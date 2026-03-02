export type TruthGraphLane =
  | "process-call"
  | "segment-call"
  | "ai-router"
  | "journal"
  | "sms-ingest"
  | "unknown";

export type TruthGraphRepairAction =
  | "repair_process_call"
  | "repair_ai_router";

export interface TruthGraphHydration {
  calls_raw: boolean;
  interactions: boolean;
  conversation_spans: boolean;
  evidence_events: boolean;
  span_attributions: boolean;
  journal_claims: boolean;
  review_queue: boolean;
}

export interface TruthGraphSuggestedRepair {
  action: TruthGraphRepairAction;
  label: string;
  idempotency_key: string;
}

export interface TruthGraphComputationResult {
  lane: TruthGraphLane;
  suggested_repairs: TruthGraphSuggestedRepair[];
  warnings: string[];
}

export function buildRepairIdempotencyKey(
  interactionId: string,
  repairAction: TruthGraphRepairAction,
  now: Date = new Date(),
): string {
  const day = now.toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
  return `repair:${repairAction}:${interactionId}:${day}`;
}

export function computeTruthGraph(
  interactionId: string,
  hydration: TruthGraphHydration,
  opts: { interaction_channel?: string | null; now?: Date } = {},
): TruthGraphComputationResult {
  const warnings: string[] = [];
  const now = opts.now ?? new Date();
  const channel = String(opts.interaction_channel || "").trim().toLowerCase();
  const looksLikeSms = interactionId.startsWith("sms_thread_") || interactionId.startsWith("sms_thread__") ||
    channel === "sms" || channel === "text" || channel === "sms_thread";

  let lane: TruthGraphLane = "unknown";

  if (looksLikeSms) {
    lane = "sms-ingest";
  } else if (!hydration.calls_raw || !hydration.interactions) {
    lane = "process-call";
  } else if (!hydration.conversation_spans || !hydration.evidence_events) {
    lane = "segment-call";
  } else if (!hydration.span_attributions) {
    lane = "ai-router";
  } else if (!hydration.journal_claims) {
    lane = "journal";
  } else {
    lane = "unknown";
  }

  const suggested_repairs: TruthGraphSuggestedRepair[] = [];

  if (lane === "process-call" || lane === "segment-call") {
    suggested_repairs.push({
      action: "repair_process_call",
      label: "Replay process-call (rebuild raw → interaction → spans)",
      idempotency_key: buildRepairIdempotencyKey(interactionId, "repair_process_call", now),
    });
    if (!hydration.calls_raw) {
      warnings.push("missing_calls_raw_snapshot: repair_process_call may be unable to reconstruct payload");
    }
  }

  if (lane === "ai-router") {
    suggested_repairs.push({
      action: "repair_ai_router",
      label: "Re-run attribution/router (reseed spans → reroute)",
      idempotency_key: buildRepairIdempotencyKey(interactionId, "repair_ai_router", now),
    });
  }

  if (lane === "journal") {
    warnings.push("journal_missing: no v0 repair hook exposed (manual follow-up)");
  }

  return { lane, suggested_repairs, warnings };
}

