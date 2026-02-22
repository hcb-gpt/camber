/**
 * Shared types for the labeling pipeline (Passes 0-4).
 */

export interface UnlabeledSpan {
  span_id: string;
  interaction_id: string;
  contact_id: string | null;
  contact_phone: string | null;
  contact_name: string | null;
  event_at_utc: string | null;
  transcript_segment: string | null;
}

export interface ActiveProject {
  id: string;
  name: string;
  status: string;
  phase: string | null;
  address: string | null;
  client_name: string | null;
  aliases: string[];
}

export type LabelSource =
  | "pass0_phone_match"
  | "pass0_homeowner_regex"
  | "pass0_staff_exclusion"
  | "pass0_single_vendor"
  | "pass1_graph_propagation"
  | "pass1_temporal_cluster"
  | "pass1_sub_transitivity"
  | "pass2_haiku_triage"
  | "pass3_opus_deep_label"
  | "pass4_human_review"
  | "gt_correction";

export type LabelDecision = "assign" | "none" | "review" | "unlabeled";

export interface LabelingResult {
  span_id: string;
  interaction_id: string;
  project_id: string | null;
  label_decision: LabelDecision;
  confidence: number;
  label_source: LabelSource;
  pass_number: number;
  batch_run_id: string;
  attribution_lock?: string;
  model_id?: string;
  tokens_used?: number;
  inference_ms?: number;
  raw_response?: Record<string, unknown>;
  extracted_facts?: Record<string, unknown>[];
}

export interface AffinityRow {
  contact_id: string;
  project_id: string;
  weight: number;
}

export interface ContactFanout {
  contact_id: string;
  effective_fanout: number;
  fanout_class: string;
}

export interface PassStats {
  pass_name: string;
  pass_number: number;
  total_input: number;
  labeled: number;
  deferred: number;
  errors: number;
  detail: Record<string, number>;
}
