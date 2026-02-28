import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "assistant-context_v1.2.0";
const METRIC_CONTRACT_VERSION = "assistant_context_metric_contract_v3";

const TOP_PROJECT_METRIC_FIELDS = [
  "interactions_7d",
  "active_journal_claims_total",
  "active_journal_claims_7d",
  "open_loops_total",
  "open_loops_7d",
  "pending_reviews_span_total",
  "pending_reviews_queue_total",
  "pending_reviews_queue_7d",
];

const TOP_PROJECT_REMOVED_ALIASES = [
  "active_journal_claims",
  "open_loops",
  "pending_reviews",
];

const PROJECT_FEED_SELECT_COLUMNS = [
  "project_id",
  "project_name",
  "phase",
  "interactions_7d",
  "active_journal_claims_total",
  "active_journal_claims_7d",
  "open_loops_total",
  "open_loops_7d",
  "pending_reviews_span_total",
  "pending_reviews_queue_total",
  "pending_reviews_queue_7d",
  "striking_signal_count",
  "risk_flag",
];

const PROJECT_CONTEXT_SELECT_COLUMNS = [
  ...PROJECT_FEED_SELECT_COLUMNS,
  "project_status",
  "client_name",
  "total_interactions",
  "last_interaction_at",
  "promoted_claims",
  "last_promoted_at",
  "last_striking_at",
];

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, content-type",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
  };
}

function json(data: unknown, status = 200, requestId?: string): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...(requestId ? { "x-request-id": requestId } : {}),
      ...corsHeaders(),
    },
  });
}

function asNumber(value: unknown): number {
  const num = Number(value);
  return Number.isFinite(num) ? num : 0;
}

function asNullableString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function normalizeProjectFeedRow(
  row: Record<string, unknown>,
): Record<string, unknown> {
  return {
    project_id: asNullableString(row.project_id),
    project_name: asNullableString(row.project_name),
    phase: asNullableString(row.phase),
    interactions_7d: asNumber(row.interactions_7d),
    active_journal_claims_total: asNumber(row.active_journal_claims_total),
    active_journal_claims_7d: asNumber(row.active_journal_claims_7d),
    open_loops_total: asNumber(row.open_loops_total),
    open_loops_7d: asNumber(row.open_loops_7d),
    pending_reviews_span_total: asNumber(row.pending_reviews_span_total),
    pending_reviews_queue_total: asNumber(row.pending_reviews_queue_total),
    pending_reviews_queue_7d: asNumber(row.pending_reviews_queue_7d),
    striking_signal_count: asNumber(row.striking_signal_count),
    risk_flag: asNullableString(row.risk_flag),
  };
}

function normalizeProjectContextRow(
  row: Record<string, unknown>,
): Record<string, unknown> {
  return {
    ...normalizeProjectFeedRow(row),
    project_status: asNullableString(row.project_status),
    client_name: asNullableString(row.client_name),
    total_interactions: asNumber(row.total_interactions),
    last_interaction_at: asNullableString(row.last_interaction_at),
    promoted_claims: asNumber(row.promoted_claims),
    last_promoted_at: asNullableString(row.last_promoted_at),
    last_striking_at: asNullableString(row.last_striking_at),
  };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();
  if (req.method !== "GET") {
    return json({ ok: false, error: "Method not allowed", request_id: requestId }, 405, requestId);
  }

  const t0 = Date.now();

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sb = createClient(supabaseUrl, serviceKey);

  const url = new URL(req.url);
  const projectId = url.searchParams.get("project_id");
  const limit = Math.min(
    parseInt(url.searchParams.get("limit") ?? "10", 10) || 10,
    50,
  );

  try {
    // 1. Pipeline health snapshot
    const { data: pipelineHealth } = await sb
      .from("v_pipeline_health")
      .select("capability, total, last_at, hours_stale");

    // 2. Top active projects (by 7-day interactions)
    const { data: projectFeedRaw } = await sb
      .from("v_project_feed")
      .select(PROJECT_FEED_SELECT_COLUMNS.join(", "))
      .order("interactions_7d", { ascending: false })
      .limit(limit);

    // 3. Who needs you today (people signals)
    const { data: whoNeeds } = await sb
      .from("v_who_needs_you_today")
      .select("category, project, detail, speaker, hours_ago")
      .order("hours_ago", { ascending: true })
      .limit(10);

    // 4. Review queue pressure
    const { data: reviewSummary } = await sb
      .from("v_review_queue_summary")
      .select("*")
      .limit(1)
      .maybeSingle();

    const { data: reviewSummaryByProject } = await sb
      .from("v_review_queue_project_summary")
      .select(
        "project_id, project_name, pending_reviews_total, pending_reviews_7d, oldest_pending_created_at, latest_pending_created_at",
      )
      .order("pending_reviews_total", { ascending: false })
      .limit(10);

    // 5. Recent calls (last 24h)
    const { data: recentCalls, count: callCount24h } = await sb
      .from("calls_raw")
      .select("id, other_party_name, channel, event_at_utc, summary", {
        count: "exact",
      })
      .gte(
        "ingested_at_utc",
        new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString(),
      )
      .order("event_at_utc", { ascending: false })
      .limit(5);

    // 6. Optional: project-specific context
    let projectContext = null;
    if (projectId) {
      const { data: proj } = await sb
        .from("v_project_feed")
        .select(PROJECT_CONTEXT_SELECT_COLUMNS.join(", "))
        .eq("project_id", projectId)
        .maybeSingle();

      const { data: timeline } = await sb
        .from("v_project_activity_timeline")
        .select(
          "event_type, event_at, summary, contact_name, source_table, source_id",
        )
        .eq("project_id", projectId)
        .order("event_at", { ascending: false })
        .limit(10);

      const { data: intel } = await sb
        .from("v_project_intelligence_coverage")
        .select("*")
        .eq("project_id", projectId)
        .maybeSingle();

      projectContext = {
        project: proj ? normalizeProjectContextRow(proj as unknown as Record<string, unknown>) : null,
        recent_timeline: timeline ?? [],
        intelligence: intel,
      };
    }

    const projectFeedRows = Array.isArray(projectFeedRaw)
      ? (projectFeedRaw as unknown as Array<Record<string, unknown>>)
      : [];

    const projectFeed = projectFeedRows.map((row) => normalizeProjectFeedRow(row));

    const packet = {
      ok: true,
      request_id: requestId,
      generated_at: new Date().toISOString(),
      function_version: FUNCTION_VERSION,
      contract_version: METRIC_CONTRACT_VERSION,
      metric_contract: {
        version: METRIC_CONTRACT_VERSION,
        top_projects: {
          explicit_metric_fields: TOP_PROJECT_METRIC_FIELDS,
          preferred_display_fields_7d: [
            "interactions_7d",
            "active_journal_claims_7d",
            "open_loops_7d",
            "pending_reviews_queue_7d",
          ],
          removed_ambiguous_aliases: TOP_PROJECT_REMOVED_ALIASES,
        },
      },
      pipeline_health: pipelineHealth ?? [],
      top_projects: projectFeed ?? [],
      who_needs_you: whoNeeds ?? [],
      review_pressure: reviewSummary,
      review_pressure_by_project: reviewSummaryByProject ?? [],
      recent_activity: {
        calls_24h: callCount24h ?? 0,
        latest_calls: recentCalls ?? [],
      },
      project_context: projectContext,
      ms: Date.now() - t0,
    };

    return json(packet, 200, requestId);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return json(
      {
        ok: false,
        error: msg,
        request_id: requestId,
        function_version: FUNCTION_VERSION,
        contract_version: METRIC_CONTRACT_VERSION,
      },
      500,
      requestId,
    );
  }
});
