#!/usr/bin/env -S deno run --allow-env --allow-net

/**
 * GT Eval Script - Phase 3 Ground Truth Evaluation
 *
 * Compares pipeline labeling results against human-verified ground truth labels.
 *
 * Usage:
 *   deno run --allow-env --allow-net gt_eval.ts --batch-run-id=wm-prep-v1
 *
 * Baseline accuracy: 8.2% (from WP-H sample)
 * Target accuracy: >= 50%
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { parse } from "https://deno.land/std@0.208.0/flags/mod.ts";

interface GTLabel {
  span_id: string;
  applied_project_id: string;
  attribution_lock: string;
  confidence: number;
  decision: string;
}

interface PipelineResult {
  span_id: string;
  project_id: string | null;
  confidence: number;
  pass_number: number;
  batch_run_id: string;
}

interface EvalResult {
  total_gt_spans: number;
  total_pipeline_results: number;
  matched_spans: number;
  correct_predictions: number;
  accuracy_pct: number;
  per_pass_breakdown: Record<number, {
    total: number;
    correct: number;
    accuracy: number;
  }>;
  baseline_pct: number;
  target_pct: number;
  meets_target: boolean;
}

async function main() {
  const args = parse(Deno.args, {
    string: ["batch-run-id"],
    default: {
      "batch-run-id": "wm-prep-v1",
    },
  });

  const batchRunId = args["batch-run-id"];
  console.log(`\n🔍 GT Eval - Batch: ${batchRunId}\n`);

  // Initialize Supabase client
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !supabaseKey) {
    console.error("❌ Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
    Deno.exit(1);
  }

  const supabase = createClient(supabaseUrl, supabaseKey);

  // Step 1: Fetch ground truth labels (human-verified)
  console.log("📊 Fetching ground truth labels (human-verified)...");
  const { data: gtLabels, error: gtError } = await supabase
    .from("span_attributions")
    .select("span_id, applied_project_id, attribution_lock, confidence, decision")
    .not("applied_project_id", "is", null)
    .eq("attribution_lock", "human");

  if (gtError) {
    console.error("❌ Error fetching GT labels:", gtError);
    Deno.exit(1);
  }

  if (!gtLabels || gtLabels.length === 0) {
    console.error("❌ No ground truth labels found with attribution_lock='human'");
    Deno.exit(1);
  }

  console.log(`✅ Found ${gtLabels.length} human-verified GT labels\n`);

  // Step 2: Fetch pipeline results for the batch
  console.log(`📊 Fetching pipeline results for batch: ${batchRunId}...`);
  // Paginate to avoid Supabase 1000-row default limit
  const allPipelineResults: PipelineResult[] = [];
  let offset = 0;
  const pageSize = 1000;
  while (true) {
    const { data: page, error: pageErr } = await supabase
      .from("labeling_results")
      .select("span_id, project_id, confidence, pass_number, batch_run_id")
      .eq("batch_run_id", batchRunId)
      .range(offset, offset + pageSize - 1);
    if (pageErr) {
      console.error("❌ Error fetching pipeline results:", pageErr);
      Deno.exit(1);
    }
    if (!page || page.length === 0) break;
    allPipelineResults.push(...(page as PipelineResult[]));
    if (page.length < pageSize) break;
    offset += pageSize;
  }
  const pipelineResults = allPipelineResults;
  const pipelineError = null;

  if (pipelineError) {
    console.error("❌ Error fetching pipeline results:", pipelineError);
    Deno.exit(1);
  }

  if (!pipelineResults || pipelineResults.length === 0) {
    console.error(`❌ No pipeline results found for batch_run_id='${batchRunId}'`);
    console.log("\n💡 Available batch_run_ids:");

    const { data: batches } = await supabase
      .from("labeling_results")
      .select("batch_run_id")
      .order("batch_run_id");

    if (batches) {
      const uniqueBatches = [...new Set(batches.map(b => b.batch_run_id))];
      uniqueBatches.forEach(b => console.log(`  - ${b}`));
    }

    Deno.exit(1);
  }

  console.log(`✅ Found ${pipelineResults.length} pipeline results\n`);

  // Step 3: Build lookup maps
  const gtMap = new Map<string, string>();
  for (const gt of gtLabels as GTLabel[]) {
    gtMap.set(gt.span_id, gt.applied_project_id);
  }

  const pipelineMap = new Map<string, PipelineResult>();
  for (const result of pipelineResults as PipelineResult[]) {
    // Keep the highest pass number for each span (last result wins)
    const existing = pipelineMap.get(result.span_id);
    if (!existing || result.pass_number > existing.pass_number) {
      pipelineMap.set(result.span_id, result);
    }
  }

  // Step 4: Compare GT vs Pipeline
  console.log("🔬 Evaluating pipeline accuracy against ground truth...\n");

  let matchedSpans = 0;
  let correctPredictions = 0;
  const perPassStats: Record<number, { total: number; correct: number }> = {};

  for (const [spanId, gtProjectId] of gtMap.entries()) {
    const pipelineResult = pipelineMap.get(spanId);

    if (pipelineResult) {
      matchedSpans++;

      const passNum = pipelineResult.pass_number;
      if (!perPassStats[passNum]) {
        perPassStats[passNum] = { total: 0, correct: 0 };
      }
      perPassStats[passNum].total++;

      if (pipelineResult.project_id === gtProjectId) {
        correctPredictions++;
        perPassStats[passNum].correct++;
      }
    }
  }

  // Step 5: Calculate metrics
  const accuracy = matchedSpans > 0 ? (correctPredictions / matchedSpans) * 100 : 0;
  const baselineAccuracy = 8.2;
  const targetAccuracy = 50.0;

  const perPassBreakdown: Record<number, { total: number; correct: number; accuracy: number }> = {};
  for (const [passNum, stats] of Object.entries(perPassStats)) {
    const passAccuracy = stats.total > 0 ? (stats.correct / stats.total) * 100 : 0;
    perPassBreakdown[parseInt(passNum)] = {
      total: stats.total,
      correct: stats.correct,
      accuracy: passAccuracy,
    };
  }

  const result: EvalResult = {
    total_gt_spans: gtLabels.length,
    total_pipeline_results: pipelineResults.length,
    matched_spans: matchedSpans,
    correct_predictions: correctPredictions,
    accuracy_pct: parseFloat(accuracy.toFixed(2)),
    per_pass_breakdown: perPassBreakdown,
    baseline_pct: baselineAccuracy,
    target_pct: targetAccuracy,
    meets_target: accuracy >= targetAccuracy,
  };

  // Step 6: Display results
  console.log("═══════════════════════════════════════════════════");
  console.log("📈 GT EVAL RESULTS");
  console.log("═══════════════════════════════════════════════════");
  console.log(`Batch Run ID:         ${batchRunId}`);
  console.log(`Total GT Spans:       ${result.total_gt_spans}`);
  console.log(`Total Pipeline Res:   ${result.total_pipeline_results}`);
  console.log(`Matched Spans:        ${result.matched_spans}`);
  console.log(`Correct Predictions:  ${result.correct_predictions}`);
  console.log(`\n📊 ACCURACY:          ${result.accuracy_pct}%`);
  console.log(`   Baseline:          ${result.baseline_pct}%`);
  console.log(`   Target:            ${result.target_pct}%`);
  console.log(`   Meets Target:      ${result.meets_target ? "✅ YES" : "❌ NO"}`);

  console.log("\n📋 PER-PASS BREAKDOWN:");
  console.log("───────────────────────────────────────────────────");
  const sortedPasses = Object.keys(result.per_pass_breakdown)
    .map(Number)
    .sort((a, b) => a - b);

  for (const passNum of sortedPasses) {
    const stats = result.per_pass_breakdown[passNum];
    console.log(
      `Pass ${passNum}:  ${stats.correct}/${stats.total} correct (${stats.accuracy.toFixed(2)}%)`
    );
  }

  console.log("═══════════════════════════════════════════════════\n");

  // Exit code: 0 if meets target, 1 if below target
  Deno.exit(result.meets_target ? 0 : 1);
}

if (import.meta.main) {
  main();
}
