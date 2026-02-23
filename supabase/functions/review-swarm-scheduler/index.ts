/**
 * review-swarm-scheduler Edge Function v1.1.1
 *
 * Cron-triggered scheduler (every 5 min). Checks SSOT backlog
 * (review_queue pending) and triggers review-swarm-runner when
 * thresholds are met.
 *
 * v1.1.1: Fix runner fetch timeout (fire-and-forget pattern).
 * v1.1.0: Aligned to SSOT (review_queue), skip observability.
 *
 * Trigger signals (any one fires):
 *   open_count >= 150  (review_queue pending)
 *   oldest_age_h > 4   (oldest pending item)
 *   sla_breach > 0     (pending > 24h, overrides cooldown)
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
const FUNCTION_VERSION = "v1.1.1";
const JSON_HEADERS = { "Content-Type": "application/json" };

const TRIGGER_OPEN_COUNT = 150;
const TRIGGER_OLDEST_AGE_H = 4;
const COOLDOWN_MINUTES = 10;
const MAX_RUNS_PER_HOUR = 6;
const BATCH_LIMIT = 100;
const HIGH_VOLUME_THRESHOLD = 500;
const RUNNER_FETCH_TIMEOUT_MS = 10_000;

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

  try {
    // --- Step 1: Auth ---
    const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
    if (!auth.ok) {
      return authErrorResponse(auth.error_code || "missing_edge_secret");
    }

    const db = createClient(
      Deno.env.get("SUPABASE_URL") || "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "",
    );

    // --- Step 2: Query trigger metrics from SSOT (review_queue) ---
    const { data: pendingData, error: pendingError } = await db
      .from("review_queue")
      .select("id, span_id, created_at")
      .eq("status", "pending");

    if (pendingError) {
      return jsonResponse({
        ok: false,
        function_slug: FUNCTION_SLUG,
        version: FUNCTION_VERSION,
        error: "query_failed",
        detail: pendingError.message,
      }, 500);
    }

    const pendingRows = pendingData || [];
    const openCount = pendingRows.length;

    // Compute oldest_age_h from review_queue.created_at
    let oldestAgeH: number | null = null;
    if (pendingRows.length > 0) {
      const now = Date.now();
      let minTime = Infinity;
      for (const row of pendingRows) {
        const ts = asString((row as JsonRecord).created_at);
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

    // Compute sla_breach: pending items older than 24h
    const twentyFourHoursAgo = Date.now() - 24 * 3600 * 1000;
    let slaBreach = 0;
    for (const row of pendingRows) {
      const ts = asString((row as JsonRecord).created_at);
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
      // Skip observability: log why we skipped
      await db.from("evidence_events").insert({
        source_type: "scheduler",
        source_id: `skip_${new Date().toISOString().replace(/[-:T]/g, "").slice(0, 15)}`,
        transcript_variant: null,
        metadata: {
          scheduler_version: FUNCTION_VERSION,
          action: "skip",
          reason: "no_trigger_met",
          backlog_source: "review_queue",
          open_count: openCount,
          oldest_age_h: oldestAgeH,
          sla_breach: slaBreach,
          thresholds: { open_count: TRIGGER_OPEN_COUNT, oldest_age_h: TRIGGER_OLDEST_AGE_H },
          ms: Date.now() - t0,
        },
      }).then(() => {}, () => {}); // fire-and-forget
      return jsonResponse({
        ok: true,
        function_slug: FUNCTION_SLUG,
        version: FUNCTION_VERSION,
        action: "skip",
        reason: "no_trigger_met",
        backlog_source: "review_queue",
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
    // Re-query review_queue to avoid stale data race
    const { data: recheckData } = await db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending");

    const recheckOpenCount = recheckData?.length ?? openCount;

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

    // Fire runner with a short timeout. The runner processes spans asynchronously
    // and may take minutes. We only need to confirm the request was accepted.
    let runnerHttpStatus = 0;
    let runnerError: string | null = null;
    let runnerAccepted = false;

    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), RUNNER_FETCH_TIMEOUT_MS);

      const resp = await fetch(runnerUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": edgeSecret,
          "X-Source": "review-swarm-scheduler",
        },
        body: JSON.stringify(runnerBody),
        signal: controller.signal,
      });

      clearTimeout(timeoutId);
      runnerHttpStatus = resp.status;
      runnerAccepted = resp.ok;

      if (!resp.ok) {
        const respBody = await resp.json().catch(() => ({}));
        const errBody = typeof respBody === "object" && respBody !== null ? respBody as JsonRecord : {};
        runnerError = `runner_http_${resp.status}: ${asString(errBody.error) || "unknown"}`;
      }
      // If runner responded OK, don't block reading the full body — it may be large.
    } catch (e: unknown) {
      if (e instanceof DOMException && e.name === "AbortError") {
        // Timeout is OK — runner is still processing in the background.
        runnerAccepted = true;
        runnerError = null;
        runnerHttpStatus = 202; // Treat as accepted
      } else {
        runnerError = e instanceof Error ? e.message : String(e || "unknown");
      }
    }

    // --- Step 9: Write evidence_events row ---
    const evidencePayload = {
      source_type: "scheduler",
      source_id: batchId,
      transcript_variant: "n/a",
      metadata: {
        scheduler_version: FUNCTION_VERSION,
        backlog_source: "review_queue",
        open_count: openCount,
        recheck_open_count: recheckOpenCount,
        oldest_age_h: oldestAgeH,
        sla_breach: slaBreach,
        batch_id: batchId,
        runner_http_status: runnerHttpStatus,
        runner_accepted: runnerAccepted,
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
    return jsonResponse({
      ok: runnerAccepted,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      action: "ran",
      batch_id: batchId,
      reviewer_model: reviewerModel || null,
      runner_http_status: runnerHttpStatus,
      runner_accepted: runnerAccepted,
      runner_error: runnerError,
      triggers: metrics,
      triggers_fired: {
        open_count: triggerOpenCount,
        oldest_age: triggerOldestAge,
        sla_breach: triggerSlaBreach,
      },
      evidence_logged: !evidenceError,
      ms: Date.now() - t0,
    });
  } catch (fatal: unknown) {
    return jsonResponse({
      ok: false,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      error: "uncaught_exception",
      detail: fatal instanceof Error ? fatal.message : String(fatal || "unknown"),
      ms: Date.now() - t0,
    }, 500);
  }
});
