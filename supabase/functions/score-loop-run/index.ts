/**
 * score-loop-run Edge Function v1.0.0
 * Closed-Loop Stage 5: Headless span-level scoring for synthetic ground truth runs.
 *
 * @version 1.0.0
 * @date 2026-03-01
 * @purpose Score pipeline attribution accuracy against synthetic ground truth at SPAN level
 *
 * Architecture:
 *   Reads synthetic_ground_truth entries, joins through the pipeline chain:
 *     synthetic_ground_truth.interaction_id -> interactions
 *     interactions.interaction_id -> conversation_spans
 *     conversation_spans.id -> span_attributions (via span_id)
 *     interactions.interaction_id -> review_queue
 *
 *   Scores at SPAN LEVEL (not interaction level):
 *     For each expected project in expected_project_ids, checks if any span_attribution
 *     assigned it correctly.
 *
 *   Verdicts: correct, wrong_project, missed, false_positive, failed_to_split
 *
 * Input:  { run_name, run_type?, limit? }
 *   - run_name (required): label for this scoring run
 *   - run_type: "full" | "incremental" | "regression" (default: "full")
 *   - limit: max ground truth rows to process (default: 500)
 *   - run_id: optional UUID — if provided, only score GT entries for this run
 *
 * Output: loop_run_scores row + loop_run_details rows + summary JSON
 *
 * Auth: X-Edge-Secret (internal machine-to-machine)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_VERSION = "v1.0.0";
const JSON_HEADERS = { "Content-Type": "application/json" };
const MAX_LIMIT = 2000;
const DEFAULT_LIMIT = 500;

const ALLOWED_SOURCES = [
  "score-loop-run",
  "closed-loop-runner",
  "agent-teams",
  "claude-chat",
  "manual",
  "test",
];

// ============================================================
// TYPES
// ============================================================

type Verdict = "correct" | "wrong_project" | "missed" | "false_positive" | "failed_to_split";

interface SpanDetail {
  interaction_id: string;
  span_id: string | null;
  verdict: Verdict;
  expected_project_id: string;
  actual_project_id: string | null;
  pipeline_confidence: number | null;
  epistemic_entropy: number | null;
  evidence_support_gap: number | null;
  agent_action: string | null;
}

interface GroundTruthRow {
  id: string;
  interaction_id: string;
  run_id: string | null;
  expected_taxonomy_state: string | null;
  expected_project_ids: string[] | null;
  expected_span_count: number | null;
  difficulty: string | null;
  scenario_type: string | null;
}

interface SpanAttributionRow {
  id: string;
  span_id: string;
  project_id: string | null;
  confidence: number | null;
}

interface ConversationSpanRow {
  id: string;
  interaction_id: string;
  span_index: number;
}

interface ReviewQueueRow {
  id: string;
  interaction_id: string;
  span_id: string | null;
  status: string;
}

// ============================================================
// HELPERS
// ============================================================

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS,
  });
}

/**
 * Compute precision, recall, F1 from TP/FP/FN counts.
 */
function computeMetrics(tp: number, fp: number, fn: number) {
  const precision = tp + fp > 0 ? tp / (tp + fp) : 0;
  const recall = tp + fn > 0 ? tp / (tp + fn) : 0;
  const f1 = precision + recall > 0 ? (2 * precision * recall) / (precision + recall) : 0;
  const accuracy = tp + fp + fn > 0 ? tp / (tp + fp + fn) : 0;
  return {
    accuracy: round4(accuracy),
    precision_score: round4(precision),
    recall_score: round4(recall),
    f1_score: round4(f1),
  };
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}

// ============================================================
// SCORING LOGIC
// ============================================================

/**
 * Score a single ground truth entry at span level.
 *
 * For each expected_project_id:
 *   - If a span_attribution exists for that project -> "correct"
 *   - If span_attributions exist but for different projects -> "wrong_project"
 *   - If no span_attributions exist at all for the interaction -> "missed"
 *
 * For each span_attribution that maps to a project NOT in expected_project_ids:
 *   -> "false_positive"
 *
 * If expected_taxonomy_state = "NEEDS_SPLIT" and the pipeline produced only 1 span
 * but expected_span_count > 1 -> "failed_to_split"
 */
function scoreEntry(
  gt: GroundTruthRow,
  spans: ConversationSpanRow[],
  attributions: SpanAttributionRow[],
  reviewItems: ReviewQueueRow[],
): SpanDetail[] {
  const details: SpanDetail[] = [];
  const expectedProjects = gt.expected_project_ids ?? [];

  // Build a set of all projects that the pipeline attributed
  const attributedProjectIds = new Set<string>();
  for (const attr of attributions) {
    if (attr.project_id) {
      attributedProjectIds.add(attr.project_id);
    }
  }

  // Build a map from project_id to the best attribution (highest confidence)
  const projectToAttr = new Map<string, SpanAttributionRow>();
  for (const attr of attributions) {
    if (!attr.project_id) continue;
    const existing = projectToAttr.get(attr.project_id);
    if (!existing || (attr.confidence ?? 0) > (existing.confidence ?? 0)) {
      projectToAttr.set(attr.project_id, attr);
    }
  }

  // Check for failed_to_split:
  // Expected NEEDS_SPLIT with expected_span_count > 1, but pipeline made <= 1 span
  const failedToSplit =
    gt.expected_taxonomy_state === "NEEDS_SPLIT" &&
    (gt.expected_span_count ?? 0) > 1 &&
    spans.length <= 1;

  // Determine the review action for this interaction (if any)
  const reviewAction = reviewItems.length > 0 ? reviewItems[0].status : null;

  // Score each expected project
  for (const expectedProjId of expectedProjects) {
    if (failedToSplit) {
      // If the segmenter failed to split, all expected projects are "failed_to_split"
      const bestAttr = projectToAttr.get(expectedProjId);
      details.push({
        interaction_id: gt.interaction_id,
        span_id: bestAttr?.span_id ?? (spans.length > 0 ? spans[0].id : null),
        verdict: "failed_to_split",
        expected_project_id: expectedProjId,
        actual_project_id: bestAttr?.project_id ?? null,
        pipeline_confidence: bestAttr?.confidence ?? null,
        epistemic_entropy: null,
        evidence_support_gap: null,
        agent_action: reviewAction,
      });
    } else if (attributedProjectIds.has(expectedProjId)) {
      // Correct: pipeline attributed this project to some span
      const bestAttr = projectToAttr.get(expectedProjId)!;
      details.push({
        interaction_id: gt.interaction_id,
        span_id: bestAttr.span_id,
        verdict: "correct",
        expected_project_id: expectedProjId,
        actual_project_id: bestAttr.project_id,
        pipeline_confidence: bestAttr.confidence ?? null,
        epistemic_entropy: null,
        evidence_support_gap: null,
        agent_action: reviewAction,
      });
    } else if (attributions.length > 0) {
      // Pipeline did attribute spans, but NOT to this expected project -> wrong_project
      // Pick the span with the highest confidence to report against
      const topAttr = attributions.reduce((a, b) => ((a.confidence ?? 0) >= (b.confidence ?? 0) ? a : b));
      details.push({
        interaction_id: gt.interaction_id,
        span_id: topAttr.span_id,
        verdict: "wrong_project",
        expected_project_id: expectedProjId,
        actual_project_id: topAttr.project_id,
        pipeline_confidence: topAttr.confidence ?? null,
        epistemic_entropy: null,
        evidence_support_gap: null,
        agent_action: reviewAction,
      });
    } else {
      // No attributions at all -> missed
      details.push({
        interaction_id: gt.interaction_id,
        span_id: spans.length > 0 ? spans[0].id : null,
        verdict: "missed",
        expected_project_id: expectedProjId,
        actual_project_id: null,
        pipeline_confidence: null,
        epistemic_entropy: null,
        evidence_support_gap: null,
        agent_action: reviewAction,
      });
    }
  }

  // Check for false positives: projects the pipeline attributed that are NOT expected
  const expectedSet = new Set(expectedProjects);
  for (const attr of attributions) {
    if (attr.project_id && !expectedSet.has(attr.project_id)) {
      details.push({
        interaction_id: gt.interaction_id,
        span_id: attr.span_id,
        verdict: "false_positive",
        expected_project_id: "",
        actual_project_id: attr.project_id,
        pipeline_confidence: attr.confidence ?? null,
        epistemic_entropy: null,
        evidence_support_gap: null,
        agent_action: reviewAction,
      });
    }
  }

  return details;
}

// ============================================================
// MAIN
// ============================================================

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-edge-secret, x-source, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "POST_ONLY" }, 405);
  }

  // ========================================
  // 1. AUTH
  // ========================================
  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code!, `score-loop-run ${FUNCTION_VERSION}`);
  }

  // ========================================
  // 2. PARSE INPUT
  // ========================================
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ ok: false, error: "invalid_json" }, 400);
  }

  const run_name = body.run_name as string | undefined;
  const run_type = (body.run_type as string) || "full";
  const limit = Math.min(Number(body.limit) || DEFAULT_LIMIT, MAX_LIMIT);
  const run_id = body.run_id as string | undefined;

  if (!run_name) {
    return jsonResponse(
      { ok: false, error: "missing_required_field", detail: "run_name is required" },
      400,
    );
  }

  if (!["full", "incremental", "regression"].includes(run_type)) {
    return jsonResponse(
      { ok: false, error: "invalid_run_type", detail: "run_type must be full, incremental, or regression" },
      400,
    );
  }

  // ========================================
  // 3. INIT SUPABASE
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    // ========================================
    // 4. FETCH GROUND TRUTH
    // ========================================
    let gtQuery = db
      .from("synthetic_ground_truth")
      .select("id, interaction_id, run_id, expected_taxonomy_state, expected_project_ids, expected_span_count, difficulty, scenario_type")
      .order("created_at", { ascending: true })
      .limit(limit);

    if (run_id) {
      gtQuery = gtQuery.eq("run_id", run_id);
    }

    const { data: gtRows, error: gtErr } = await gtQuery;

    if (gtErr) {
      throw new Error(`db_ground_truth: ${gtErr.message}`);
    }

    if (!gtRows || gtRows.length === 0) {
      return jsonResponse({
        ok: true,
        run_name,
        run_type,
        reason: "no_ground_truth_found",
        filter_run_id: run_id ?? null,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      });
    }

    // ========================================
    // 5. BATCH FETCH PIPELINE DATA
    // ========================================

    // Collect all interaction_ids from ground truth
    const interactionIds = [...new Set(gtRows.map((g: GroundTruthRow) => g.interaction_id))];

    // 5a. Fetch conversation_spans for all interactions
    const { data: allSpans, error: spansErr } = await db
      .from("conversation_spans")
      .select("id, interaction_id, span_index")
      .in("interaction_id", interactionIds)
      .order("span_index", { ascending: true });

    if (spansErr) {
      throw new Error(`db_conversation_spans: ${spansErr.message}`);
    }

    // Group spans by interaction_id
    const spansByInteraction = new Map<string, ConversationSpanRow[]>();
    for (const span of (allSpans ?? [])) {
      const list = spansByInteraction.get(span.interaction_id) ?? [];
      list.push(span);
      spansByInteraction.set(span.interaction_id, list);
    }

    // 5b. Fetch span_attributions for all spans
    const allSpanIds = (allSpans ?? []).map((s: ConversationSpanRow) => s.id);
    let allAttributions: SpanAttributionRow[] = [];

    if (allSpanIds.length > 0) {
      // Batch in chunks of 500 to avoid query size limits
      const CHUNK_SIZE = 500;
      for (let i = 0; i < allSpanIds.length; i += CHUNK_SIZE) {
        const chunk = allSpanIds.slice(i, i + CHUNK_SIZE);
        const { data: attrChunk, error: attrErr } = await db
          .from("span_attributions")
          .select("id, span_id, project_id, confidence")
          .in("span_id", chunk);

        if (attrErr) {
          throw new Error(`db_span_attributions: ${attrErr.message}`);
        }
        allAttributions = allAttributions.concat(attrChunk ?? []);
      }
    }

    // Group attributions by interaction_id (via span -> interaction mapping)
    const spanToInteraction = new Map<string, string>();
    for (const span of (allSpans ?? [])) {
      spanToInteraction.set(span.id, span.interaction_id);
    }

    const attrByInteraction = new Map<string, SpanAttributionRow[]>();
    for (const attr of allAttributions) {
      const iid = spanToInteraction.get(attr.span_id);
      if (!iid) continue;
      const list = attrByInteraction.get(iid) ?? [];
      list.push(attr);
      attrByInteraction.set(iid, list);
    }

    // 5c. Fetch review_queue items for all interactions
    const { data: allReviewItems, error: reviewErr } = await db
      .from("review_queue")
      .select("id, interaction_id, span_id, status")
      .in("interaction_id", interactionIds);

    if (reviewErr) {
      throw new Error(`db_review_queue: ${reviewErr.message}`);
    }

    // Group review items by interaction_id
    const reviewByInteraction = new Map<string, ReviewQueueRow[]>();
    for (const ri of (allReviewItems ?? [])) {
      const list = reviewByInteraction.get(ri.interaction_id) ?? [];
      list.push(ri);
      reviewByInteraction.set(ri.interaction_id, list);
    }

    // ========================================
    // 6. SCORE EACH GROUND TRUTH ENTRY
    // ========================================
    const allDetails: SpanDetail[] = [];
    const processedInteractions = new Set<string>();

    for (const gt of gtRows as GroundTruthRow[]) {
      const spans = spansByInteraction.get(gt.interaction_id) ?? [];
      const attrs = attrByInteraction.get(gt.interaction_id) ?? [];
      const reviews = reviewByInteraction.get(gt.interaction_id) ?? [];

      const entryDetails = scoreEntry(gt, spans, attrs, reviews);
      allDetails.push(...entryDetails);
      processedInteractions.add(gt.interaction_id);
    }

    // ========================================
    // 7. AGGREGATE METRICS
    // ========================================
    let correctCount = 0;
    let wrongProjectCount = 0;
    let missedCount = 0;
    let falsePositiveCount = 0;
    let failedToSplitCount = 0;
    let confidenceSum = 0;
    let confidenceN = 0;

    for (const d of allDetails) {
      switch (d.verdict) {
        case "correct":
          correctCount++;
          break;
        case "wrong_project":
          wrongProjectCount++;
          break;
        case "missed":
          missedCount++;
          break;
        case "false_positive":
          falsePositiveCount++;
          break;
        case "failed_to_split":
          failedToSplitCount++;
          break;
      }
      if (d.pipeline_confidence !== null) {
        confidenceSum += d.pipeline_confidence;
        confidenceN++;
      }
    }

    // TP = correct, FP = wrong_project + false_positive, FN = missed + failed_to_split
    const tp = correctCount;
    const fp = wrongProjectCount + falsePositiveCount;
    const fn = missedCount + failedToSplitCount;
    const metrics = computeMetrics(tp, fp, fn);
    const meanConfidence = confidenceN > 0 ? round4(confidenceSum / confidenceN) : null;

    // ========================================
    // 8. WRITE loop_run_scores
    // ========================================
    const { data: scoreRow, error: scoreErr } = await db
      .from("loop_run_scores")
      .insert({
        run_name,
        run_type,
        total_interactions: processedInteractions.size,
        total_spans: allDetails.length,
        correct_attributions: correctCount,
        wrong_project: wrongProjectCount,
        missed: missedCount,
        false_positive: falsePositiveCount,
        failed_to_split: failedToSplitCount,
        accuracy: metrics.accuracy,
        precision_score: metrics.precision_score,
        recall_score: metrics.recall_score,
        f1_score: metrics.f1_score,
        mean_confidence: meanConfidence,
        mean_epistemic_entropy: null,
        notes: `Scored ${processedInteractions.size} interactions, ${allDetails.length} span-level verdicts. run_id filter: ${run_id ?? "none"}`,
      })
      .select("id")
      .single();

    if (scoreErr) {
      throw new Error(`db_insert_loop_run_scores: ${scoreErr.message}`);
    }

    const scoreRunId = scoreRow.id;

    // ========================================
    // 9. WRITE loop_run_details (batch insert)
    // ========================================
    const detailRows = allDetails.map((d) => ({
      run_id: scoreRunId,
      interaction_id: d.interaction_id,
      span_id: d.span_id,
      attribution_verdict: d.verdict,
      expected_project_id: d.expected_project_id || null,
      actual_project_id: d.actual_project_id,
      pipeline_confidence: d.pipeline_confidence,
      epistemic_entropy: d.epistemic_entropy,
      evidence_support_gap: d.evidence_support_gap,
      agent_action: d.agent_action,
    }));

    // Batch insert in chunks of 200
    const DETAIL_CHUNK_SIZE = 200;
    let detailsInserted = 0;
    for (let i = 0; i < detailRows.length; i += DETAIL_CHUNK_SIZE) {
      const chunk = detailRows.slice(i, i + DETAIL_CHUNK_SIZE);
      const { error: detailErr } = await db
        .from("loop_run_details")
        .insert(chunk);

      if (detailErr) {
        throw new Error(`db_insert_loop_run_details (batch ${Math.floor(i / DETAIL_CHUNK_SIZE)}): ${detailErr.message}`);
      }
      detailsInserted += chunk.length;
    }

    // ========================================
    // 10. RETURN SUMMARY
    // ========================================
    return jsonResponse({
      ok: true,
      run_id: scoreRunId,
      run_name,
      run_type,
      total_interactions: processedInteractions.size,
      total_span_verdicts: allDetails.length,
      verdicts: {
        correct: correctCount,
        wrong_project: wrongProjectCount,
        missed: missedCount,
        false_positive: falsePositiveCount,
        failed_to_split: failedToSplitCount,
      },
      metrics: {
        accuracy: metrics.accuracy,
        precision: metrics.precision_score,
        recall: metrics.recall_score,
        f1: metrics.f1_score,
        mean_confidence: meanConfidence,
      },
      details_inserted: detailsInserted,
      filter_run_id: run_id ?? null,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : String(e);
    console.error(`[score-loop-run] Error: ${message}`);
    return jsonResponse(
      {
        ok: false,
        error: message,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      },
      500,
    );
  }
});
