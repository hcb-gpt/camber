/**
 * review-swarm-runner Edge Function v0.1.0
 *
 * Automated LLM proxy reviewer: samples spans via mixed sampling,
 * calls audit-attribution-reviewer for each, maps verdicts to
 * attribution_validation_feedback rows.
 *
 * Modes:
 *   dry_run    — sample + review, no DB writes
 *   label_only — sample + review + write feedback (default)
 *   apply_corrections — HARD-GATED OFF in v1
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_SLUG = "review-swarm-runner";
const FUNCTION_VERSION = "v0.1.1";
const JSON_HEADERS = { "Content-Type": "application/json" };
const DEFAULT_LIMIT = 5;
const MAX_LIMIT = 5;
const REVIEWER_TIMEOUT_MS = 30000;
const BACKLOG_RATIO = 0.5;

const ALLOWED_SOURCES = [
  "review-swarm-runner",
  "review-swarm-scheduler",
  "manual",
  "cron",
  "strat",
];

type JsonRecord = Record<string, unknown>;

function asString(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

function asRecord(v: unknown): JsonRecord {
  return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as JsonRecord) : {};
}

function asNumber(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim()) {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

interface SampledSpan {
  span_id: string;
  interaction_id: string;
  span_index: number;
  char_start: number | null;
  char_end: number | null;
  transcript_segment: string;
  sa_id: string;
  project_id: string | null;
  applied_project_id: string | null;
  decision: string;
  confidence: number | null;
  evidence_tier: number | null;
  attribution_source: string | null;
  needs_review: boolean;
  project_name: string | null;
  pool: "backlog" | "calibration";
}

interface ReviewResult {
  span_id: string;
  interaction_id: string;
  pool: string;
  reviewer_verdict: string;
  mapped_verdict: string;
  reviewer_notes: string;
  reviewer_ms: number;
  reviewer_error: string | null;
  written: boolean;
  write_error: string | null;
  queue_updated: boolean;
  queue_error: string | null;
}

function mapVerdict(
  reviewerVerdict: string,
): "CORRECT" | "INCORRECT" | "UNSURE" {
  switch (reviewerVerdict) {
    case "MATCH":
      return "CORRECT";
    case "MISMATCH":
      return "INCORRECT";
    default:
      return "UNSURE";
  }
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

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

  const mode = asString(body.mode) || "label_only";
  if (mode === "apply_corrections") {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "apply_corrections_hard_gated_off",
        detail: "apply_corrections is disabled in v1. Use label_only.",
      }),
      { status: 400, headers: JSON_HEADERS },
    );
  }
  if (mode !== "dry_run" && mode !== "label_only") {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "invalid_mode",
        detail: "Allowed modes: dry_run, label_only",
      }),
      { status: 400, headers: JSON_HEADERS },
    );
  }

  const rawLimit = asNumber(body.limit) ?? DEFAULT_LIMIT;
  const limit = Math.min(Math.max(1, Math.round(rawLimit)), MAX_LIMIT);
  const batchId = asString(body.batch_id) ||
    `swarm_${new Date().toISOString().replace(/[-:T]/g, "").slice(0, 15)}`;
  const reviewerModel = asString(body.reviewer_model) || undefined;

  const db = createClient(
    Deno.env.get("SUPABASE_URL") || "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "",
  );

  // --- Mixed sampling ---
  const backlogLimit = Math.ceil(limit * BACKLOG_RATIO);
  const calibLimit = limit - backlogLimit;

  // Pre-fetch already-reviewed span_ids for client-side dedup
  const { data: reviewedRows } = await db
    .from("attribution_validation_feedback")
    .select("span_id")
    .eq("source", "llm_proxy_review");
  const reviewedSet = new Set<string>(
    (reviewedRows || []).map((r: JsonRecord) => asString(r.span_id)),
  );

  // Query FROM span_attributions with embedded conversation_spans
  // (reversed direction avoids !inner join which requires PostgREST 10.1+)
  const saSelectCols = `
    id,
    span_id,
    project_id,
    applied_project_id,
    decision,
    confidence,
    evidence_tier,
    attribution_source,
    needs_review,
    conversation_spans (
      id,
      interaction_id,
      span_index,
      char_start,
      char_end,
      transcript_segment
    )
  `;

  // Fetch generously to account for already-reviewed spans being filtered out
  const fetchLimit = 1000;

  const [backlogResp, calibResp] = await Promise.all([
    db
      .from("span_attributions")
      .select(saSelectCols)
      .eq("needs_review", true)
      .limit(fetchLimit),
    db
      .from("span_attributions")
      .select(saSelectCols)
      .eq("needs_review", false)
      .gte("confidence", 0.55)
      .lte("confidence", 0.85)
      .limit(fetchLimit),
  ]);

  if (backlogResp.error || calibResp.error) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "sampling_failed",
        detail: backlogResp.error?.message || calibResp.error?.message,
      }),
      { status: 500, headers: JSON_HEADERS },
    );
  }

  const backlogRows = backlogResp.data || [];
  const calibRows = calibResp.data || [];

  // Flatten, dedupe, and exclude already-reviewed
  const allSpanIds = new Set<string>();
  const sampled: SampledSpan[] = [];

  // Row shape: span_attributions fields at top, conversation_spans embedded
  function flattenRow(
    row: JsonRecord,
    pool: "backlog" | "calibration",
  ): SampledSpan | null {
    const spanId = asString(row.span_id);
    if (!spanId || allSpanIds.has(spanId) || reviewedSet.has(spanId)) {
      return null;
    }
    allSpanIds.add(spanId);
    const cs = asRecord(row.conversation_spans);
    return {
      span_id: spanId,
      interaction_id: asString(cs.interaction_id),
      span_index: asNumber(cs.span_index) ?? 0,
      char_start: asNumber(cs.char_start),
      char_end: asNumber(cs.char_end),
      transcript_segment: asString(cs.transcript_segment),
      sa_id: asString(row.id),
      project_id: asString(row.project_id) || null,
      applied_project_id: asString(row.applied_project_id) || null,
      decision: asString(row.decision),
      confidence: asNumber(row.confidence),
      evidence_tier: asNumber(row.evidence_tier),
      attribution_source: asString(row.attribution_source) || null,
      needs_review: row.needs_review === true,
      project_name: null,
      pool,
    };
  }

  let backlogCount = 0;
  for (const row of backlogRows as JsonRecord[]) {
    if (backlogCount >= backlogLimit) break;
    const s = flattenRow(row, "backlog");
    if (s) {
      sampled.push(s);
      backlogCount++;
    }
  }
  let calibCount = 0;
  for (const row of calibRows as JsonRecord[]) {
    if (calibCount >= calibLimit) break;
    const s = flattenRow(row, "calibration");
    if (s) {
      sampled.push(s);
      calibCount++;
    }
  }

  if (sampled.length === 0) {
    return new Response(
      JSON.stringify({
        ok: true,
        function_slug: FUNCTION_SLUG,
        version: FUNCTION_VERSION,
        mode,
        batch_id: batchId,
        sampled: 0,
        message: "no_eligible_spans",
        ms: Date.now() - t0,
      }),
      { status: 200, headers: JSON_HEADERS },
    );
  }

  // Lookup project names
  const projectIds = [
    ...new Set(
      sampled.map((s) => s.project_id).filter((id): id is string => Boolean(id)),
    ),
  ];
  if (projectIds.length > 0) {
    const { data: projects } = await db
      .from("projects")
      .select("id, name")
      .in("id", projectIds);
    if (projects) {
      const nameMap = new Map<string, string>();
      for (const p of projects as JsonRecord[]) {
        nameMap.set(asString(p.id), asString(p.name));
      }
      for (const s of sampled) {
        if (s.project_id) s.project_name = nameMap.get(s.project_id) || null;
      }
    }
  }

  // Fetch evidence_events for interaction_ids
  const interactionIds = [
    ...new Set(sampled.map((s) => s.interaction_id).filter(Boolean)),
  ];
  const evidenceMap = new Map<string, JsonRecord[]>();
  if (interactionIds.length > 0) {
    const { data: events } = await db
      .from("evidence_events")
      .select(
        "evidence_event_id, source_type, source_id, transcript_variant, metadata",
      )
      .eq("source_type", "call")
      .in("source_id", interactionIds);
    if (events) {
      for (const ev of events as JsonRecord[]) {
        const srcId = asString(ev.source_id);
        if (!evidenceMap.has(srcId)) evidenceMap.set(srcId, []);
        evidenceMap.get(srcId)!.push(ev);
      }
    }
  }

  // --- Call reviewer for each span ---
  const reviewerUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/audit-attribution-reviewer`;
  const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET") || "";

  const results: ReviewResult[] = [];

  for (const span of sampled) {
    const rt0 = Date.now();
    let reviewerVerdict = "INSUFFICIENT";
    let reviewerNotes = "";
    let reviewerError: string | null = null;
    let reviewerOutput: JsonRecord = {};

    try {
      const evidenceEvents = evidenceMap.get(span.interaction_id) || [];
      const packet: JsonRecord = {
        interaction_id: span.interaction_id,
        span_id: span.span_id,
        span_attribution_id: span.sa_id,
        assigned_project_id: span.project_id,
        assigned_decision: span.decision,
        assigned_confidence: span.confidence,
        assigned_evidence_tier: span.evidence_tier,
        attribution_source: span.attribution_source,
        transcript_segment: span.transcript_segment,
        span_bounds: {
          char_start: span.char_start,
          char_end: span.char_end,
          span_index: span.span_index,
        },
        project_context_as_of: span.project_name
          ? [{
            project_id: span.project_id,
            fact_kind: "project_metadata",
            fact_payload: { project_name: span.project_name },
          }]
          : [],
        evidence_events: evidenceEvents,
        claim_pointers: [],
        call_at_utc: new Date().toISOString(),
        asof_mode: "KNOWN_AS_OF",
        same_call_excluded: true,
      };

      const reviewerBody: JsonRecord = {
        packet_json: packet,
      };
      if (reviewerModel) {
        reviewerBody.reviewer_model = reviewerModel;
      }

      const resp = await Promise.race([
        fetch(reviewerUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Edge-Secret": edgeSecret,
            "X-Source": "review-swarm-runner",
          },
          body: JSON.stringify(reviewerBody),
        }),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error("reviewer_timeout")), REVIEWER_TIMEOUT_MS)),
      ]);

      if (!resp.ok) {
        const errText = await resp.text().catch(() => "");
        throw new Error(`reviewer_http_${resp.status}: ${errText.slice(0, 200)}`);
      }

      const reviewerResp = asRecord(await resp.json());
      reviewerOutput = asRecord(reviewerResp.reviewer_output);
      reviewerVerdict = asString(reviewerOutput.verdict) || "INSUFFICIENT";
      reviewerNotes = asString(reviewerOutput.notes);
    } catch (e: unknown) {
      reviewerError = e instanceof Error ? e.message : String(e || "unknown");
    }

    const mappedVerdict = mapVerdict(reviewerVerdict);
    let written = false;
    let writeError: string | null = null;
    let queueUpdated = false;
    let queueError: string | null = null;

    if (mode === "label_only" && !reviewerError) {
      try {
        // 1. Write feedback
        const { error: insertErr } = await db
          .from("attribution_validation_feedback")
          .insert({
            span_id: span.span_id,
            interaction_id: span.interaction_id,
            project_id: span.project_id,
            verdict: mappedVerdict,
            notes: `batch_id:${batchId} | pool:${span.pool} | reviewer_verdict:${reviewerVerdict} | ${reviewerNotes}`
              .slice(
                0,
                500,
              ),
            source: "llm_proxy_review",
            created_by: `${FUNCTION_SLUG}/${FUNCTION_VERSION}`,
          });
        if (insertErr) {
          if (insertErr.code === "23505") {
            writeError = "duplicate_skipped";
            written = false;
          } else {
            throw new Error(insertErr.message);
          }
        } else {
          written = true;
        }

        // 2. Sync to review_queue to unblock auto-resolver
        if (written || writeError === "duplicate_skipped") {
          // Map to context_payload fields expected by auto-review-resolver
          let candidateProjectId: string | null = null;
          let candidateConfidence = 0.0;

          if (reviewerVerdict === "MATCH") {
            candidateProjectId = span.project_id;
            candidateConfidence = 0.96; // High but distinct from 1.0
          } else if (reviewerVerdict === "MISMATCH") {
            const candidates = Array.isArray(reviewerOutput.top_candidates) ? reviewerOutput.top_candidates : [];
            const top = asRecord(candidates[0]);
            candidateProjectId = asString(top.project_id) || null;
            candidateConfidence = asNumber(top.confidence) ?? 0.0;
          } else {
            // INSUFFICIENT or other: low confidence triggers auto-dismiss in resolver
            candidateProjectId = span.project_id;
            candidateConfidence = 0.10;
          }

          // Fetch the current review_queue item for this span
          const { data: queueItem } = await db
            .from("review_queue")
            .select("id, context_payload")
            .eq("span_id", span.span_id)
            .eq("status", "pending")
            .maybeSingle();

          if (queueItem) {
            const currentPayload = asRecord(queueItem.context_payload);
            const nextPayload = {
              ...currentPayload,
              candidate_project_id: candidateProjectId,
              candidate_confidence: candidateConfidence,
              ai_verdict: reviewerVerdict,
              swarm_batch_id: batchId,
              reviewed_at: new Date().toISOString(),
            };

            const { error: updateErr } = await db
              .from("review_queue")
              .update({ context_payload: nextPayload })
              .eq("id", queueItem.id);

            if (updateErr) {
              queueError = updateErr.message;
            } else {
              queueUpdated = true;
            }
          } else {
            queueError = "no_pending_queue_item_found";
          }
        }
      } catch (e: unknown) {
        writeError = e instanceof Error ? e.message : String(e || "unknown");
      }
    }

    results.push({
      span_id: span.span_id,
      interaction_id: span.interaction_id,
      pool: span.pool,
      reviewer_verdict: reviewerVerdict,
      mapped_verdict: mappedVerdict,
      reviewer_notes: reviewerNotes.slice(0, 200),
      reviewer_ms: Date.now() - rt0,
      reviewer_error: reviewerError,
      written,
      write_error: writeError,
      queue_updated: queueUpdated,
      queue_error: queueError,
    });
  }

  // --- Summary ---
  const totalReviewed = results.length;
  const totalWritten = results.filter((r) => r.written).length;
  const totalUpdated = results.filter((r) => r.queue_updated).length;
  const totalErrors = results.filter((r) => r.reviewer_error).length;
  const totalDupes = results.filter((r) => r.write_error === "duplicate_skipped").length;
  const verdictCounts: Record<string, number> = {};
  for (const r of results) {
    verdictCounts[r.mapped_verdict] = (verdictCounts[r.mapped_verdict] || 0) +
      1;
  }
  const poolCounts = {
    backlog: results.filter((r) => r.pool === "backlog").length,
    calibration: results.filter((r) => r.pool === "calibration").length,
  };

  // --- Emit per-run instrumentation into evidence_events ---
  const runMs = Date.now() - t0;
  await db.from("evidence_events").insert({
    source_type: "runner",
    source_id: batchId,
    transcript_variant: null,
    metadata: {
      runner_version: FUNCTION_VERSION,
      mode,
      batch_id: batchId,
      reviewer_model: reviewerModel || null,
      sampled: sampled.length,
      reviewed: totalReviewed,
      written: totalWritten,
      updated_queue: totalUpdated,
      errors: totalErrors,
      duplicates_skipped: totalDupes,
      verdict_counts: verdictCounts,
      pool_counts: poolCounts,
      ms: runMs,
    },
  }).then(() => {}, () => {}); // fire-and-forget

  return new Response(
    JSON.stringify({
      ok: true,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      mode,
      batch_id: batchId,
      reviewer_model: reviewerModel || null,
      sampled: sampled.length,
      reviewed: totalReviewed,
      written: totalWritten,
      updated_queue: totalUpdated,
      errors: totalErrors,
      duplicates_skipped: totalDupes,
      verdict_counts: verdictCounts,
      pool_counts: poolCounts,
      results,
      ms: runMs,
    }),
    { status: 200, headers: JSON_HEADERS },
  );
});
