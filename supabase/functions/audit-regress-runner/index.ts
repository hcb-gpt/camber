/**
 * audit-regress-runner Edge Function v0.1.0
 *
 * Regression gate: loads promoted manifest items, replays each through
 * audit-attribution-reviewer under original packet_json, compares
 * current verdict to baseline verdict, reports pass/fail.
 *
 * Does NOT write new ledger rows (reviewer-only replay).
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_VERSION = "v0.2.0";
const JSON_HEADERS = { "Content-Type": "application/json" };
const DEFAULT_MANIFEST_NAME = "attrib_regress_v1";
const DEFAULT_LIMIT = 10;
const MAX_LIMIT = 100;
const REVIEWER_TIMEOUT_MS = 25000;

const ALLOWED_SOURCES = [
  "prod-attrib-audit-runner",
  "manual",
  "cron",
  "audit-regress-runner-test",
];

type JsonRecord = Record<string, unknown>;

interface ManifestItem {
  manifest_item_id: string;
  ledger_id: string;
  interaction_id: string;
  span_id: string;
  baseline_verdict: string;
  baseline_reviewer_model: string | null;
  failure_mode_bucket: string | null;
  assigned_project_id: string | null;
  packet_json: JsonRecord;
  correction_expected_project_id: string | null;
}

interface RegressResult {
  manifest_item_id: string;
  ledger_id: string;
  interaction_id: string;
  span_id: string;
  baseline_verdict: string;
  baseline_reviewer_model: string | null;
  pinned_reviewer_model: string | null;
  current_verdict: string;
  pass: boolean;
  failure_mode_bucket: string | null;
  correction_expected_project_id: string | null;
  reviewer_ms: number;
  reviewer_error: string | null;
}

function asString(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

function asRecord(v: unknown): JsonRecord {
  return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as JsonRecord) : {};
}

async function loadManifestItems(
  db: ReturnType<typeof createClient>,
  manifestName: string,
  limit: number,
): Promise<ManifestItem[]> {
  const { data: manifest, error: manifestErr } = await db
    .from("attribution_audit_manifest")
    .select("id")
    .eq("name", manifestName)
    .eq("is_active", true)
    .limit(1)
    .maybeSingle();

  if (manifestErr) throw new Error(`manifest_lookup_failed: ${manifestErr.message}`);
  if (!manifest) throw new Error(`manifest_not_found: ${manifestName}`);

  const { data: items, error: itemsErr } = await db
    .from("attribution_audit_manifest_items")
    .select(`
      id,
      ledger_id,
      notes,
      attribution_audit_ledger!inner (
        interaction_id,
        span_id,
        verdict,
        failure_mode_bucket,
        assigned_project_id,
        packet_json,
        reviewer_model
      )
    `)
    .eq("manifest_id", manifest.id)
    .order("added_at", { ascending: true })
    .limit(limit);

  if (itemsErr) throw new Error(`manifest_items_failed: ${itemsErr.message}`);
  if (!items || items.length === 0) return [];

  const manifestItemIds = items.map((i: JsonRecord) => asString(i.id));
  const { data: corrections } = await db
    .from("attribution_audit_manifest_item_corrections")
    .select("manifest_item_id, expected_project_id")
    .in("manifest_item_id", manifestItemIds)
    .eq("is_active", true);

  const correctionMap = new Map<string, string>();
  if (corrections) {
    for (const c of corrections) {
      correctionMap.set(asString(c.manifest_item_id), asString(c.expected_project_id));
    }
  }

  return items.map((item: JsonRecord) => {
    const ledger = asRecord(item.attribution_audit_ledger);
    return {
      manifest_item_id: asString(item.id),
      ledger_id: asString(item.ledger_id),
      interaction_id: asString(ledger.interaction_id),
      span_id: asString(ledger.span_id),
      baseline_verdict: asString(ledger.verdict),
      baseline_reviewer_model: asString(ledger.reviewer_model) || null,
      failure_mode_bucket: asString(ledger.failure_mode_bucket) || null,
      assigned_project_id: asString(ledger.assigned_project_id) || null,
      packet_json: asRecord(ledger.packet_json),
      correction_expected_project_id: correctionMap.get(asString(item.id)) || null,
    };
  });
}

async function callReviewer(
  supabaseUrl: string,
  edgeSecret: string,
  packetJson: JsonRecord,
  reviewerModel: string | null,
): Promise<{ verdict: string; ms: number; error: string | null }> {
  const t0 = Date.now();
  const reviewerUrl = `${supabaseUrl}/functions/v1/audit-attribution-reviewer`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REVIEWER_TIMEOUT_MS);

  const payload: JsonRecord = { packet_json: packetJson };
  if (reviewerModel) {
    payload.reviewer_model = reviewerModel;
  }

  try {
    const resp = await fetch(reviewerUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Edge-Secret": edgeSecret,
        "X-Source": "prod-attrib-audit-runner",
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });

    const body = asRecord(await resp.json());
    const ms = Date.now() - t0;

    if (!body.ok) {
      return { verdict: "ERROR", ms, error: asString(body.error) || "reviewer_error" };
    }

    const output = asRecord(body.reviewer_output);
    return { verdict: asString(output.verdict) || "ERROR", ms, error: null };
  } catch (e: unknown) {
    const ms = Date.now() - t0;
    const msg = e instanceof Error ? e.message : String(e || "unknown");
    return { verdict: "ERROR", ms, error: msg };
  } finally {
    clearTimeout(timeout);
  }
}

function verdictMatches(baseline: string, current: string): boolean {
  if (current === "ERROR") return false;
  return baseline.toUpperCase() === current.toUpperCase();
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: JSON_HEADERS });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ ok: false, error: "method_not_allowed" }),
      { status: 405, headers: JSON_HEADERS },
    );
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code || "missing_edge_secret");
  }

  let body: JsonRecord = {};
  try {
    body = asRecord(await req.json());
  } catch {
    return new Response(
      JSON.stringify({ ok: false, error: "invalid_json" }),
      { status: 400, headers: JSON_HEADERS },
    );
  }

  const manifestName = asString(body.manifest_name) || DEFAULT_MANIFEST_NAME;
  const rawLimit = typeof body.limit === "number" ? body.limit : DEFAULT_LIMIT;
  const limit = Math.min(Math.max(1, Math.round(rawLimit as number)), MAX_LIMIT);
  const dryRun = body.dry_run === true;
  const forceReviewerModel = asString(body.reviewer_model) || null;

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET") || "";

  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(
      JSON.stringify({ ok: false, error: "server_misconfigured" }),
      { status: 500, headers: JSON_HEADERS },
    );
  }

  const db = createClient(supabaseUrl, serviceRoleKey);

  let items: ManifestItem[];
  try {
    items = await loadManifestItems(db, manifestName, limit);
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e || "unknown");
    return new Response(
      JSON.stringify({ ok: false, error: "manifest_load_failed", detail: msg }),
      { status: 500, headers: JSON_HEADERS },
    );
  }

  if (items.length === 0) {
    return new Response(
      JSON.stringify({
        ok: true,
        version: FUNCTION_VERSION,
        manifest_name: manifestName,
        items_loaded: 0,
        results: [],
        summary: { total: 0, pass: 0, fail: 0, error: 0 },
        ms: Date.now() - t0,
      }),
      { status: 200, headers: JSON_HEADERS },
    );
  }

  if (dryRun) {
    return new Response(
      JSON.stringify({
        ok: true,
        version: FUNCTION_VERSION,
        dry_run: true,
        manifest_name: manifestName,
        items_loaded: items.length,
        force_reviewer_model: forceReviewerModel,
        items_preview: items.map((i) => ({
          manifest_item_id: i.manifest_item_id,
          ledger_id: i.ledger_id,
          interaction_id: i.interaction_id,
          span_id: i.span_id,
          baseline_verdict: i.baseline_verdict,
          baseline_reviewer_model: i.baseline_reviewer_model,
          pinned_reviewer_model: forceReviewerModel || i.baseline_reviewer_model,
          failure_mode_bucket: i.failure_mode_bucket,
          has_packet: Object.keys(i.packet_json).length > 0,
        })),
        ms: Date.now() - t0,
      }),
      { status: 200, headers: JSON_HEADERS },
    );
  }

  const results: RegressResult[] = [];
  let passCount = 0;
  let failCount = 0;
  let errorCount = 0;

  for (const item of items) {
    const pinnedModel = forceReviewerModel || item.baseline_reviewer_model;

    if (Object.keys(item.packet_json).length === 0) {
      results.push({
        manifest_item_id: item.manifest_item_id,
        ledger_id: item.ledger_id,
        interaction_id: item.interaction_id,
        span_id: item.span_id,
        baseline_verdict: item.baseline_verdict,
        baseline_reviewer_model: item.baseline_reviewer_model,
        pinned_reviewer_model: pinnedModel,
        current_verdict: "ERROR",
        pass: false,
        failure_mode_bucket: item.failure_mode_bucket,
        correction_expected_project_id: item.correction_expected_project_id,
        reviewer_ms: 0,
        reviewer_error: "empty_packet_json",
      });
      errorCount++;
      continue;
    }

    const review = await callReviewer(supabaseUrl, edgeSecret, item.packet_json, pinnedModel);
    const pass = verdictMatches(item.baseline_verdict, review.verdict);

    if (review.error) {
      errorCount++;
    } else if (pass) {
      passCount++;
    } else {
      failCount++;
    }

    results.push({
      manifest_item_id: item.manifest_item_id,
      ledger_id: item.ledger_id,
      interaction_id: item.interaction_id,
      span_id: item.span_id,
      baseline_verdict: item.baseline_verdict,
      baseline_reviewer_model: item.baseline_reviewer_model,
      pinned_reviewer_model: pinnedModel,
      current_verdict: review.verdict,
      pass,
      failure_mode_bucket: item.failure_mode_bucket,
      correction_expected_project_id: item.correction_expected_project_id,
      reviewer_ms: review.ms,
      reviewer_error: review.error,
    });
  }

  return new Response(
    JSON.stringify({
      ok: true,
      version: FUNCTION_VERSION,
      manifest_name: manifestName,
      force_reviewer_model: forceReviewerModel,
      items_loaded: items.length,
      summary: {
        total: results.length,
        pass: passCount,
        fail: failCount,
        error: errorCount,
        pass_rate: results.length > 0 ? Number((passCount / results.length).toFixed(4)) : 0,
      },
      results,
      ms: Date.now() - t0,
    }),
    { status: 200, headers: JSON_HEADERS },
  );
});
