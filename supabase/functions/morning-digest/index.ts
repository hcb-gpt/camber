/**
 * morning-digest Edge Function v1.3.1
 * Returns a structured daily digest for the Camber operator (Chad).
 *
 * @version 1.3.1
 * @date 2026-02-22
 * @purpose Dead-end consumer — surfaces actionable intelligence from pipeline data
 *
 * DESIGN:
 * - READ-ONLY: SELECT queries only, no writes
 * - Returns 6 sections: unresolved_signals, open_loops, review_pressure, recent_claims, pipeline_health, narrative_brief
 * - AUTH: verify_jwt=false + X-Edge-Secret (Pattern A, pipeline internal)
 *
 * SECTIONS:
 * 1. Unresolved signals — top 5 from striking_signals by score DESC, grouped by project
 * 2. Open loops — all from journal_open_loops WHERE status='open', grouped by project
 * 3. Review queue pressure — pending count + top 5 oldest from review_queue
 * 4. Recent claims — last 24h from journal_claims with project context
 * 5. Pipeline health — calls_raw last 24h, segment success rate, summary generation rate
 * 6. Narrative brief — human-readable operator summary with fallback behavior
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v1.3.1";
const jsonHeaders = { "Content-Type": "application/json", "Connection": "keep-alive" };
const OPERATOR_UNAVAILABLE_TEXT = "CAMBER brief unavailable";

function unavailableResponse(
  t0: number,
  status: number,
  reasonCode: "AUTH_FAILED" | "TRANSFORM_ERROR" | "INTEGRITY_GUARD_FAILED",
  detail: string | null = null,
): Response {
  return new Response(
    JSON.stringify({
      ok: false,
      status: "UNAVAILABLE",
      message: OPERATOR_UNAVAILABLE_TEXT,
      fallback_text: OPERATOR_UNAVAILABLE_TEXT,
      reason_code: reasonCode,
      detail,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    }),
    { status, headers: jsonHeaders },
  );
}

function hasDigestIntegrity(digest: Record<string, unknown>): boolean {
  const narrative = digest.narrative_brief as Record<string, unknown> | undefined;
  const whereToLook = narrative?.where_to_look_first;

  return digest.ok === true &&
    typeof digest.generated_at === "string" &&
    typeof digest.function_version === "string" &&
    typeof digest.ms === "number" &&
    typeof digest.unresolved_signals === "object" &&
    typeof digest.open_loops === "object" &&
    typeof digest.review_pressure === "object" &&
    typeof digest.recent_claims === "object" &&
    typeof digest.pipeline_health === "object" &&
    typeof narrative === "object" &&
    typeof narrative?.what_changed === "string" &&
    typeof narrative?.why_it_matters === "string" &&
    Array.isArray(whereToLook);
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "GET" && req.method !== "POST") {
    return new Response(JSON.stringify({ error: "GET or POST only" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  // AUTH: X-Edge-Secret (Pattern A — pipeline internal)
  const edgeSecret = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  if (!expectedSecret || edgeSecret !== expectedSecret) {
    return unavailableResponse(t0, 401, "AUTH_FAILED", "X-Edge-Secret required");
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    // ── SECTION 1: Unresolved Striking Signals ────────────────────
    const { data: strikingRaw, error: strikingErr } = await db
      .from("striking_signals")
      .select(`
        id,
        interaction_id,
        span_id,
        striking_score,
        primary_signal_type,
        signals,
        created_at
      `)
      .order("striking_score", { ascending: false })
      .limit(20);

    if (strikingErr) console.error("[morning-digest] striking_signals error:", strikingErr.message);

    // Get project context for striking signals via span_attributions
    const strikingSpanIds = (strikingRaw || []).map((s: any) => s.span_id).filter(Boolean);
    const spanProjectMap: Record<string, { project_id: string; project_name: string }> = {};

    if (strikingSpanIds.length > 0) {
      const { data: attrData } = await db
        .from("span_attributions")
        .select("span_id, applied_project_id, project_id")
        .in("span_id", strikingSpanIds);

      const projectIds = [
        ...new Set(
          (attrData || [])
            .map((a: any) => a.applied_project_id || a.project_id)
            .filter(Boolean),
        ),
      ];

      if (projectIds.length > 0) {
        const { data: projects } = await db
          .from("projects")
          .select("id, name")
          .in("id", projectIds);

        const projectNameMap: Record<string, string> = {};
        for (const p of projects || []) {
          projectNameMap[p.id] = p.name;
        }

        for (const attr of attrData || []) {
          const pid = attr.applied_project_id || attr.project_id;
          if (pid) {
            spanProjectMap[attr.span_id] = {
              project_id: pid,
              project_name: projectNameMap[pid] || "Unknown",
            };
          }
        }
      }
    }

    // Group top 5 by project
    const strikingByProject: Record<string, any[]> = {};
    for (const sig of (strikingRaw || []).slice(0, 5)) {
      const proj = spanProjectMap[sig.span_id];
      const key = proj ? proj.project_name : "Unattributed";
      if (!strikingByProject[key]) strikingByProject[key] = [];
      strikingByProject[key].push({
        interaction_id: sig.interaction_id,
        striking_score: sig.striking_score,
        primary_signal_type: sig.primary_signal_type,
        signals: sig.signals,
        created_at: sig.created_at,
      });
    }

    // ── SECTION 2: Open Loops ─────────────────────────────────────
    const { data: loopsRaw, error: loopsErr } = await db
      .from("journal_open_loops")
      .select(`
        id,
        call_id,
        project_id,
        loop_type,
        description,
        status,
        created_at
      `)
      .eq("status", "open")
      .order("created_at", { ascending: false });

    if (loopsErr) console.error("[morning-digest] journal_open_loops error:", loopsErr.message);

    // Get project names for open loops
    const loopProjectIds = [
      ...new Set(
        (loopsRaw || []).map((l: any) => l.project_id).filter(Boolean),
      ),
    ];

    const loopProjectNameMap: Record<string, string> = {};
    if (loopProjectIds.length > 0) {
      const { data: projects } = await db
        .from("projects")
        .select("id, name")
        .in("id", loopProjectIds);

      for (const p of projects || []) {
        loopProjectNameMap[p.id] = p.name;
      }
    }

    // Group by project
    const loopsByProject: Record<string, any[]> = {};
    for (const loop of loopsRaw || []) {
      const key = loop.project_id ? (loopProjectNameMap[loop.project_id] || "Unknown") : "Unattributed";
      if (!loopsByProject[key]) loopsByProject[key] = [];
      loopsByProject[key].push({
        call_id: loop.call_id,
        loop_type: loop.loop_type,
        description: loop.description,
        created_at: loop.created_at,
      });
    }

    // ── SECTION 3: Review Queue Pressure ──────────────────────────
    const { count: pendingCount, error: pendingErr } = await db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending");

    if (pendingErr) console.error("[morning-digest] review_queue count error:", pendingErr.message);

    const { data: oldestPending, error: oldestErr } = await db
      .from("review_queue")
      .select(`
        id,
        interaction_id,
        reasons,
        reason_codes,
        module,
        status,
        created_at
      `)
      .eq("status", "pending")
      .order("created_at", { ascending: true })
      .limit(5);

    if (oldestErr) console.error("[morning-digest] review_queue oldest error:", oldestErr.message);

    // Also get v_needs_triage summary for richer context
    const { data: triageData, error: triageErr } = await db
      .from("v_needs_triage")
      .select("triage_type, status, primary_reason, module, urgency_score")
      .eq("status", "pending")
      .order("urgency_score", { ascending: false })
      .limit(10);

    if (triageErr) console.error("[morning-digest] v_needs_triage error:", triageErr.message);

    // ── SECTION 4: Recent Claims (last 24h) ───────────────────────
    const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    const { count: recentClaimCount } = await db
      .from("journal_claims")
      .select("claim_id", { count: "exact", head: true })
      .gte("created_at", twentyFourHoursAgo);

    // Get claim breakdown by type
    const { data: recentClaimsRaw } = await db
      .from("journal_claims")
      .select("claim_type, project_id, claim_text, created_at")
      .gte("created_at", twentyFourHoursAgo)
      .order("created_at", { ascending: false })
      .limit(50);

    // Group by claim_type
    const claimsByType: Record<string, number> = {};
    const claimProjectIds = [
      ...new Set(
        (recentClaimsRaw || []).map((c: any) => c.project_id).filter(Boolean),
      ),
    ];

    for (const c of recentClaimsRaw || []) {
      claimsByType[c.claim_type] = (claimsByType[c.claim_type] || 0) + 1;
    }

    const claimProjectNameMap: Record<string, string> = {};
    if (claimProjectIds.length > 0) {
      const { data: projects } = await db
        .from("projects")
        .select("id, name")
        .in("id", claimProjectIds);

      for (const p of projects || []) {
        claimProjectNameMap[p.id] = p.name;
      }
    }

    // Group by project
    const claimsByProject: Record<string, number> = {};
    for (const c of recentClaimsRaw || []) {
      const key = c.project_id ? (claimProjectNameMap[c.project_id] || "Unknown") : "Unattributed";
      claimsByProject[key] = (claimsByProject[key] || 0) + 1;
    }

    // ── SECTION 5: Pipeline Health ────────────────────────────────
    // 5a: calls_raw ingested last 24h
    const { count: callsRawCount } = await db
      .from("calls_raw")
      .select("id", { count: "exact", head: true })
      .gte("event_at_utc", twentyFourHoursAgo);

    // 5b: interactions last 24h
    const { count: interactionsCount } = await db
      .from("interactions")
      .select("id", { count: "exact", head: true })
      .gte("ingested_at_utc", twentyFourHoursAgo);

    // 5c: segment success rate — spans created last 24h
    const { count: spansCreated } = await db
      .from("conversation_spans")
      .select("id", { count: "exact", head: true })
      .gte("created_at", twentyFourHoursAgo);

    // 5d: summary generation rate — interactions with human_summary in last 24h
    const { count: summariesGenerated } = await db
      .from("interactions")
      .select("id", { count: "exact", head: true })
      .gte("ingested_at_utc", twentyFourHoursAgo)
      .not("human_summary", "is", null);

    // 5e: journal_runs last 24h
    const { data: journalRunStats } = await db
      .from("journal_runs")
      .select("status")
      .gte("created_at", twentyFourHoursAgo);

    const runsByStatus: Record<string, number> = {};
    for (const r of journalRunStats || []) {
      runsByStatus[r.status] = (runsByStatus[r.status] || 0) + 1;
    }

    // ── SECTION 6: Human-Readable Narrative (additive) ───────────
    const { data: manifestRows, error: manifestErr } = await db
      .from("v_morning_manifest")
      .select("project_id, project_name, new_calls, new_journal_entries, new_striking_signals, pending_reviews")
      .order("new_calls", { ascending: false })
      .limit(5);

    if (manifestErr) {
      console.error("[morning-digest] v_morning_manifest error:", manifestErr.message);
    }

    const { data: projectFeedRows, error: projectFeedErr } = await db
      .from("v_project_feed")
      .select(
        "project_id, project_name, active_journal_claims, open_loops, striking_signal_count, pending_reviews, risk_flag",
      )
      .order("active_journal_claims", { ascending: false })
      .limit(5);

    if (projectFeedErr) {
      console.error("[morning-digest] v_project_feed error:", projectFeedErr.message);
    }

    const hasManifestRows = (manifestRows || []).length > 0;
    const fallbackActive = !hasManifestRows;

    const whereToLookFirst = hasManifestRows
      ? (manifestRows || []).map((row: any) =>
        `${row.project_name || "Unknown"}: ${row.new_calls || 0} new calls, ${
          row.pending_reviews || 0
        } pending reviews, ${row.new_striking_signals || 0} new striking signals`
      )
      : (projectFeedRows || []).map((row: any) =>
        `${row.project_name || "Unknown"}: ${row.open_loops || 0} open loops, ${
          row.pending_reviews || 0
        } pending reviews, risk=${row.risk_flag || "normal"}`
      );

    const whatChanged = `In the last 24 hours, ${callsRawCount || 0} calls were ingested, ${
      recentClaimCount || 0
    } claims were extracted, ${strikingRaw?.length || 0} striking signals were scored, and ${
      loopsRaw?.length || 0
    } open loops are currently active.`;

    const whyItMatters = pendingCount && pendingCount > 1000
      ? `Review backlog is elevated (${pendingCount} pending), which can delay human confirmation and increase stale operational risk if not triaged first.`
      : `Review backlog is manageable (${
        pendingCount || 0
      } pending), so operators can prioritize high-signal projects and open loops without losing coverage.`;

    // ── ASSEMBLE RESPONSE ─────────────────────────────────────────
    const digest = {
      ok: true,
      generated_at: new Date().toISOString(),
      function_version: FUNCTION_VERSION,

      // Section 1
      unresolved_signals: {
        description: "Top 5 striking signals by score, grouped by project",
        by_project: strikingByProject,
        total_striking_signals: (strikingRaw || []).length,
      },

      // Section 2
      open_loops: {
        description: "All open loops from journal extraction, grouped by project",
        total_open: (loopsRaw || []).length,
        by_project: loopsByProject,
      },

      // Section 3
      review_pressure: {
        description: "Review queue status — pending items needing human triage",
        pending_count: pendingCount || 0,
        oldest_pending: (oldestPending || []).map((r: any) => ({
          interaction_id: r.interaction_id,
          reasons: r.reasons,
          reason_codes: r.reason_codes,
          module: r.module,
          created_at: r.created_at,
          age_hours: Math.round((Date.now() - new Date(r.created_at).getTime()) / 3600000),
        })),
        triage_top_urgency: (triageData || []).slice(0, 5).map((t: any) => ({
          triage_type: t.triage_type,
          primary_reason: t.primary_reason,
          module: t.module,
          urgency_score: t.urgency_score,
        })),
      },

      // Section 4
      recent_claims: {
        description: "Journal claims extracted in the last 24 hours",
        total_24h: recentClaimCount || 0,
        by_type: claimsByType,
        by_project: claimsByProject,
      },

      // Section 5
      pipeline_health: {
        description: "Pipeline throughput and success rates (last 24h)",
        window: "24h",
        calls_raw_ingested: callsRawCount || 0,
        interactions_processed: interactionsCount || 0,
        spans_created: spansCreated || 0,
        summaries_generated: summariesGenerated || 0,
        summary_rate: interactionsCount
          ? `${Math.round(((summariesGenerated || 0) / interactionsCount) * 100)}%`
          : "N/A",
        journal_runs: runsByStatus,
        claims_extracted: recentClaimCount || 0,
      },

      // Section 6
      narrative_brief: {
        description:
          "Human-readable operator summary (what changed, why it matters, where to look first). Structured sections remain unchanged for machine consumers.",
        source_mode: fallbackActive
          ? "fallback_v_project_feed_plus_digest_totals"
          : "v_morning_manifest_plus_digest_totals",
        fallback_active: fallbackActive,
        what_changed: whatChanged,
        why_it_matters: whyItMatters,
        where_to_look_first: whereToLookFirst,
      },

      ms: Date.now() - t0,
    };

    if (!hasDigestIntegrity(digest)) {
      console.error("[morning-digest] integrity guard failed");
      return unavailableResponse(t0, 503, "INTEGRITY_GUARD_FAILED", "Digest shape validation failed");
    }

    return new Response(JSON.stringify(digest, null, 2), {
      status: 200,
      headers: jsonHeaders,
    });
  } catch (e: any) {
    console.error("[morning-digest] Error:", e.message);
    return unavailableResponse(t0, 500, "TRANSFORM_ERROR", e?.message || "Unknown failure");
  }
});
