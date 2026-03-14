import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  addProfileHit,
  applyTargetAffinity,
  buildProfileGmailQuery,
  buildTargetQueryFragment,
  type GmailQueryProfile,
  matchTargetsToMessage,
  mergeVendorHints,
  type SearchTarget,
  summarizeRetrievalCounts,
} from "./search.ts";
import { type ParsedReceipt } from "./extraction.ts";

function makeTarget(overrides: Partial<SearchTarget>): SearchTarget {
  return {
    company: null,
    company_aliases: [],
    confidence: 0.9,
    contact_aliases: [],
    contact_id: null,
    contact_name: null,
    email: "billing@example.com",
    priority: 100,
    project_id: null,
    project_name: null,
    relation_type: "vendor_contact",
    source: "test",
    target_id: "target-1",
    target_type: "vendor_correspondence",
    trade: null,
    vendor_name: "Grounded Siteworks",
    vendor_name_normalized: "grounded siteworks",
    ...overrides,
  };
}

function makeReceipt(overrides: Partial<ParsedReceipt>): ParsedReceipt {
  return {
    amount: { method: "contextual_total", raw: "1200.00", total: 1200 },
    body_excerpt: "Invoice",
    confidence: 0.6,
    invoice_or_transaction: "1042",
    job_name: null,
    matched_project_alias: null,
    project_id: null,
    receipt_date: "2026-03-14",
    reasons: ["amount:contextual_total"],
    vendor: null,
    vendor_normalized: null,
    ...overrides,
  };
}

function makeProfile(overrides: Partial<GmailQueryProfile>): GmailQueryProfile {
  return {
    active: true,
    class_hint: "vendor_invoice",
    effective_after_date: null,
    gmail_query: "subject:invoice",
    label_mirror_name: null,
    mailbox_scope: "zack@heartwoodcustombuilders.com",
    priority: 100,
    profile_set: "finance_v1",
    profile_slug: "broad_finance_candidate_net",
    ...overrides,
  };
}

Deno.test("buildProfileGmailQuery applies the later effective after date", () => {
  const query = buildProfileGmailQuery(
    makeProfile({ effective_after_date: "2025-04-01" }),
    new Date("2025-03-15T00:00:00.000Z"),
  );

  assertEquals(query, "after:2025/04/01 subject:invoice");
});

Deno.test("addProfileHit dedupes messages and merges profile provenance", () => {
  const listedById = new Map();
  addProfileHit(
    listedById,
    "msg-1",
    "thread-1",
    makeProfile({
      class_hint: "vendor_invoice",
      priority: 200,
      profile_slug: "high_conf_invoice_traffic",
    }),
    "subject:invoice",
  );
  addProfileHit(
    listedById,
    "msg-1",
    "thread-1",
    makeProfile({
      class_hint: "statement",
      priority: 300,
      profile_slug: "vendor_platform_exception_path",
    }),
    "from:quickbooks@notification.intuit.com",
  );

  const listed = listedById.get("msg-1");
  assertEquals(listed?.matched_profile_slugs, [
    "high_conf_invoice_traffic",
    "vendor_platform_exception_path",
  ]);
  assertEquals(listed?.class_hints, ["vendor_invoice", "statement"]);
  assertEquals(listed?.priority, 300);
  assertEquals(summarizeRetrievalCounts([listed]), {
    high_conf_invoice_traffic: 1,
    vendor_platform_exception_path: 1,
  });
});

Deno.test("matchTargetsToMessage finds participant matches from headers and body", () => {
  const matched = matchTargetsToMessage(
    [
      makeTarget({ email: "billing@groundedsiteworks.com" }),
      makeTarget({ email: "other@example.com", target_id: "target-2" }),
    ],
    [
      { name: "From", value: '"Grounded Siteworks" <billing@groundedsiteworks.com>' },
      { name: "To", value: "zack@heartwoodcustombuilders.com" },
    ],
    "Reply to billing@groundedsiteworks.com for questions.",
  );

  assertEquals(matched.map((target) => target.target_id), ["target-1"]);
});

Deno.test("buildTargetQueryFragment uses round-trip search for vendor correspondence", () => {
  const query = buildTargetQueryFragment(makeTarget({ email: "billing@groundedsiteworks.com" }), null);
  assertEquals(query, "(from:billing@groundedsiteworks.com OR to:billing@groundedsiteworks.com)");
});

Deno.test("buildTargetQueryFragment narrows client outbound search to recipient and sender", () => {
  const query = buildTargetQueryFragment(
    makeTarget({
      email: "owner@example.com",
      target_type: "client_outbound",
      vendor_name: "Woodbery",
      vendor_name_normalized: "woodbery",
    }),
    "chad@heartwoodbuilt.com",
  );
  assertEquals(query, "to:owner@example.com from:chad@heartwoodbuilt.com");
});

Deno.test("mergeVendorHints ignores client outbound targets", () => {
  const hints = mergeVendorHints(
    ["Accent Granite"],
    [
      makeTarget({ vendor_name: "Grounded Siteworks", company_aliases: ["Grounded"] }),
      makeTarget({
        email: "owner@example.com",
        target_id: "target-2",
        target_type: "client_outbound",
        vendor_name: "Woodbery Residence",
        vendor_name_normalized: "woodbery residence",
      }),
    ],
  );

  assertEquals(hints, ["Accent Granite", "Grounded Siteworks", "Grounded"]);
});

Deno.test("applyTargetAffinity fills missing project and vendor from consistent vendor target", () => {
  const enriched = applyTargetAffinity(
    makeReceipt({ vendor: null, vendor_normalized: null }),
    [
      makeTarget({
        project_id: "11111111-1111-4111-8111-111111111111",
        project_name: "Winship Residence",
      }),
    ],
  );

  assertEquals(enriched.project_id, "11111111-1111-4111-8111-111111111111");
  assertEquals(enriched.job_name, "Winship Residence");
  assertEquals(enriched.vendor, "Grounded Siteworks");
  assertEquals(enriched.vendor_normalized, "grounded siteworks");
});

Deno.test("applyTargetAffinity defaults client outbound receipts to HCB vendor", () => {
  const enriched = applyTargetAffinity(
    makeReceipt({ vendor: "Woodbery Residence", vendor_normalized: "woodbery residence" }),
    [
      makeTarget({
        email: "owner@example.com",
        target_type: "client_outbound",
        vendor_name: "Woodbery Residence",
        vendor_name_normalized: "woodbery residence",
      }),
    ],
  );

  assertEquals(enriched.vendor, "HCB");
  assertEquals(enriched.vendor_normalized, "hcb");
});
