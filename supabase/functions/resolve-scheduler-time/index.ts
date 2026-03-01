/**
 * resolve-scheduler-time Edge Function v1.0.0
 *
 * Orchestrator that wires time-resolver logic into the scheduler pipeline.
 * Called by:
 *   - DB trigger on scheduler_items (via pg_net) for real-time resolution
 *   - Manual POST ?action=backfill for batch backfill of stuck items
 *
 * Flow:
 *   1. Receive scheduler_item_id (single) or fetch batch of unresolved items
 *   2. Call resolveTime() from shared module (no network hop)
 *   3. Write to time_resolution_audit (always)
 *   4. Write to scheduler_items (only if confidence >= MEDIUM, per Gemini review)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { resolveTime } from "../_shared/time_resolver.ts";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_VERSION = "resolve-scheduler-time_v1.0.0";
const ALLOWED_SOURCES = [
  "scheduler-trigger",
  "backfill",
  "test",
  "strat",
  "operator",
];
const DEFAULT_BACKFILL_LIMIT = 200;
const MAX_BACKFILL_LIMIT = 1000;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

interface ResolveResult {
  scheduler_item_id: string;
  time_hint: string;
  confidence: string;
  reason_code: string;
  applied: boolean;
  start_at_utc: string | null;
  due_at_utc: string | null;
}

async function resolveOneItem(
  db: ReturnType<typeof createClient>,
  itemId: string,
  timeHint: string,
  anchorTs: string,
  backfillRunId: string,
): Promise<ResolveResult> {
  const resolution = resolveTime(timeHint, anchorTs, {
    timezone: "America/New_York",
  });

  // Always write audit entry
  const { error: auditErr } = await db.from("time_resolution_audit").insert({
    source_table: "scheduler_items",
    source_id: itemId,
    time_hint: timeHint,
    anchor_ts: anchorTs,
    start_at_utc: resolution.start_at_utc,
    end_at_utc: resolution.end_at_utc,
    due_at_utc: resolution.due_at_utc,
    confidence: resolution.confidence,
    needs_review: resolution.needs_review,
    reason_code: resolution.reason_code,
    evidence_quote: resolution.evidence_quote,
    timezone: resolution.timezone,
    applied: false, // will update after scheduler_items write
    backfill_run_id: backfillRunId,
  });

  if (auditErr) {
    console.error(JSON.stringify({
      msg: "audit_insert_failed",
      scheduler_item_id: itemId,
      error: auditErr.message,
      version: FUNCTION_VERSION,
    }));
  }

  // Only write to scheduler_items if confidence >= MEDIUM
  // TENTATIVE and LOW go to audit only (per Gemini peer review)
  const shouldApply = resolution.confidence === "HIGH" || resolution.confidence === "MEDIUM";

  if (shouldApply && (resolution.start_at_utc || resolution.due_at_utc)) {
    const updatePayload: Record<string, unknown> = {
      updated_at: new Date().toISOString(),
    };

    if (resolution.start_at_utc) {
      updatePayload.start_at_utc = resolution.start_at_utc;
      updatePayload.window_start_utc = resolution.start_at_utc;
    }
    if (resolution.end_at_utc) {
      updatePayload.window_end_utc = resolution.end_at_utc;
    }
    if (resolution.due_at_utc) {
      updatePayload.due_at_utc = resolution.due_at_utc;
    }
    if (resolution.needs_review) {
      updatePayload.needs_review = true;
    }
    if (resolution.evidence_quote) {
      updatePayload.evidence_quote = resolution.evidence_quote;
    }

    // Only update items that still have no timestamps (idempotent guard)
    const { error: updateErr } = await db
      .from("scheduler_items")
      .update(updatePayload)
      .eq("id", itemId)
      .is("start_at_utc", null)
      .is("due_at_utc", null);

    if (updateErr) {
      console.error(JSON.stringify({
        msg: "scheduler_item_update_failed",
        scheduler_item_id: itemId,
        error: updateErr.message,
        version: FUNCTION_VERSION,
      }));
    } else {
      // Mark audit entry as applied
      await db
        .from("time_resolution_audit")
        .update({ applied: true })
        .eq("source_id", itemId)
        .eq("backfill_run_id", backfillRunId);
    }

    return {
      scheduler_item_id: itemId,
      time_hint: timeHint,
      confidence: resolution.confidence,
      reason_code: resolution.reason_code,
      applied: !updateErr,
      start_at_utc: resolution.start_at_utc,
      due_at_utc: resolution.due_at_utc,
    };
  }

  // TENTATIVE/LOW → audit only
  if (resolution.confidence === "TENTATIVE" && resolution.due_at_utc) {
    // Write tentative_resolved_at as a hint, but don't set the real timestamps
    await db
      .from("scheduler_items")
      .update({
        tentative_resolved_at: resolution.due_at_utc,
        needs_review: true,
        updated_at: new Date().toISOString(),
      })
      .eq("id", itemId)
      .is("tentative_resolved_at", null);
  }

  return {
    scheduler_item_id: itemId,
    time_hint: timeHint,
    confidence: resolution.confidence,
    reason_code: resolution.reason_code,
    applied: false,
    start_at_utc: resolution.start_at_utc,
    due_at_utc: resolution.due_at_utc,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed", function_version: FUNCTION_VERSION }, 405);
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) return authErrorResponse(auth.error_code || "auth_failed");

  const t0 = Date.now();
  const url = new URL(req.url);
  const action = url.searchParams.get("action");

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseKey) {
    return json({ ok: false, error: "missing_supabase_config", function_version: FUNCTION_VERSION }, 500);
  }

  const db = createClient(supabaseUrl, supabaseKey);

  try {
    // ── Backfill mode: batch-resolve unresolved items ──────────────────
    if (action === "backfill") {
      const rawLimit = parseInt(url.searchParams.get("limit") || String(DEFAULT_BACKFILL_LIMIT), 10);
      const limit = Math.min(Math.max(isNaN(rawLimit) ? DEFAULT_BACKFILL_LIMIT : rawLimit, 1), MAX_BACKFILL_LIMIT);
      const backfillRunId = `backfill_${Date.now()}_${crypto.randomUUID().slice(0, 8)}`;

      // Fetch items with time_hint but no resolved timestamps
      const { data: items, error: fetchErr } = await db
        .from("scheduler_items")
        .select("id, time_hint, interaction_id, created_at")
        .not("time_hint", "is", null)
        .neq("time_hint", "")
        .is("start_at_utc", null)
        .is("due_at_utc", null)
        .order("created_at", { ascending: true })
        .limit(limit);

      if (fetchErr) {
        return json({ ok: false, error: "fetch_failed", detail: fetchErr.message, function_version: FUNCTION_VERSION }, 500);
      }

      if (!items || items.length === 0) {
        return json({
          ok: true,
          action: "backfill",
          backfill_run_id: backfillRunId,
          processed: 0,
          remaining: 0,
          function_version: FUNCTION_VERSION,
          elapsed_ms: Date.now() - t0,
        });
      }

      // Fetch anchor timestamps from interactions
      const interactionIds = [...new Set(items.map((i: any) => i.interaction_id).filter(Boolean))];
      let anchorMap = new Map<string, string>();

      if (interactionIds.length > 0) {
        const { data: interactions } = await db
          .from("interactions")
          .select("id, event_at_utc")
          .in("id", interactionIds);

        if (interactions) {
          for (const row of interactions as any[]) {
            if (row.event_at_utc) anchorMap.set(row.id, row.event_at_utc);
          }
        }
      }

      const results: ResolveResult[] = [];
      for (const item of items as any[]) {
        const anchorTs = anchorMap.get(item.interaction_id) || item.created_at;
        const result = await resolveOneItem(db, item.id, item.time_hint, anchorTs, backfillRunId);
        results.push(result);
      }

      // Count remaining
      const { count: remaining } = await db
        .from("scheduler_items")
        .select("id", { count: "exact", head: true })
        .not("time_hint", "is", null)
        .neq("time_hint", "")
        .is("start_at_utc", null)
        .is("due_at_utc", null);

      const applied = results.filter((r) => r.applied).length;
      const tentative = results.filter((r) => r.confidence === "TENTATIVE").length;
      const low = results.filter((r) => r.confidence === "LOW").length;

      console.log(JSON.stringify({
        msg: "backfill_complete",
        backfill_run_id: backfillRunId,
        processed: results.length,
        applied,
        tentative,
        low,
        remaining: remaining ?? "unknown",
        elapsed_ms: Date.now() - t0,
        version: FUNCTION_VERSION,
      }));

      return json({
        ok: true,
        action: "backfill",
        backfill_run_id: backfillRunId,
        processed: results.length,
        applied,
        tentative,
        low,
        remaining: remaining ?? "unknown",
        function_version: FUNCTION_VERSION,
        elapsed_ms: Date.now() - t0,
        results,
      });
    }

    // ── Single-item mode: from DB trigger or direct call ────────────────
    const body = await req.json().catch(() => ({}));
    const schedulerItemId = typeof body?.scheduler_item_id === "string" ? body.scheduler_item_id : null;
    const timeHint = typeof body?.time_hint === "string" ? body.time_hint : null;
    const anchorTs = typeof body?.anchor_ts === "string" ? body.anchor_ts : null;
    const interactionId = typeof body?.interaction_id === "string" ? body.interaction_id : null;

    if (!schedulerItemId) {
      return json({
        ok: false,
        error: "missing_scheduler_item_id",
        function_version: FUNCTION_VERSION,
      }, 400);
    }

    // If time_hint not provided in payload, fetch from DB
    let resolvedHint = timeHint;
    let resolvedAnchor = anchorTs;

    if (!resolvedHint || !resolvedAnchor) {
      const { data: item, error: itemErr } = await db
        .from("scheduler_items")
        .select("time_hint, interaction_id, created_at")
        .eq("id", schedulerItemId)
        .maybeSingle();

      if (itemErr || !item) {
        return json({
          ok: false,
          error: "item_not_found",
          scheduler_item_id: schedulerItemId,
          function_version: FUNCTION_VERSION,
        }, 404);
      }

      resolvedHint = resolvedHint || item.time_hint;
      if (!resolvedAnchor && item.interaction_id) {
        const { data: interaction } = await db
          .from("interactions")
          .select("event_at_utc")
          .eq("id", item.interaction_id)
          .maybeSingle();
        resolvedAnchor = interaction?.event_at_utc || item.created_at;
      }
      resolvedAnchor = resolvedAnchor || item.created_at;
    }

    if (!resolvedHint) {
      return json({
        ok: false,
        error: "no_time_hint",
        scheduler_item_id: schedulerItemId,
        function_version: FUNCTION_VERSION,
      }, 400);
    }

    const runId = `trigger_${Date.now()}_${crypto.randomUUID().slice(0, 8)}`;
    const result = await resolveOneItem(db, schedulerItemId, resolvedHint, resolvedAnchor!, runId);

    console.log(JSON.stringify({
      msg: "single_resolve",
      ...result,
      source: auth.source,
      elapsed_ms: Date.now() - t0,
      version: FUNCTION_VERSION,
    }));

    return json({
      ok: true,
      function_version: FUNCTION_VERSION,
      source: auth.source,
      elapsed_ms: Date.now() - t0,
      result,
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(JSON.stringify({ msg: "resolve_error", error: message, version: FUNCTION_VERSION }));
    return json({
      ok: false,
      error: "internal_error",
      detail: message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
});
