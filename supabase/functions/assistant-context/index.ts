import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "assistant-context_v1.0.0";

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, content-type",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
  };
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  if (req.method !== "GET") {
    return json({ ok: false, error: "Method not allowed" }, 405);
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
    const { data: projectFeed } = await sb
      .from("v_project_feed")
      .select(
        "project_id, project_name, phase, interactions_7d, active_journal_claims, open_loops, pending_reviews, striking_signal_count, risk_flag",
      )
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
        .select("*")
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
        project: proj,
        recent_timeline: timeline ?? [],
        intelligence: intel,
      };
    }

    const packet = {
      ok: true,
      generated_at: new Date().toISOString(),
      function_version: FUNCTION_VERSION,
      pipeline_health: pipelineHealth ?? [],
      top_projects: projectFeed ?? [],
      who_needs_you: whoNeeds ?? [],
      review_pressure: reviewSummary,
      recent_activity: {
        calls_24h: callCount24h ?? 0,
        latest_calls: recentCalls ?? [],
      },
      project_context: projectContext,
      ms: Date.now() - t0,
    };

    return json(packet);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return json(
      { ok: false, error: msg, function_version: FUNCTION_VERSION },
      500,
    );
  }
});
