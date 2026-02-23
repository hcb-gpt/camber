/**
 * review-swarm-scheduler Edge Function v1.0.0
 *
 * Cron-triggered scheduler (every 5 min). Checks backlog metrics
 * and triggers review-swarm-runner when thresholds are met.
 *
 * Trigger signals (any one fires):
 *   open_count >= 150
 *   oldest_age_h > 4
 *   sla_breach > 0  (overrides cooldown)
 *
 * Safety limits:
 *   - 10 min cooldown between runs (unless sla_breach)
 *   - Max 6 runs/hour (hard cap)
 *   - Batch size: 100
 *   - Mode: label_only ONLY (apply_corrections NEVER)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_SLUG = "review-swarm-scheduler";
const FUNCTION_VERSION = "v1.0.0";
const JSON_HEADERS = { "Content-Type": "application/json" };

const TRIGGER_OPEN_COUNT = 150;
const TRIGGER_OLDEST_AGE_H = 4;
const COOLDOWN_MINUTES = 10;
const MAX_RUNS_PER_HOUR = 6;
const BATCH_LIMIT = 100;
const HIGH_VOLUME_THRESHOLD = 500;

const ALLOWED_SOURCES = [
  "review-swarm-scheduler",
  "cron",
  "manual",
  "strat",
];

type JsonRecord = Record<string, unknown>;

function asString(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

function asNumber(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim()) {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

interface TriggerMetrics {
  open_count: number;
  oldest_age_h: number | null;
  sla_breach: number;
}

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  // --- Step 0: Method check ---
  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "method_not_allowed" }, 405);
  }

  // --- Step 1: Auth ---
  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code || "missing_edge_secret");
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL") || "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "",
  );

  // --- Step 2: Query trigger metrics ---
  // Get all needs_review spans
  const { data: unreviewedData, error: unreviewedError } = await db
    .from("span_attributions")
    .select("span_id, attributed_at")
    .eq("needs_review", true);

  if (unreviewedError) {
    return jsonResponse({
      ok: false,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      error: "query_failed",
      detail: unreviewedError.message,
    }, 500);
  }

  // Get already-reviewed span_ids (source = llm_proxy_review)
  const { data: reviewedData, error: reviewedError } = await db
    .from("attribution_validation_feedback")
    .select("span_id")
    .eq("source", "llm_proxy_review");

  if (reviewedError) {
    return jsonResponse({
      ok: false,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      error: "query_failed",
      detail: reviewedError.message,
    }, 500);
  }

  // Client-side: filter unreviewed to exclude those already reviewed
  const reviewedSet = new Set<string>(
    (reviewedData || []).map((r: JsonRecord) => asString(r.span_id)),
  );

  const openSpans = (unreviewedData || []).filter(
    (r: JsonRecord) => !reviewedSet.has(asString(r.span_id)),
  );

  const openCount = openSpans.length;

  // Compute oldest_age_h from attributed_at timestamps
  let oldestAgeH: number | null = null;
  if (openSpans.length > 0) {
    const now = Date.now();
    let minTime = Infinity;
    for (const row of openSpans) {
      const ts = asString((row as JsonRecord).attributed_at);
      if (ts) {
        const t = new Date(ts).getTime();
        if (Number.isFinite(t) && t < minTime) {
          minTime = t;
        }
      }
    }
    if (minTime < Infinity) {
      oldestAgeH = (now - minTime) / (1000 * 3600);
    }
  }

  // Compute sla_breach: spans with attributed_at > 24h ago
  const twentyFourHoursAgo = Date.now() - 24 * 3600 * 1000;
  let slaBreach = 0;
  for (const row of openSpans) {
    const ts = asString((row as JsonRecord).attributed_at);
    if (ts) {
      const t = new Date(ts).getTime();
      if (Number.isFinite(t) && t < twentyFourHoursAgo) {
        slaBreach++;
      }
    }
  }

  const metrics: TriggerMetrics = {
    open_count: openCount,
    oldest_age_h: oldestAgeH,
    sla_breach: slaBreach,
  };

  // --- Step 3: Check triggers ---
  const triggerOpenCount = openCount >= TRIGGER_OPEN_COUNT;
  const triggerOldestAge = oldestAgeH !== null && oldestAgeH > TRIGGER_OLDEST_AGE_H;
  const triggerSlaBreach = slaBreach > 0;
  const shouldTrigger = triggerOpenCount || triggerOldestAge || triggerSlaBreach;

  if (!shouldTrigger) {
    return jsonResponse({
      ok: true,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      action: "skip",
      reason: "no_trigger_met",
      triggers: {
        open_count: openCount,
        oldest_age_h: oldestAgeH,
        sla_breach: slaBreach,
        thresholds: {
          open_count: TRIGGER_OPEN_COUNT,
          oldest_age_h: TRIGGER_OLDEST_AGE_H,
        },
      },
      ms: Date.now() - t0,
    });
  }

  // --- Step 4: Check cooldown ---
  const { data: lastRunData, error: lastRunError } = await db
    .from("attribution_validation_feedback")
    .select("created_at")
    .eq("source", "llm_proxy_review")
    .like("notes", "%auto_%")
    .order("created_at", { ascending: false })
    .limit(1);

  if (lastRunError) {
    return jsonResponse({
      ok: false,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      error: "cooldown_query_failed",
      detail: lastRunError.message,
    }, 500);
  }

  if (lastRunData && lastRunData.length > 0) {
    const lastRunAt = new Date(asString((lastRunData[0] as JsonRecord).created_at)).getTime();
    const minutesSinceLast = (Date.now() - lastRunAt) / (1000 * 60);

    if (minutesSinceLast < COOLDOWN_MINUTES && !triggerSlaBreach) {
      return jsonResponse({
        ok: true,
        function_slug: FUNCTION_SLUG,
        version: FUNCTION_VERSION,
        action: "skip",
        reason: "cooldown_active",
        cooldown_remaining_min: Math.round((COOLDOWN_MINUTES - minutesSinceLast) * 10) / 10,
        triggers: metrics,
        ms: Date.now() - t0,
      });
    }
  }

  // --- Step 5: Check hourly cap ---
  const oneHourAgo = new Date(Date.now() - 3600 * 1000).toISOString();

  const { data: recentRuns, error: recentRunsError } = await db
    .from("attribution_validation_feedback")
    .select("notes")
    .eq("source", "llm_proxy_review")
    .like("notes", "%auto_%")
    .gte("created_at", oneHourAgo);

  if (recentRunsError) {
    return jsonResponse({
      ok: false,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      error: "hourly_cap_query_failed",
      detail: recentRunsError.message,
    }, 500);
  }

  // Count distinct batch_ids from notes (format: "auto_<ts>_<count> | ...")
  const recentBatchIds = new Set<string>();
  for (const row of (recentRuns || []) as JsonRecord[]) {
    const notes = asString(row.notes);
    // Notes format: "batch_id:auto_<ts>_<count> | pool:... | ..."
    // or just starts with "auto_" — extract the batch_id token
    const batchMatch = notes.match(/batch_id:(auto_[^\s|]+)/);
    if (batchMatch) {
      recentBatchIds.add(batchMatch[1]);
    }
  }

  if (recentBatchIds.size >= MAX_RUNS_PER_HOUR) {
    return jsonResponse({
      ok: true,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      action: "skip",
      reason: "hourly_cap_reached",
      runs_this_hour: recentBatchIds.size,
      max_runs_per_hour: MAX_RUNS_PER_HOUR,
      triggers: metrics,
      ms: Date.now() - t0,
    });
  }

  // --- Step 6: Pick reviewer model tier ---
  const reviewerModel = openCount >= HIGH_VOLUME_THRESHOLD ? "full-power" : undefined;

  // --- Step 7: Abort check — re-verify open_count before calling runner ---
  // Re-query to avoid stale data race
  const { data: recheckData } = await db
    .from("span_attributions")
    .select("span_id")
    .eq("needs_review", true);

  const { data: recheckReviewed } = await db
    .from("attribution_validation_feedback")
    .select("span_id")
    .eq("source", "llm_proxy_review");

  const recheckReviewedSet = new Set<string>(
    (recheckReviewed || []).map((r: JsonRecord) => asString(r.span_id)),
  );
  const recheckOpenCount = (recheckData || []).filter(
    (r: JsonRecord) => !recheckReviewedSet.has(asString(r.span_id)),
  ).length;

  // If open_count dropped below all thresholds and no sla_breach, abort
  if (
    recheckOpenCount < TRIGGER_OPEN_COUNT &&
    !triggerOldestAge &&
    !triggerSlaBreach
  ) {
    return jsonResponse({
      ok: true,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      action: "skip",
      reason: "abort_recheck_below_threshold",
      recheck_open_count: recheckOpenCount,
      original_open_count: openCount,
      triggers: metrics,
      ms: Date.now() - t0,
    });
  }

  // --- Step 8: Build batch_id and call runner ---
  const ts = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 15);
  const batchId = `auto_${ts}_${openCount}`;

  const runnerUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/review-swarm-runner`;
  const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET") || "";

  const runnerBody: JsonRecord = {
    mode: "label_only",
    limit: BATCH_LIMIT,
    sampling: "mixed",
    batch_id: batchId,
    source: "review-swarm-scheduler",
  };
  if (reviewerModel) {
    runnerBody.reviewer_model = reviewerModel;
  }

  let runnerResponse: JsonRecord = {};
  let runnerHttpStatus = 0;
  let runnerError: string | null = null;

  try {
    const resp = await fetch(runnerUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Edge-Secret": edgeSecret,
        "X-Source": "review-swarm-scheduler",
      },
      body: JSON.stringify(runnerBody),
    });

    runnerHttpStatus = resp.status;

    const respBody = await resp.json().catch(() => ({}));
    runnerResponse = typeof respBody === "object" && respBody !== null ? respBody as JsonRecord : {};

    if (!resp.ok) {
      runnerError = `runner_http_${resp.status}: ${asString(runnerResponse.error) || "unknown"}`;
    }
  } catch (e: unknown) {
    runnerError = e instanceof Error ? e.message : String(e || "unknown");
  }

  // --- Step 9: Write evidence_events row ---
  const evidencePayload = {
    source_type: "scheduler",
    source_id: batchId,
    transcript_variant: "n/a",
    metadata: {
      scheduler_version: FUNCTION_VERSION,
      open_count: openCount,
      recheck_open_count: recheckOpenCount,
      oldest_age_h: oldestAgeH,
      sla_breach: slaBreach,
      batch_id: batchId,
      runner_http_status: runnerHttpStatus,
      runner_ok: runnerResponse.ok ?? null,
      runner_error: runnerError,
      reviewer_model: reviewerModel || null,
      triggers_fired: {
        open_count: triggerOpenCount,
        oldest_age: triggerOldestAge,
        sla_breach: triggerSlaBreach,
      },
    },
  };

  const { error: evidenceError } = await db
    .from("evidence_events")
    .insert(evidencePayload);

  if (evidenceError) {
    console.error(
      `[${FUNCTION_SLUG}] evidence_events insert failed: ${evidenceError.message}`,
    );
  }

  // --- Step 10: Return summary ---
  const runnerSummary: JsonRecord = {
    ok: runnerResponse.ok ?? null,
    sampled: asNumber(runnerResponse.sampled),
    reviewed: asNumber(runnerResponse.reviewed),
    written: asNumber(runnerResponse.written),
    errors: asNumber(runnerResponse.errors),
    verdict_counts: runnerResponse.verdict_counts ?? null,
  };

  return jsonResponse({
    ok: !runnerError,
    function_slug: FUNCTION_SLUG,
    version: FUNCTION_VERSION,
    action: "ran",
    batch_id: batchId,
    reviewer_model: reviewerModel || null,
    runner_http_status: runnerHttpStatus,
    runner_error: runnerError,
    runner_response_summary: runnerSummary,
    triggers: metrics,
    triggers_fired: {
      open_count: triggerOpenCount,
      oldest_age: triggerOldestAge,
      sla_breach: triggerSlaBreach,
    },
    evidence_logged: !evidenceError,
    ms: Date.now() - t0,
  });
});
