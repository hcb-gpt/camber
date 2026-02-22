/**
 * Pass 4 — Review Queue ($0 cost)
 *
 * Enqueues any spans still unlabeled or with label_decision='review' after Pass 3
 * into the review_queue table for human resolution.
 *
 * Each span is upserted into review_queue with:
 *   - interaction_id from the span
 *   - reasons: ['labeling_low_confidence'] or ['labeling_no_match'] depending on whether
 *     any project candidate was attempted by prior passes
 *   - context_payload: includes batch_run_id, span_id, best_guess_project_id (if any),
 *     confidence, transcript snippet (first 300 chars), pass_history
 *   - status: 'open'
 *
 * Also writes a row to labeling_results with label_decision='review',
 * label_source='pass4_human_review', pass_number=4.
 *
 * No LLM calls — just DB reads + writes.
 *
 * Usage:
 *   source ~/.camber/credentials.env
 *   deno run --allow-net --allow-env pass4_review_queue.ts \
 *     --batch-run-id <id> [--unlabeled-only] [--dry-run]
 */

import { getDb } from "./shared/db.ts";
import { writeLabel, getLabeledSpanIds } from "./shared/label_writer.ts";
import type { UnlabeledSpan, PassStats } from "./shared/types.ts";

// ============================================================
// CONFIG
// ============================================================

const DRY_RUN = Deno.args.includes("--dry-run");
const UNLABELED_ONLY = Deno.args.includes("--unlabeled-only");

const batchRunIdArg = Deno.args.find((a) => a.startsWith("--batch-run-id="));
const BATCH_RUN_ID = batchRunIdArg?.split("=")[1] || `wm-label-${new Date().toISOString().slice(0,10).replace(/-/g,"")}-pass4`;

const db = getDb();

const stats: PassStats = {
  pass_name: "Review Queue",
  pass_number: 4,
  total_input: 0,
  labeled: 0,
  deferred: 0,
  errors: 0,
  detail: {
    low_confidence: 0,
    no_match: 0,
  },
};

// ============================================================
// DATA LOADING
// ============================================================

interface ReviewCandidate {
  span_id: string;
  interaction_id: string;
  transcript_segment: string | null;
  best_guess_project_id: string | null;
  confidence: number | null;
  pass_history: Array<{ pass_number: number; label_source: string; decision: string }>;
}

async function getReviewCandidates(alreadyLabeled: Set<string>): Promise<ReviewCandidate[]> {
  // Get all conversation_spans + interaction metadata
  const { data: spans, error: spansError } = await db
    .from("conversation_spans")
    .select("id, interaction_id, transcript_segment");

  if (spansError) {
    console.error("Failed to query conversation_spans:", spansError.message);
    return [];
  }

  // Get all labeling_results for this batch
  const { data: allLabels, error: labelsError } = await db
    .from("labeling_results")
    .select("span_id, project_id, confidence, label_decision, label_source, pass_number")
    .eq("batch_run_id", BATCH_RUN_ID);

  if (labelsError) {
    console.warn("Failed to query labeling_results:", labelsError.message);
  }

  // Build maps
  const labelsMap = new Map<string, any[]>();
  for (const label of allLabels || []) {
    const existing = labelsMap.get(label.span_id) || [];
    existing.push(label);
    labelsMap.set(label.span_id, existing);
  }

  // Filter spans: include if unlabeled OR if latest decision='review'
  const candidates: ReviewCandidate[] = [];

  for (const span of spans || []) {
    if (alreadyLabeled.has(span.id)) continue;

    const labels = labelsMap.get(span.id) || [];
    // Sort by pass_number desc to get latest
    labels.sort((a, b) => b.pass_number - a.pass_number);
    const latest = labels[0];

    // Include if: no labels OR latest decision is 'review' or 'unlabeled'
    const shouldInclude = !latest || latest.label_decision === 'review' || latest.label_decision === 'unlabeled';
    if (!shouldInclude) continue;

    const passHistory = labels.map((l) => ({
      pass_number: l.pass_number,
      label_source: l.label_source,
      decision: l.label_decision,
    }));

    candidates.push({
      span_id: span.id,
      interaction_id: span.interaction_id,
      transcript_segment: span.transcript_segment,
      best_guess_project_id: latest?.project_id || null,
      confidence: latest?.confidence || null,
      pass_history: passHistory,
    });
  }

  return candidates;
}

// ============================================================
// ENQUEUE LOGIC
// ============================================================

async function enqueueForReview(candidate: ReviewCandidate, dryRun: boolean): Promise<boolean> {
  // Determine reason
  const hasAttempt = candidate.best_guess_project_id !== null;
  const reason = hasAttempt ? 'labeling_low_confidence' : 'labeling_no_match';

  // Build context_payload
  const contextPayload = {
    batch_run_id: BATCH_RUN_ID,
    span_id: candidate.span_id,
    best_guess_project_id: candidate.best_guess_project_id,
    confidence: candidate.confidence,
    transcript_snippet: candidate.transcript_segment?.slice(0, 300) || "",
    pass_history: candidate.pass_history,
  };

  if (dryRun) {
    console.log(
      `[DRY-RUN] Would enqueue span=${candidate.span_id.slice(0, 8)} ` +
        `reason=${reason} ` +
        `interaction=${candidate.interaction_id}`,
    );
    return true;
  }

  // Upsert into review_queue
  const { error: queueError } = await db.from("review_queue").upsert({
    interaction_id: candidate.interaction_id,
    span_id: candidate.span_id,
    batch_run_id: BATCH_RUN_ID,
    reasons: [reason],
    context_payload: contextPayload,
    status: 'pending',
    created_at: new Date().toISOString(),
  }, {
    onConflict: "span_id,batch_run_id",
  });

  if (queueError) {
    console.error(
      `Failed to enqueue span ${candidate.span_id}:`,
      queueError.message,
    );
    return false;
  }

  // Write labeling_result with decision='review'
  const writeOk = await writeLabel(db, {
    span_id: candidate.span_id,
    interaction_id: candidate.interaction_id,
    project_id: candidate.best_guess_project_id,
    label_decision: "review",
    confidence: candidate.confidence || 0.0,
    label_source: "pass4_human_review",
    pass_number: 4,
    batch_run_id: BATCH_RUN_ID,
    attribution_lock: "pass4_review",
  }, false); // not a dry-run for writeLabel, we already checked above

  return writeOk;
}

// ============================================================
// MAIN
// ============================================================

async function main() {
  console.log("=== Pass 4: Review Queue ===");
  console.log(`Batch run ID: ${BATCH_RUN_ID}`);
  console.log(`Mode: ${DRY_RUN ? "DRY RUN" : "LIVE"}`);
  console.log(`Unlabeled only: ${UNLABELED_ONLY}`);
  console.log("");

  // Load already-labeled spans in this batch (excluding 'review')
  const alreadyLabeled = UNLABELED_ONLY
    ? await getLabeledSpanIds(db, BATCH_RUN_ID)
    : new Set<string>();

  // Get candidates
  console.log("Loading review candidates...");
  const candidates = await getReviewCandidates(alreadyLabeled);

  stats.total_input = candidates.length;
  console.log(`Review candidates: ${candidates.length}`);

  if (candidates.length === 0) {
    console.log("Nothing to enqueue.");
    return;
  }

  // Process candidates
  console.log("\nProcessing...\n");

  for (const candidate of candidates) {
    const ok = await enqueueForReview(candidate, DRY_RUN);
    if (ok) {
      const hasAttempt = candidate.best_guess_project_id !== null;
      if (hasAttempt) {
        stats.detail.low_confidence++;
      } else {
        stats.detail.no_match++;
      }
      stats.labeled++;
    } else {
      stats.errors++;
    }
  }

  // Report
  console.log("\n=== Pass 4 Results ===");
  console.log(`Total input:          ${stats.total_input}`);
  console.log(`Low confidence:       ${stats.detail.low_confidence}`);
  console.log(`No match:             ${stats.detail.no_match}`);
  console.log(`Total enqueued:       ${stats.labeled}`);
  console.log(`Errors:               ${stats.errors}`);
  if (DRY_RUN) {
    console.log("\n[DRY-RUN] No writes were made.");
  }
}

main().catch((err) => {
  console.error("Pass 4 failed:", err);
  Deno.exit(1);
});
