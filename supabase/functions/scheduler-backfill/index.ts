/**
 * scheduler-backfill Edge Function v1.0.0
 *
 * Epic 1.2: Run time_resolver against scheduler_items (and optionally
 * journal_open_loops) that have temporal language but no resolved timestamps.
 *
 * - Processes in batches (default 50)
 * - AUTO-WRITES start_at_utc / due_at_utc for HIGH confidence only (CONFIRMED)
 * - Logs every resolution to time_resolution_audit
 * - Dry-run mode available (apply=false)
 *
 * Auth: Internal only (EDGE_SHARED_SECRET)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { resolveTime, type TimeResolution } from "../_shared/time_resolver.ts";

const FUNCTION_VERSION = "v1.2.0";

// ISO 8601 date patterns — these are already resolved and can be written directly
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$/;

function tryParseIsoHint(hint: string): TimeResolution | null {
  if (!ISO_DATE_RE.test(hint.trim())) return null;
  const parsed = new Date(hint.trim());
  if (isNaN(parsed.getTime())) return null;
  const iso = parsed.toISOString();
  return {
    start_at_utc: iso,
    end_at_utc: null,
    due_at_utc: iso,
    confidence: "HIGH",
    needs_review: false,
    reason_code: "iso_passthrough",
    evidence_quote: hint,
    timezone: "UTC",
  };
}
const DEFAULT_BATCH_SIZE = 50;
const MAX_BATCH_SIZE = 200;
const DEFAULT_LIMIT = 500;
const MAX_LIMIT = 5000;
const ALLOWED_SOURCES = ["strat", "operator", "dev", "scheduler-backfill"];
// Only auto-write for HIGH confidence (= CONFIRMED per Epic 1.2 directive).
// MEDIUM, TENTATIVE, LOW are flagged in audit but NOT written back.
const AUTO_APPLY_CONFIDENCES = new Set(["HIGH"]);

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

interface BackfillStats {
  processed: number;
  applied: number;
  skipped_low_confidence: number;
  skipped_empty_resolution: number;
  errors: number;
  by_confidence: Record<string, number>;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed", function_version: FUNCTION_VERSION }, 405);
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) return authErrorResponse(auth.error_code || "auth_failed");

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !supabaseKey) {
    return json({ ok: false, error: "missing_supabase_config" }, 500);
  }
  const db = createClient(supabaseUrl, supabaseKey);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // defaults
  }

  const target = String(body.target ?? "scheduler_items");
  const batchSize = clamp(Number(body.batch_size) || DEFAULT_BATCH_SIZE, 1, MAX_BATCH_SIZE);
  const limit = clamp(Number(body.limit) || DEFAULT_LIMIT, 1, MAX_LIMIT);
  const apply = body.apply !== false; // default true
  const runId = `backfill_${Date.now()}_${crypto.randomUUID().slice(0, 8)}`;

  if (target === "scheduler_items") {
    return await backfillSchedulerItems(db, { batchSize, limit, apply, runId });
  } else if (target === "journal_open_loops") {
    return await backfillOpenLoops(db, { batchSize, limit, apply, runId });
  } else {
    return json({ ok: false, error: "invalid_target", valid: ["scheduler_items", "journal_open_loops"] }, 400);
  }
});

interface BackfillOptions {
  batchSize: number;
  limit: number;
  apply: boolean;
  runId: string;
}

async function writeRunSummary(
  db: ReturnType<typeof createClient>,
  runId: string,
  target: string,
  stats: BackfillStats,
  startedAt: number,
): Promise<void> {
  await db.from("backfill_runs").insert({
    run_id: runId,
    source_table: target,
    rows_processed: stats.processed,
    rows_resolved: stats.applied,
    rows_needs_review: stats.skipped_low_confidence,
    rows_failed: stats.errors,
    rows_empty: stats.skipped_empty_resolution,
    confidence_breakdown: stats.by_confidence,
    duration_ms: Date.now() - startedAt,
  }).then(({ error }) => {
    if (error) console.error("[backfill_runs] insert failed:", error.message);
  });
}

async function backfillSchedulerItems(
  db: ReturnType<typeof createClient>,
  opts: BackfillOptions,
): Promise<Response> {
  const startedAt = Date.now();
  const stats: BackfillStats = {
    processed: 0,
    applied: 0,
    skipped_low_confidence: 0,
    skipped_empty_resolution: 0,
    errors: 0,
    by_confidence: {},
  };

  // Fetch rows with time_hint but no resolved timestamps
  const { data: rows, error: fetchErr } = await db
    .from("scheduler_items")
    .select("id, time_hint, created_at, start_at_utc, due_at_utc")
    .not("time_hint", "is", null)
    .neq("time_hint", "")
    .is("start_at_utc", null)
    .is("due_at_utc", null)
    .order("created_at", { ascending: true })
    .limit(opts.limit);

  if (fetchErr) {
    return json({ ok: false, error: "fetch_failed", detail: fetchErr.message }, 500);
  }

  if (!rows || rows.length === 0) {
    return json({
      ok: true,
      run_id: opts.runId,
      message: "no_rows_to_backfill",
      stats,
      function_version: FUNCTION_VERSION,
    });
  }

  // Process in batches
  for (let i = 0; i < rows.length; i += opts.batchSize) {
    const batch = rows.slice(i, i + opts.batchSize);
    const auditRows: Record<string, unknown>[] = [];
    const updates: { id: string; start_at_utc: string | null; due_at_utc: string | null }[] = [];

    for (const row of batch) {
      stats.processed++;

      try {
        // Fast path: ISO dates are already resolved
        const resolution = tryParseIsoHint(row.time_hint) ?? resolveTime(
          row.time_hint,
          row.created_at || new Date().toISOString(),
          { timezone: "America/New_York" },
        );

        stats.by_confidence[resolution.confidence] = (stats.by_confidence[resolution.confidence] || 0) + 1;

        // Build audit row
        auditRows.push({
          source_table: "scheduler_items",
          source_id: row.id,
          time_hint: row.time_hint,
          anchor_ts: row.created_at,
          start_at_utc: resolution.start_at_utc,
          end_at_utc: resolution.end_at_utc,
          due_at_utc: resolution.due_at_utc,
          confidence: resolution.confidence,
          needs_review: resolution.needs_review,
          reason_code: resolution.reason_code,
          evidence_quote: resolution.evidence_quote,
          timezone: resolution.timezone,
          applied: false, // updated below if we apply
          backfill_run_id: opts.runId,
        });

        if (!resolution.start_at_utc && !resolution.due_at_utc) {
          stats.skipped_empty_resolution++;
          continue;
        }

        if (opts.apply && AUTO_APPLY_CONFIDENCES.has(resolution.confidence)) {
          updates.push({
            id: row.id,
            start_at_utc: resolution.start_at_utc,
            due_at_utc: resolution.due_at_utc,
          });
          // Mark as applied in audit
          auditRows[auditRows.length - 1].applied = true;
          stats.applied++;
        } else {
          stats.skipped_low_confidence++;
        }
      } catch (e) {
        stats.errors++;
        auditRows.push({
          source_table: "scheduler_items",
          source_id: row.id,
          time_hint: row.time_hint,
          anchor_ts: row.created_at,
          confidence: "LOW",
          needs_review: true,
          reason_code: `resolver_error: ${(e as Error).message?.slice(0, 200)}`,
          applied: false,
          backfill_run_id: opts.runId,
        });
      }
    }

    // Write audit rows
    if (auditRows.length > 0) {
      const { error: auditErr } = await db.from("time_resolution_audit").insert(auditRows);
      if (auditErr) {
        return json({
          ok: false,
          error: "audit_insert_failed",
          detail: auditErr.message,
          stats,
          run_id: opts.runId,
        }, 500);
      }
    }

    // Apply updates to scheduler_items
    if (updates.length > 0) {
      for (const upd of updates) {
        const updatePayload: Record<string, string | null> = {};
        if (upd.start_at_utc) updatePayload.start_at_utc = upd.start_at_utc;
        if (upd.due_at_utc) updatePayload.due_at_utc = upd.due_at_utc;

        const { error: updErr } = await db
          .from("scheduler_items")
          .update(updatePayload)
          .eq("id", upd.id);

        if (updErr) {
          stats.errors++;
        }
      }
    }
  }

  await writeRunSummary(db, opts.runId, "scheduler_items", stats, startedAt);

  return json({
    ok: true,
    run_id: opts.runId,
    target: "scheduler_items",
    total_eligible: rows.length,
    apply_mode: opts.apply,
    stats,
    function_version: FUNCTION_VERSION,
  });
}

async function backfillOpenLoops(
  db: ReturnType<typeof createClient>,
  opts: BackfillOptions,
): Promise<Response> {
  const startedAt = Date.now();
  const stats: BackfillStats = {
    processed: 0,
    applied: 0,
    skipped_low_confidence: 0,
    skipped_empty_resolution: 0,
    errors: 0,
    by_confidence: {},
  };

  // Open loops: extract temporal hints from description text
  // No dedicated time column to write back — audit-only
  const { data: rows, error: fetchErr } = await db
    .from("journal_open_loops")
    .select("id, description, created_at, status")
    .eq("status", "open")
    .not("description", "is", null)
    .order("created_at", { ascending: true })
    .limit(opts.limit);

  if (fetchErr) {
    return json({ ok: false, error: "fetch_failed", detail: fetchErr.message }, 500);
  }

  if (!rows || rows.length === 0) {
    return json({
      ok: true,
      run_id: opts.runId,
      message: "no_rows_to_backfill",
      stats,
      function_version: FUNCTION_VERSION,
    });
  }

  // Idempotency: fetch IDs already processed in a prior backfill run
  const { data: alreadyAudited } = await db
    .from("time_resolution_audit")
    .select("source_id")
    .eq("source_table", "journal_open_loops")
    .in("source_id", rows.map((r: { id: string }) => r.id));
  const alreadyProcessed = new Set((alreadyAudited ?? []).map((r: { source_id: string }) => r.source_id));

  // Temporal pattern to extract time hints from descriptions
  const TEMPORAL_RE =
    /\b(today|tomorrow|tonight|this week|next week|this morning|this afternoon|this evening|monday|tuesday|wednesday|thursday|friday|saturday|sunday|end of day|eod|asap|by \w+day|within \d+ (?:day|week|hour)|in \d+ (?:day|week|hour)|(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2})\b/i;

  for (let i = 0; i < rows.length; i += opts.batchSize) {
    const batch = rows.slice(i, i + opts.batchSize);
    const auditRows: Record<string, unknown>[] = [];

    for (const row of batch) {
      if (alreadyProcessed.has(row.id)) continue; // idempotency guard
      const match = row.description?.match(TEMPORAL_RE);
      if (!match) continue;

      stats.processed++;
      const timeHint = match[0];

      try {
        const resolution = resolveTime(
          timeHint,
          row.created_at || new Date().toISOString(),
          { timezone: "America/New_York" },
        );

        stats.by_confidence[resolution.confidence] = (stats.by_confidence[resolution.confidence] || 0) + 1;

        auditRows.push({
          source_table: "journal_open_loops",
          source_id: row.id,
          time_hint: timeHint,
          anchor_ts: row.created_at,
          start_at_utc: resolution.start_at_utc,
          end_at_utc: resolution.end_at_utc,
          due_at_utc: resolution.due_at_utc,
          confidence: resolution.confidence,
          needs_review: resolution.needs_review,
          reason_code: resolution.reason_code,
          evidence_quote: row.description?.slice(0, 200),
          timezone: resolution.timezone,
          applied: false, // open_loops has no time columns to write back
          backfill_run_id: opts.runId,
        });

        if (!resolution.start_at_utc && !resolution.due_at_utc) {
          stats.skipped_empty_resolution++;
        } else if (AUTO_APPLY_CONFIDENCES.has(resolution.confidence)) {
          stats.applied++; // counted but not written (no target column)
        } else {
          stats.skipped_low_confidence++;
        }
      } catch (e) {
        stats.errors++;
        auditRows.push({
          source_table: "journal_open_loops",
          source_id: row.id,
          time_hint: timeHint,
          anchor_ts: row.created_at,
          confidence: "LOW",
          needs_review: true,
          reason_code: `resolver_error: ${(e as Error).message?.slice(0, 200)}`,
          applied: false,
          backfill_run_id: opts.runId,
        });
      }
    }

    if (auditRows.length > 0) {
      const { error: auditErr } = await db.from("time_resolution_audit").insert(auditRows);
      if (auditErr) {
        return json({
          ok: false,
          error: "audit_insert_failed",
          detail: auditErr.message,
          stats,
          run_id: opts.runId,
        }, 500);
      }
    }
  }

  await writeRunSummary(db, opts.runId, "journal_open_loops", stats, startedAt);

  return json({
    ok: true,
    run_id: opts.runId,
    target: "journal_open_loops",
    total_scanned: rows.length,
    apply_mode: false, // open_loops never auto-applies (no time columns)
    stats,
    function_version: FUNCTION_VERSION,
  });
}
