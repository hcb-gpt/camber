/**
 * truth-graph-probe Edge Function v1.0.0
 * Walks the attribution chain for an interaction and diagnoses gaps.
 * Offers idempotent repair hooks to replay pipeline stages.
 *
 * @version 1.0.0
 * @date 2026-02-28
 *
 * Actions:
 *   "probe"                — walk chain via redline_truth_graph_v1, return diagnosis
 *   "replay_process_call"  — re-invoke process-call for the interaction
 *   "replay_ai_router"     — re-invoke ai-router for each active span
 *
 * Auth (internal pattern):
 *   verify_jwt=false, X-Edge-Secret == EDGE_SHARED_SECRET, source in allowlist
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_VERSION = "v1.0.0";
const ALLOWED_SOURCES = ["test", "redline", "strat", "operator", "admin"];
const ID_PATTERN = /^cll_[a-zA-Z0-9_]+$/;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const PROCESS_CALL_URL = `${SUPABASE_URL}/functions/v1/process-call`;
const AI_ROUTER_URL = `${SUPABASE_URL}/functions/v1/ai-router`;
const REPLAY_TIMEOUT_MS = 15_000;

type Action = "probe" | "replay_process_call" | "replay_ai_router";

interface ProbeRequest {
  interaction_id: string;
  action?: Action;
}

// -- Chain node types matching redline_truth_graph_v1 output --

interface NodeStatuses {
  calls_raw: { present: boolean; count: number; ids: string[] };
  interactions: { present: boolean; count: number; ids: string[] };
  conversation_spans: { present: boolean; count: number; ids: string[] };
  evidence_events: { present: boolean; count: number; ids: string[] };
  span_attributions: {
    present: boolean;
    count: number;
    needs_review_count: number;
    ids: string[];
  };
  review_queue: {
    present: boolean;
    count: number;
    pending_count: number;
    ids: string[];
  };
  journal_claims: {
    present: boolean;
    count: number;
    active_count: number;
    ids: string[];
  };
  journal_open_loops: {
    present: boolean;
    count: number;
    open_count: number;
    ids: string[];
  };
  redline_thread: { present: boolean; count: number };
  context_materialization: {
    staleness_status: string;
    refreshed_at_utc: string | null;
    latest_pipeline_activity_at_utc: string | null;
  };
}

interface TruthGraphRow {
  interaction_id: string;
  interaction_uuid: string | null;
  project_id: string | null;
  thread_id: string | null;
  lane_label: string;
  primary_defect_type: string | null;
  node_statuses: NodeStatuses;
  span_ids: string[];
}

// -- Diagnosis generation --

const LANE_DIAGNOSES: Record<string, string> = {
  ingestion: "calls_raw or interaction missing - process-call may not have completed ingestion",
  segmentation: "conversation_spans or evidence_events missing - segment-call may not have completed",
  attribution: "span_attributions missing or pending review - ai-router may not have completed",
  journal: "journal_claims or open_loops empty - journal-extract may not have fired",
  projection: "redline_thread missing or context stale - projection pipeline may be lagging",
  client: "pending review_queue items - human review outstanding",
  healthy: "full chain present and healthy",
};

function buildChain(ns: NodeStatuses) {
  const chain = [
    {
      lane: "calls_raw",
      status: ns.calls_raw.present ? "EXISTS" : "MISSING",
      count: ns.calls_raw.count,
    },
    {
      lane: "interaction",
      status: ns.interactions.present ? "EXISTS" : "MISSING",
      count: ns.interactions.count,
    },
    {
      lane: "spans",
      status: ns.conversation_spans.present ? "EXISTS" : "MISSING",
      count: ns.conversation_spans.count,
    },
    {
      lane: "evidence_events",
      status: ns.evidence_events.present ? "EXISTS" : "MISSING",
      count: ns.evidence_events.count,
    },
    {
      lane: "attribution",
      status: ns.span_attributions.present
        ? (ns.span_attributions.needs_review_count > 0 ? "NEEDS_REVIEW" : "EXISTS")
        : "MISSING",
      count: ns.span_attributions.count,
      needs_review_count: ns.span_attributions.needs_review_count,
    },
    {
      lane: "review_queue",
      status: ns.review_queue.present ? (ns.review_queue.pending_count > 0 ? "PENDING" : "EXISTS") : "NONE",
      count: ns.review_queue.count,
      pending_count: ns.review_queue.pending_count,
    },
    {
      lane: "journal",
      status: ns.journal_claims.present || ns.journal_open_loops.present ? "EXISTS" : "MISSING",
      claims_count: ns.journal_claims.count,
      open_loops_count: ns.journal_open_loops.count,
    },
    {
      lane: "redline_thread",
      status: ns.redline_thread.present ? "EXISTS" : "MISSING",
      count: ns.redline_thread.count,
    },
    {
      lane: "context_materialization",
      status: ns.context_materialization.staleness_status === "fresh"
        ? "FRESH"
        : ns.context_materialization.staleness_status?.toUpperCase() || "UNKNOWN",
    },
  ];

  return chain;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// -- Replay helpers --

async function replayProcessCall(
  interactionId: string,
  edgeSecret: string,
): Promise<{ status: number; body: unknown; error?: string }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REPLAY_TIMEOUT_MS);
  try {
    const resp = await fetch(PROCESS_CALL_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Edge-Secret": edgeSecret,
        "X-Source": "truth-graph-probe",
      },
      body: JSON.stringify({ interaction_id: interactionId, source: "truth-graph-probe" }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    const body = await resp.json().catch(() => null);
    return { status: resp.status, body };
  } catch (e: unknown) {
    clearTimeout(timer);
    const msg = e instanceof Error ? e.message : String(e);
    return { status: 0, body: null, error: msg };
  }
}

async function replayAiRouter(
  spanId: string,
  edgeSecret: string,
): Promise<{ span_id: string; status: number; body: unknown; error?: string }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REPLAY_TIMEOUT_MS);
  try {
    const resp = await fetch(AI_ROUTER_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Edge-Secret": edgeSecret,
        "X-Source": "truth-graph-probe",
      },
      body: JSON.stringify({ span_id: spanId, source: "truth-graph-probe" }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    const body = await resp.json().catch(() => null);
    return { span_id: spanId, status: resp.status, body };
  } catch (e: unknown) {
    clearTimeout(timer);
    const msg = e instanceof Error ? e.message : String(e);
    return { span_id: spanId, status: 0, body: null, error: msg };
  }
}

// -- Main handler --

Deno.serve(async (req: Request) => {
  // Auth gate
  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code!, `truth-graph-probe ${FUNCTION_VERSION}`);
  }

  // Parse request
  let body: ProbeRequest;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const { interaction_id, action = "probe" } = body;

  if (!interaction_id || !ID_PATTERN.test(interaction_id)) {
    return json(
      { ok: false, error: "invalid_interaction_id", detail: "must match cll_[a-zA-Z0-9_]+" },
      400,
    );
  }

  if (!["probe", "replay_process_call", "replay_ai_router"].includes(action)) {
    return json({ ok: false, error: "invalid_action", detail: "probe|replay_process_call|replay_ai_router" }, 400);
  }

  const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET");
  if (!edgeSecret) {
    return json({ ok: false, error: "server_misconfigured", detail: "EDGE_SHARED_SECRET missing" }, 500);
  }

  // Supabase client for RPC
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceRole) {
    return json({ ok: false, error: "server_misconfigured", detail: "SUPABASE_SERVICE_ROLE_KEY missing" }, 500);
  }
  const db = createClient(SUPABASE_URL, serviceRole);

  // ---- ACTION: probe ----
  if (action === "probe") {
    const { data, error } = await db.rpc("redline_truth_graph_v1", {
      p_interaction_id: interaction_id,
    });

    if (error) {
      return json({ ok: false, error: "rpc_failed", detail: error.message }, 500);
    }

    if (!data || (Array.isArray(data) && data.length === 0)) {
      return json({
        ok: true,
        interaction_id,
        chain: [],
        diagnosis: "interaction not found in any pipeline stage",
        lane_label: "ingestion",
        primary_defect_type: "ingestion_missing",
        version: FUNCTION_VERSION,
      });
    }

    const row: TruthGraphRow = Array.isArray(data) ? data[0] : data;
    const chain = buildChain(row.node_statuses);
    const diagnosis = LANE_DIAGNOSES[row.lane_label] || `unknown lane: ${row.lane_label}`;

    return json({
      ok: true,
      interaction_id,
      interaction_uuid: row.interaction_uuid,
      project_id: row.project_id,
      thread_id: row.thread_id,
      lane_label: row.lane_label,
      primary_defect_type: row.primary_defect_type,
      chain,
      diagnosis,
      node_statuses: row.node_statuses,
      span_ids: row.span_ids,
      version: FUNCTION_VERSION,
    });
  }

  // ---- ACTION: replay_process_call ----
  if (action === "replay_process_call") {
    const result = await replayProcessCall(interaction_id, edgeSecret);
    return json({
      ok: result.status >= 200 && result.status < 300,
      action: "replay_process_call",
      interaction_id,
      replay_status: result.status,
      replay_response: result.body,
      replay_error: result.error || null,
      version: FUNCTION_VERSION,
    });
  }

  // ---- ACTION: replay_ai_router ----
  if (action === "replay_ai_router") {
    // First, get active span IDs for the interaction
    const { data: spans, error: spanErr } = await db
      .from("conversation_spans")
      .select("id")
      .eq("interaction_id", interaction_id)
      .eq("is_superseded", false)
      .order("span_index", { ascending: true });

    if (spanErr) {
      return json({ ok: false, error: "span_lookup_failed", detail: spanErr.message }, 500);
    }

    if (!spans || spans.length === 0) {
      return json({
        ok: false,
        error: "no_active_spans",
        detail: "no active conversation_spans for this interaction - run replay_process_call first",
        interaction_id,
        version: FUNCTION_VERSION,
      }, 404);
    }

    // Replay ai-router for each span sequentially (idempotent)
    const results = [];
    for (const span of spans) {
      const result = await replayAiRouter(span.id, edgeSecret);
      results.push(result);
    }

    const allOk = results.every((r) => r.status >= 200 && r.status < 300);
    return json({
      ok: allOk,
      action: "replay_ai_router",
      interaction_id,
      spans_replayed: results.length,
      results,
      version: FUNCTION_VERSION,
    });
  }

  return json({ ok: false, error: "unhandled_action" }, 400);
});
