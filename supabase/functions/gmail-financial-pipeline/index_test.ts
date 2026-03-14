import { assertEquals, assertExists } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { handleRequest } from "./index.ts";

type Row = Record<string, unknown>;

class MockQuery implements PromiseLike<any> {
  action: "select" | "insert" | "update" | null = null;
  filters: Array<{ field: string; op: "eq" | "in"; value: unknown }> = [];
  limitValue: number | null = null;
  orderBy: Array<{ field: string; ascending: boolean }> = [];
  payload: unknown = null;
  selectOptions: Record<string, unknown> | null = null;
  singleRow = false;

  constructor(
    private readonly db: MockDb,
    private readonly table: string,
  ) {}

  select(_columns?: string, options?: Record<string, unknown>) {
    if (!this.action) this.action = "select";
    this.selectOptions = options || null;
    return this;
  }

  insert(payload: unknown) {
    this.action = "insert";
    this.payload = payload;
    return this;
  }

  update(payload: unknown) {
    this.action = "update";
    this.payload = payload;
    return this;
  }

  eq(field: string, value: unknown) {
    this.filters.push({ field, op: "eq", value });
    return this;
  }

  in(field: string, value: unknown) {
    this.filters.push({ field, op: "in", value });
    return this;
  }

  order(field: string, options?: { ascending?: boolean }) {
    this.orderBy.push({ field, ascending: options?.ascending !== false });
    return this;
  }

  limit(value: number) {
    this.limitValue = value;
    return this;
  }

  single() {
    this.singleRow = true;
    return this;
  }

  then<TResult1 = any, TResult2 = never>(
    onfulfilled?: ((value: any) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: any) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return Promise.resolve(this.execute()).then(onfulfilled, onrejected);
  }

  private execute() {
    if (this.action === "insert") return this.executeInsert();
    if (this.action === "update") return this.executeUpdate();
    return this.executeSelect();
  }

  private executeSelect() {
    if (this.table === "v_gmail_financial_review_queue" && this.selectOptions?.head === true) {
      return { count: this.db.reviewQueue().length, data: null, error: null };
    }

    let rows = this.db.rowsForTable(this.table);
    rows = this.applyFilters(rows);
    rows = this.applyOrdering(rows);
    if (this.limitValue !== null) rows = rows.slice(0, this.limitValue);

    if (this.singleRow) {
      return { data: rows[0] || null, error: null };
    }
    return { data: rows, error: null };
  }

  private executeInsert() {
    if (this.table !== "gmail_financial_pipeline_runs") {
      throw new Error(`unexpected_insert_table:${this.table}`);
    }

    const run = {
      id: this.db.nextId("run"),
      ...((this.payload as Row) || {}),
    };
    this.db.runs.push(run);

    if (this.singleRow) {
      return { data: { id: run.id }, error: null };
    }
    return { data: [run], error: null };
  }

  private executeUpdate() {
    if (!["gmail_financial_pipeline_runs", "gmail_financial_candidates"].includes(this.table)) {
      throw new Error(`unexpected_update_table:${this.table}`);
    }

    const rows = this.applyFilters(this.db.rowsForTable(this.table));
    for (const row of rows) {
      Object.assign(row, this.payload as Row);
    }
    return { data: null, error: null };
  }

  private applyFilters(rows: Row[]): Row[] {
    return rows.filter((row) =>
      this.filters.every((filter) => {
        if (filter.op === "eq") {
          return row[filter.field] === filter.value;
        }
        if (!Array.isArray(filter.value)) return false;
        return (filter.value as unknown[]).includes(row[filter.field]);
      })
    );
  }

  private applyOrdering(rows: Row[]): Row[] {
    if (this.orderBy.length === 0) return rows;
    const sorted = [...rows];
    sorted.sort((a, b) => {
      for (const order of this.orderBy) {
        const av = a[order.field];
        const bv = b[order.field];
        if (av === bv) continue;
        const cmp = String(av || "").localeCompare(String(bv || ""));
        return order.ascending ? cmp : -cmp;
      }
      return 0;
    });
    return sorted;
  }
}

class MockDb {
  aliases: Row[] = [];
  candidates: Row[] = [];
  profiles: Row[] = [];
  projects: Row[] = [];
  receipts: Row[] = [];
  runs: Row[] = [];
  searchTargets: Row[] = [];
  private counters = new Map<string, number>();

  from(table: string) {
    return new MockQuery(this, table);
  }

  rpc(name: string, args: Record<string, unknown>) {
    if (name === "upsert_gmail_financial_candidate") {
      const payload = (args.p_candidate as Row) || {};
      let candidate = this.candidates.find((row) => row.message_id === payload.message_id);
      if (!candidate) {
        candidate = {
          id: this.nextId("candidate"),
          classification_state: "pending",
          decision: null,
          extraction_receipt_id: null,
          extraction_state: "pending",
          retrieval_state: "retrieved",
        };
        this.candidates.push(candidate);
      }

      Object.assign(candidate, payload, {
        last_retrieved_at_utc: new Date().toISOString(),
      });

      return Promise.resolve({
        data: [{
          candidate_id: candidate.id,
          classification_state: candidate.classification_state,
          decision: candidate.decision,
          extraction_state: candidate.extraction_state,
        }],
        error: null,
      });
    }

    if (name === "upsert_gmail_financial_receipt") {
      const payload = (args.p_receipt as Row) || {};
      const existing = this.receipts.find((row) =>
        row.vendor_normalized === payload.vendor_normalized &&
        row.total === payload.total &&
        row.receipt_date === payload.receipt_date
      );

      if (existing) {
        return Promise.resolve({
          data: [{
            hit_count: 2,
            is_duplicate: true,
            receipt_id: existing.id,
          }],
          error: null,
        });
      }

      const receipt = {
        id: this.nextId("receipt"),
        ...payload,
      };
      this.receipts.push(receipt);

      return Promise.resolve({
        data: [{
          hit_count: 1,
          is_duplicate: false,
          receipt_id: receipt.id,
        }],
        error: null,
      });
    }

    throw new Error(`unexpected_rpc:${name}`);
  }

  nextId(prefix: string): string {
    const next = (this.counters.get(prefix) || 0) + 1;
    this.counters.set(prefix, next);
    return `${prefix}-${next}`;
  }

  reviewQueue(): Row[] {
    return this.candidates
      .filter((row) => row.decision === "review" && row.review_state === "pending")
      .map((row) => ({
        candidate_id: row.id,
        decision_reason: row.decision_reason,
        doc_type: row.doc_type,
        finance_relevance_score: row.finance_relevance_score,
        from_header: row.from_header,
        last_retrieved_at_utc: row.last_retrieved_at_utc,
        matched_profile_slugs: row.matched_profile_slugs,
        message_id: row.message_id,
        subject: row.subject,
      }));
  }

  rowsForTable(table: string): Row[] {
    switch (table) {
      case "projects":
        return this.projects;
      case "v_project_alias_lookup":
        return this.aliases;
      case "v_gmail_search_targets":
        return this.searchTargets;
      case "gmail_query_profiles":
        return this.profiles;
      case "gmail_financial_pipeline_runs":
        return this.runs;
      case "gmail_financial_candidates":
        return this.candidates;
      case "v_gmail_financial_review_queue":
        return this.reviewQueue();
      default:
        throw new Error(`unexpected_table:${table}`);
    }
  }
}

class StrictModeDb extends MockDb {
  constructor(private readonly forbiddenTables: Set<string>) {
    super();
  }

  override rowsForTable(table: string): Row[] {
    if (this.forbiddenTables.has(table)) {
      throw new Error(`unexpected_table_access:${table}`);
    }
    return super.rowsForTable(table);
  }
}

async function withEdgeSecretEnv(fn: () => Promise<void>) {
  const previousAlias = Deno.env.get("X_EDGE_SECRET");
  const previousCanonical = Deno.env.get("EDGE_SHARED_SECRET");
  const previousOpenAiKey = Deno.env.get("OPENAI_API_KEY");
  Deno.env.set("X_EDGE_SECRET", "test-edge-secret");
  Deno.env.set("EDGE_SHARED_SECRET", "test-edge-secret");
  Deno.env.delete("OPENAI_API_KEY");
  try {
    await fn();
  } finally {
    if (previousAlias === undefined) Deno.env.delete("X_EDGE_SECRET");
    else Deno.env.set("X_EDGE_SECRET", previousAlias);
    if (previousCanonical === undefined) Deno.env.delete("EDGE_SHARED_SECRET");
    else Deno.env.set("EDGE_SHARED_SECRET", previousCanonical);
    if (previousOpenAiKey === undefined) Deno.env.delete("OPENAI_API_KEY");
    else Deno.env.set("OPENAI_API_KEY", previousOpenAiKey);
  }
}

function makeRequest(body: Record<string, unknown>): Request {
  return new Request("http://localhost/gmail-financial-pipeline", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Edge-Secret": "test-edge-secret",
      "X-Source": "operator",
    },
    body: JSON.stringify(body),
  });
}

function makeFullRunDb(): MockDb {
  const db = new MockDb();
  db.projects = [{
    id: "11111111-1111-4111-8111-111111111111",
    name: "Winship Residence",
    project_kind: "client",
    status: "active",
  }];
  db.aliases = [{
    alias: "Winship",
    project_id: "11111111-1111-4111-8111-111111111111",
  }];
  db.profiles = [{
    active: true,
    class_hint: "vendor_invoice",
    effective_after_date: "2025-04-01",
    gmail_query: "subject:invoice",
    label_mirror_name: "3",
    mailbox_scope: "zack@heartwoodcustombuilders.com",
    priority: 200,
    profile_set: "finance_v1",
    profile_slug: "broad_finance_candidate_net",
  }];
  db.searchTargets = [{
    company: null,
    company_aliases: [],
    confidence: 0.95,
    contact_aliases: [],
    contact_id: null,
    contact_name: null,
    email: "billing@groundedsiteworks.com",
    priority: 100,
    project_id: "11111111-1111-4111-8111-111111111111",
    project_name: "Winship Residence",
    relation_type: "vendor_contact",
    source: "test",
    target_id: "target-1",
    target_type: "vendor_correspondence",
    trade: null,
    vendor_name: "Grounded Siteworks",
    vendor_name_normalized: "grounded siteworks",
  }];
  return db;
}

Deno.test("handleRequest smoke test runs full staged workflow and inserts canonical receipt", async () => {
  await withEdgeSecretEnv(async () => {
    const db = makeFullRunDb();
    const response = await handleRequest(
      makeRequest({
        candidate_limit: 5,
        max_targets: 5,
        profile_set: "finance_v1",
        run_mode: "full",
      }),
      {
        db,
        gmailGetJson: ({ path }) =>
          Promise.resolve(
            path === "messages"
              ? {
                json: {
                  messages: [{ id: "msg-1", threadId: "thread-1" }],
                  resultSizeEstimate: 1,
                },
                ok: true,
                status: 200,
              }
              : {
                json: {
                  id: "msg-1",
                  internalDate: String(Date.parse("2026-03-14T17:55:30.000Z")),
                  payload: {
                    body: {
                      data: btoa(
                        "Invoice Date: 03/13/2026\nInvoice # 1042\nAmount Due: $12,500.00\nWinship driveway work",
                      ),
                    },
                    headers: [
                      { name: "From", value: '"Grounded Siteworks" <billing@groundedsiteworks.com>' },
                      { name: "Subject", value: "QuickBooks: Invoice 1042 for Winship" },
                    ],
                    mimeType: "text/plain",
                  },
                  snippet: "Amount Due: $12,500.00",
                  threadId: "thread-1",
                },
                ok: true,
                status: 200,
              },
          ),
        resolveAccessToken: () => Promise.resolve({ authMode: "oauth_refresh_token", token: "gmail-token" }),
      },
    );

    assertEquals(response.status, 200);
    const json = await response.json();
    assertEquals(json.ok, true);
    assertEquals(json.stats.messages_listed, 1);
    assertEquals(json.stats.messages_examined, 1);
    assertEquals(json.stats.receipts_inserted, 1);

    assertEquals(db.candidates.length, 1);
    assertEquals(db.candidates[0].decision, "accept_extract");
    assertEquals(db.candidates[0].extraction_state, "extracted");

    assertEquals(db.receipts.length, 1);
    assertEquals(db.receipts[0].vendor, "Grounded Siteworks");
    assertEquals(db.receipts[0].project_id, "11111111-1111-4111-8111-111111111111");

    const run = db.runs[0];
    assertExists(run.notes);
    assertEquals((run.notes as Row).profile_set, "finance_v1");
  });
});

Deno.test("handleRequest smoke test routes uncertain candidates to review queue without extraction", async () => {
  await withEdgeSecretEnv(async () => {
    const db = makeFullRunDb();
    const response = await handleRequest(
      makeRequest({
        profile_set: "finance_v1",
        review_only: true,
        run_mode: "full",
      }),
      {
        db,
        gmailGetJson: ({ path }) =>
          Promise.resolve(
            path === "messages"
              ? {
                json: {
                  messages: [{ id: "msg-2", threadId: "thread-2" }],
                  resultSizeEstimate: 1,
                },
                ok: true,
                status: 200,
              }
              : {
                json: {
                  id: "msg-2",
                  internalDate: String(Date.parse("2026-03-14T18:05:00.000Z")),
                  payload: {
                    body: { data: btoa("Please review this thread when you can.") },
                    headers: [
                      { name: "From", value: '"Vendor" <billing@example.com>' },
                      { name: "Subject", value: "Need this looked at" },
                    ],
                    mimeType: "text/plain",
                  },
                  snippet: "Please review this thread when you can.",
                  threadId: "thread-2",
                },
                ok: true,
                status: 200,
              },
          ),
        resolveAccessToken: () => Promise.resolve({ authMode: "oauth_refresh_token", token: "gmail-token" }),
      },
    );

    assertEquals(response.status, 200);
    const json = await response.json();
    assertEquals(json.ok, true);
    assertEquals(json.review_queue_count, 1);
    assertEquals(db.receipts.length, 0);
    assertEquals(db.candidates[0].decision, "review");
    assertEquals(db.candidates[0].review_state, "pending");
  });
});

Deno.test("handleRequest smoke test routes unrelated invoice-shaped mail to review", async () => {
  await withEdgeSecretEnv(async () => {
    const db = makeFullRunDb();
    db.searchTargets.push(
      {
        company: null,
        company_aliases: [],
        confidence: 0.98,
        contact_aliases: [],
        contact_id: null,
        contact_name: null,
        email: "zack@heartwoodcustombuilders.com",
        priority: 150,
        project_id: "24583746-69f2-459f-a66a-7be613046292",
        project_name: "Internal Admin",
        relation_type: "vendor_contact",
        source: "test",
        target_id: "target-hcb-1",
        target_type: "vendor_correspondence",
        trade: null,
        vendor_name: "Heartwood Custom Builders",
        vendor_name_normalized: "hcb",
      },
      {
        company: null,
        company_aliases: [],
        confidence: 0.97,
        contact_aliases: [],
        contact_id: null,
        contact_name: null,
        email: "admin@heartwoodcustombuilders.com",
        priority: 140,
        project_id: "310a3768-d7c0-4e72-88d0-aa67bf4d1b05",
        project_name: "Internal Admin 2",
        relation_type: "vendor_contact",
        source: "test",
        target_id: "target-hcb-2",
        target_type: "vendor_correspondence",
        trade: null,
        vendor_name: "Heartwood Custom Builders",
        vendor_name_normalized: "hcb",
      },
    );
    const response = await handleRequest(
      makeRequest({
        profile_set: "finance_v1",
        review_only: true,
        run_mode: "full",
      }),
      {
        db,
        gmailGetJson: ({ path }) =>
          Promise.resolve(
            path === "messages"
              ? {
                json: {
                  messages: [{ id: "msg-3", threadId: "thread-3" }],
                  resultSizeEstimate: 1,
                },
                ok: true,
                status: 200,
              }
              : {
                json: {
                  id: "msg-3",
                  internalDate: String(Date.parse("2026-03-14T18:06:00.000Z")),
                  payload: {
                    body: { data: btoa("Invoice Date: 03/13/2026\nInvoice # 8891\nAmount Due: $42.00") },
                    headers: [
                      { name: "From", value: '"Picsart" <billing@picsart.com>' },
                      { name: "Subject", value: "Your Picsart Invoice" },
                    ],
                    mimeType: "text/plain",
                  },
                  snippet: "Invoice Date: 03/13/2026",
                  threadId: "thread-3",
                },
                ok: true,
                status: 200,
              },
          ),
        resolveAccessToken: () => Promise.resolve({ authMode: "oauth_refresh_token", token: "gmail-token" }),
      },
    );

    assertEquals(response.status, 200);
    const json = await response.json();
    assertEquals(json.ok, true);
    assertEquals(json.review_queue_count, 1);
    assertEquals(db.receipts.length, 0);
    assertEquals(db.candidates[0].decision, "review");
    assertEquals(db.candidates[0].extraction_state, "pending");
  });
});

Deno.test("handleRequest ignores weak single-name project aliases during classification", async () => {
  await withEdgeSecretEnv(async () => {
    const db = makeFullRunDb();
    db.aliases.push({
      alias: "Chris",
      project_id: "f4f2b725-9370-4824-9cc8-4a542368b6c5",
    });

    const response = await handleRequest(
      makeRequest({
        profile_set: "finance_v1",
        review_only: true,
        run_mode: "full",
      }),
      {
        db,
        gmailGetJson: ({ path }) =>
          Promise.resolve(
            path === "messages"
              ? {
                json: {
                  messages: [{ id: "msg-4", threadId: "thread-4" }],
                  resultSizeEstimate: 1,
                },
                ok: true,
                status: 200,
              }
              : {
                json: {
                  id: "msg-4",
                  internalDate: String(Date.parse("2026-03-14T18:07:00.000Z")),
                  payload: {
                    body: { data: btoa("Reminder: Controllr Demo with Chris Anderson tomorrow.") },
                    headers: [
                      { name: "From", value: '"Chris Anderson" <notifications@calendly.com>' },
                      { name: "Subject", value: "Reminder: Controllr Demo with Chris Anderson tomorrow" },
                    ],
                    mimeType: "text/plain",
                  },
                  snippet: "Reminder: Controllr Demo with Chris Anderson tomorrow.",
                  threadId: "thread-4",
                },
                ok: true,
                status: 200,
              },
          ),
        resolveAccessToken: () => Promise.resolve({ authMode: "oauth_refresh_token", token: "gmail-token" }),
      },
    );

    assertEquals(response.status, 200);
    const json = await response.json();
    assertEquals(json.ok, true);
    assertEquals(json.review_queue_count, 1);
    assertEquals(db.receipts.length, 0);
    assertEquals(db.candidates[0].decision, "review");
  });
});

Deno.test("handleRequest smoke test extract_only processes seeded candidates without Gmail fetch", async () => {
  await withEdgeSecretEnv(async () => {
    const db = makeFullRunDb();
    db.candidates = [{
      body_excerpt: "Invoice Date: 03/13/2026\nInvoice # 1042\nAmount Due: $12,500.00\nWinship driveway work",
      classification_state: "classified",
      decision: "accept_extract",
      doc_type: "vendor_invoice",
      extraction_receipt_id: null,
      extraction_state: "pending",
      from_header: '"Grounded Siteworks" <billing@groundedsiteworks.com>',
      id: "candidate-seeded-1",
      internal_date: "2026-03-14T17:55:30.000Z",
      matched_class_hints: ["vendor_invoice"],
      matched_profile_slugs: ["broad_finance_candidate_net"],
      matched_query_fragments: ["after:2025/04/01 subject:invoice"],
      message_id: "msg-seeded-1",
      raw_headers: [
        { name: "From", value: '"Grounded Siteworks" <billing@groundedsiteworks.com>' },
        { name: "Subject", value: "QuickBooks: Invoice 1042 for Winship" },
      ],
      snippet: "Amount Due: $12,500.00",
      subject: "QuickBooks: Invoice 1042 for Winship",
      thread_id: "thread-seeded-1",
    }];

    const response = await handleRequest(
      makeRequest({
        candidate_limit: 5,
        run_mode: "extract_only",
      }),
      {
        db,
        gmailGetJson: () => Promise.reject(new Error("gmail_fetch_not_expected_in_extract_only")),
        resolveAccessToken: () => Promise.reject(new Error("auth_not_expected_in_extract_only")),
      },
    );

    assertEquals(response.status, 200);
    const json = await response.json();
    assertEquals(json.ok, true);
    assertEquals(json.stats.receipts_inserted, 1);
    assertEquals(db.receipts.length, 1);
    assertEquals(db.candidates[0].extraction_state, "extracted");
  });
});

Deno.test("handleRequest smoke test classify_only classifies seeded candidates without Gmail fetch", async () => {
  await withEdgeSecretEnv(async () => {
    const db = new StrictModeDb(new Set(["gmail_query_profiles"]));
    db.projects = [{
      id: "11111111-1111-4111-8111-111111111111",
      name: "Winship Residence",
      project_kind: "client",
      status: "active",
    }];
    db.aliases = [{
      alias: "Winship",
      project_id: "11111111-1111-4111-8111-111111111111",
    }];
    db.searchTargets = [{
      company: null,
      company_aliases: [],
      confidence: 0.95,
      contact_aliases: [],
      contact_id: null,
      contact_name: null,
      email: "billing@groundedsiteworks.com",
      priority: 100,
      project_id: "11111111-1111-4111-8111-111111111111",
      project_name: "Winship Residence",
      relation_type: "vendor_contact",
      source: "test",
      target_id: "target-1",
      target_type: "vendor_correspondence",
      trade: null,
      vendor_name: "Grounded Siteworks",
      vendor_name_normalized: "grounded siteworks",
    }];
    db.candidates = [{
      body_excerpt: "Invoice Date: 03/13/2026\nInvoice # 1042\nAmount Due: $12,500.00\nWinship driveway work",
      classification_state: "pending",
      decision: null,
      doc_type: null,
      extraction_receipt_id: null,
      extraction_state: "pending",
      from_header: '"Grounded Siteworks" <billing@groundedsiteworks.com>',
      id: "candidate-seeded-2",
      internal_date: "2026-03-14T18:10:00.000Z",
      matched_class_hints: [],
      matched_profile_slugs: ["broad_finance_candidate_net"],
      matched_query_fragments: ["after:2025/04/01 subject:invoice"],
      message_id: "msg-seeded-2",
      raw_headers: [
        { name: "From", value: '"Grounded Siteworks" <billing@groundedsiteworks.com>' },
        { name: "Subject", value: "QuickBooks: Invoice 1042 for Winship" },
      ],
      snippet: "Amount Due: $12,500.00",
      subject: "QuickBooks: Invoice 1042 for Winship",
      thread_id: "thread-seeded-2",
    }];

    const response = await handleRequest(
      makeRequest({
        candidate_limit: 5,
        run_mode: "classify_only",
      }),
      {
        db,
        gmailGetJson: () => Promise.reject(new Error("gmail_fetch_not_expected_in_classify_only")),
        resolveAccessToken: () => Promise.reject(new Error("auth_not_expected_in_classify_only")),
      },
    );

    assertEquals(response.status, 200);
    const json = await response.json();
    assertEquals(json.ok, true);
    assertEquals(json.stats.candidates_classified, 1);
    assertEquals(db.candidates[0].decision, "accept_extract");
    assertEquals(db.candidates[0].doc_type, "vendor_invoice");
    assertEquals(db.receipts.length, 0);
  });
});

Deno.test("handleRequest rejects mixed mailbox scopes before Gmail auth", async () => {
  await withEdgeSecretEnv(async () => {
    const db = makeFullRunDb();
    db.profiles.push({
      active: true,
      class_hint: "vendor_invoice",
      effective_after_date: "2025-04-01",
      gmail_query: "from:quickbooks@notification.intuit.com",
      label_mirror_name: "4",
      mailbox_scope: "other@heartwoodcustombuilders.com",
      priority: 150,
      profile_set: "finance_v1",
      profile_slug: "vendor_platform_exception_path",
    });

    const response = await handleRequest(
      makeRequest({
        candidate_limit: 5,
        profile_set: "finance_v1",
        run_mode: "full",
      }),
      {
        db,
        gmailGetJson: () => Promise.reject(new Error("gmail_fetch_not_expected_with_mixed_mailbox_scope")),
        resolveAccessToken: () => Promise.reject(new Error("auth_not_expected_with_mixed_mailbox_scope")),
      },
    );

    assertEquals(response.status, 500);
    const json = await response.json();
    assertEquals(json.error, "pipeline_failed");
    assertEquals(String(json.detail).startsWith("mixed_mailbox_scope:"), true);
  });
});

Deno.test("handleRequest smoke test retrieve_only avoids extraction tables and persists candidates", async () => {
  await withEdgeSecretEnv(async () => {
    const db = new StrictModeDb(
      new Set([
        "projects",
        "v_project_alias_lookup",
        "v_gmail_search_targets",
      ]),
    );
    db.profiles = [{
      active: true,
      class_hint: "vendor_invoice",
      effective_after_date: "2025-04-01",
      gmail_query: "subject:invoice",
      label_mirror_name: "3",
      mailbox_scope: "zack@heartwoodcustombuilders.com",
      priority: 200,
      profile_set: "finance_v1",
      profile_slug: "broad_finance_candidate_net",
    }];

    const response = await handleRequest(
      makeRequest({
        candidate_limit: 5,
        profile_set: "finance_v1",
        run_mode: "retrieve_only",
      }),
      {
        db,
        gmailGetJson: ({ path }) =>
          Promise.resolve(
            path === "messages"
              ? {
                json: {
                  messages: [{ id: "msg-r1", threadId: "thread-r1" }],
                  resultSizeEstimate: 5,
                },
                ok: true,
                status: 200,
              }
              : {
                json: {
                  id: "msg-r1",
                  internalDate: String(Date.parse("2026-03-14T19:00:00.000Z")),
                  payload: {
                    body: { data: btoa("Invoice Date: 03/13/2026\nInvoice # 9988\nAmount Due: $500.00") },
                    headers: [
                      { name: "From", value: '"Vendor" <billing@example.com>' },
                      { name: "Subject", value: "Invoice 9988" },
                    ],
                    mimeType: "text/plain",
                  },
                  snippet: "Amount Due: $500.00",
                  threadId: "thread-r1",
                },
                ok: true,
                status: 200,
              },
          ),
        resolveAccessToken: () => Promise.resolve({ authMode: "oauth_refresh_token", token: "gmail-token" }),
      },
    );

    assertEquals(response.status, 200);
    const json = await response.json();
    assertEquals(json.ok, true);
    assertEquals(json.stats.messages_listed, 1);
    assertEquals(json.stats.candidates_retrieved, 1);
    assertEquals(json.stats.candidates_classified, 0);
    assertEquals(db.candidates.length, 1);
    assertEquals(db.receipts.length, 0);
    assertEquals((db.runs[0].gmail_result_estimate as number) >= 1, true);
  });
});
