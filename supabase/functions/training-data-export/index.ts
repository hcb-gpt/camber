/**
 * training-data-export Edge Function v1.0.0
 *
 * Daily snapshot export for human-labeled attribution training data.
 * Source view: public.v_human_truth_attributions
 * Destination table: public.training_data_snapshots (append-only, one row/day)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_SLUG = "training-data-export";
const FUNCTION_VERSION = "v1.0.0";
const SOURCE_VIEW = "v_human_truth_attributions";
const PAGE_SIZE = 1000;
const MAX_ROWS = 200_000;

const ALLOWED_SOURCES = [
  "training-data-export",
  "cron",
  "manual",
  "strat",
  "dev",
];

type JsonRecord = Record<string, unknown>;

interface ExportRequest {
  snapshot_date?: string;
  force?: boolean;
  dry_run?: boolean;
}

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(
    JSON.stringify(body),
    { status, headers: { "Content-Type": "application/json" } },
  );
}

function utcDateString(date = new Date()): string {
  return date.toISOString().slice(0, 10);
}

function isValidDateString(value: unknown): value is string {
  if (typeof value !== "string") return false;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function isDuplicateKeyError(err: unknown): boolean {
  const anyErr = err as { code?: string; message?: string } | null;
  const code = anyErr?.code || "";
  const message = anyErr?.message || "";
  return code === "23505" || /duplicate key/i.test(message);
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "method_not_allowed" }, 405);
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code || "missing_edge_secret");
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL") || "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "",
  );

  let body: ExportRequest = {};
  try {
    body = await req.json().catch(() => ({})) as ExportRequest;
  } catch {
    return jsonResponse({ ok: false, error: "invalid_json" }, 400);
  }

  const snapshotDate = isValidDateString(body.snapshot_date) ? body.snapshot_date : utcDateString();
  const force = body.force === true;
  const dryRun = body.dry_run === true;

  const { data: existingRows, error: existingErr } = await db
    .from("training_data_snapshots")
    .select("id, snapshot_date, row_count, created_at")
    .eq("snapshot_date", snapshotDate)
    .limit(1);

  if (existingErr) {
    return jsonResponse({
      ok: false,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      error: "existing_snapshot_query_failed",
      detail: existingErr.message,
    }, 500);
  }

  if ((existingRows || []).length > 0 && !force) {
    const existing = existingRows![0] as JsonRecord;
    return jsonResponse({
      ok: true,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      action: "skip_existing",
      snapshot_date: snapshotDate,
      snapshot_id: existing.id || null,
      row_count: existing.row_count || 0,
      created_at: existing.created_at || null,
      ms: Date.now() - t0,
    });
  }

  const exportedRows: JsonRecord[] = [];
  let offset = 0;
  while (true) {
    const { data, error } = await db
      .from(SOURCE_VIEW)
      .select("*")
      .order("attribution_id", { ascending: true })
      .range(offset, offset + PAGE_SIZE - 1);

    if (error) {
      return jsonResponse({
        ok: false,
        function_slug: FUNCTION_SLUG,
        version: FUNCTION_VERSION,
        error: "source_view_query_failed",
        detail: error.message,
        snapshot_date: snapshotDate,
        offset,
      }, 500);
    }

    const page = (data || []) as JsonRecord[];
    exportedRows.push(...page);

    if (exportedRows.length > MAX_ROWS) {
      return jsonResponse({
        ok: false,
        function_slug: FUNCTION_SLUG,
        version: FUNCTION_VERSION,
        error: "max_rows_exceeded",
        snapshot_date: snapshotDate,
        max_rows: MAX_ROWS,
      }, 500);
    }

    if (page.length < PAGE_SIZE) {
      break;
    }
    offset += PAGE_SIZE;
  }

  const labelCounts: Record<string, number> = {};
  let holdoutCount = 0;
  let correctionCount = 0;
  for (const row of exportedRows) {
    const label = String(row.label_type || "UNKNOWN");
    labelCounts[label] = (labelCounts[label] || 0) + 1;
    if (row.is_holdout === true) holdoutCount++;
    if (row.is_correction === true) correctionCount++;
  }

  if (dryRun) {
    return jsonResponse({
      ok: true,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      action: "dry_run",
      snapshot_date: snapshotDate,
      row_count: exportedRows.length,
      holdout_count: holdoutCount,
      correction_count: correctionCount,
      label_counts: labelCounts,
      source_view: SOURCE_VIEW,
      ms: Date.now() - t0,
    });
  }

  const insertPayload = {
    snapshot_date: snapshotDate,
    source_view: SOURCE_VIEW,
    row_count: exportedRows.length,
    holdout_count: holdoutCount,
    correction_count: correctionCount,
    label_counts: labelCounts,
    snapshot_rows: exportedRows,
    export_version: FUNCTION_VERSION,
    created_by: `edge:${FUNCTION_SLUG}`,
  };

  const { data: inserted, error: insertErr } = await db
    .from("training_data_snapshots")
    .insert(insertPayload)
    .select("id, snapshot_date, row_count, created_at")
    .single();

  if (insertErr) {
    if (isDuplicateKeyError(insertErr)) {
      const { data: dupRows } = await db
        .from("training_data_snapshots")
        .select("id, snapshot_date, row_count, created_at")
        .eq("snapshot_date", snapshotDate)
        .limit(1);
      const existing = (dupRows || [])[0] as JsonRecord | undefined;
      return jsonResponse({
        ok: true,
        function_slug: FUNCTION_SLUG,
        version: FUNCTION_VERSION,
        action: "skip_existing_race",
        snapshot_date: snapshotDate,
        snapshot_id: existing?.id || null,
        row_count: existing?.row_count || 0,
        created_at: existing?.created_at || null,
        ms: Date.now() - t0,
      });
    }
    return jsonResponse({
      ok: false,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      error: "snapshot_insert_failed",
      detail: insertErr.message,
      snapshot_date: snapshotDate,
    }, 500);
  }

  // Best-effort lineage/event emission; never block response.
  try {
    await db.from("evidence_events").upsert({
      source_type: "lineage",
      source_id: `training_data_export:${snapshotDate}`,
      source_run_id: `${FUNCTION_SLUG}:${FUNCTION_VERSION}`,
      transcript_variant: "baseline",
      metadata: {
        source: auth.source,
        source_view: SOURCE_VIEW,
        snapshot_date: snapshotDate,
        row_count: exportedRows.length,
        holdout_count: holdoutCount,
        correction_count: correctionCount,
        label_counts: labelCounts,
        edges: [
          { from: `edge:${FUNCTION_SLUG}`, to: `view:public.${SOURCE_VIEW}`, type: "reads" },
          { from: `edge:${FUNCTION_SLUG}`, to: "table:public.training_data_snapshots", type: "writes" },
        ],
      },
    }, { onConflict: "source_type,source_id,transcript_variant" });
  } catch {
    // no-op
  }

  const snapshot = inserted as JsonRecord;
  return jsonResponse({
    ok: true,
    function_slug: FUNCTION_SLUG,
    version: FUNCTION_VERSION,
    action: "snapshot_created",
    snapshot_id: snapshot.id || null,
    snapshot_date: snapshot.snapshot_date || snapshotDate,
    row_count: snapshot.row_count || exportedRows.length,
    holdout_count: holdoutCount,
    correction_count: correctionCount,
    label_counts: labelCounts,
    source_view: SOURCE_VIEW,
    ms: Date.now() - t0,
  });
});
