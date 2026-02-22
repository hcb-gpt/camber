/**
 * Shared label writer for all passes.
 * Writes to labeling_results table (NOT span_attributions).
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { LabelingResult } from "./types.ts";

export async function writeLabel(
  db: SupabaseClient,
  result: LabelingResult,
  dryRun: boolean,
): Promise<boolean> {
  if (dryRun) {
    console.log(
      `[DRY-RUN] Would label span=${result.span_id.slice(0, 8)} -> ` +
        `project=${result.project_id?.slice(0, 8) || "none"} ` +
        `conf=${result.confidence.toFixed(3)} ` +
        `source=${result.label_source}`,
    );
    return true;
  }

  const row: Record<string, unknown> = {
    span_id: result.span_id,
    interaction_id: result.interaction_id,
    project_id: result.project_id,
    label_decision: result.label_decision,
    confidence: result.confidence,
    label_source: result.label_source,
    pass_number: result.pass_number,
    batch_run_id: result.batch_run_id,
    labeled_at: new Date().toISOString(),
  };

  if (result.attribution_lock) row.attribution_lock = result.attribution_lock;
  if (result.model_id) row.model_id = result.model_id;
  if (result.tokens_used != null) row.tokens_used = result.tokens_used;
  if (result.inference_ms != null) row.inference_ms = result.inference_ms;
  if (result.raw_response) row.raw_response = result.raw_response;
  if (result.extracted_facts) row.extracted_facts = result.extracted_facts;

  const { error } = await db.from("labeling_results").upsert(row, {
    onConflict: "span_id,batch_run_id",
  });

  if (error) {
    console.error(
      `Failed to write label for span ${result.span_id}:`,
      error.message,
    );
    return false;
  }

  return true;
}

/**
 * Get span_ids that are already labeled in this batch run.
 */
export async function getLabeledSpanIds(
  db: SupabaseClient,
  batchRunId: string,
): Promise<Set<string>> {
  const { data, error } = await db
    .from("labeling_results")
    .select("span_id")
    .eq("batch_run_id", batchRunId)
    .neq("label_decision", "unlabeled");

  if (error) {
    console.warn("Failed to query existing labels:", error.message);
    return new Set();
  }

  return new Set((data || []).map((r: { span_id: string }) => r.span_id));
}
