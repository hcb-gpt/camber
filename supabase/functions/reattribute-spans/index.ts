/**
 * reattribute-spans Edge Function v0.1.0
 *
 * Re-processes stale span attributions through the current
 * context-assembly → ai-router pipeline. Segments are NOT re-created;
 * only the attribution step is re-run with the latest engine.
 *
 * Auth: X-Edge-Secret (internal only), verify_jwt=false
 *
 * POST body:
 * {
 *   limit?: number,              // max spans per call (default 20, max 50)
 *   dry_run?: boolean,           // default true — preview only
 *   min_confidence?: number,     // floor (default 0)
 *   only_with_project?: boolean, // only spans that already have a project_id
 *   interaction_ids?: string[],  // target specific interactions
 * }
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v0.1.0";
const CURRENT_ENGINE = "ai-router-v1.19.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const EDGE_SECRET = Deno.env.get("EDGE_SHARED_SECRET") || "";
const CONTEXT_ASSEMBLY_URL = `${SUPABASE_URL}/functions/v1/context-assembly`;
const AI_ROUTER_URL = `${SUPABASE_URL}/functions/v1/ai-router`;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-edge-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

interface SpanTarget {
  span_id: string;
  interaction_id: string;
  old_confidence: number;
  old_decision: string;
  old_version: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  const secret = req.headers.get("x-edge-secret") || "";
  if (!EDGE_SECRET || secret !== EDGE_SECRET) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const limit = Math.min(Number(body.limit) || 20, 50);
  const dryRun = body.dry_run !== false; // default true for safety
  const minConfidence = Number(body.min_confidence) || 0;
  const onlyWithProject = body.only_with_project ?? false;
  const interactionIds = Array.isArray(body.interaction_ids) ? body.interaction_ids : null;

  const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // ── Step 1: Find stale review spans ──────────────────────────────
  let query = db
    .from("span_attributions")
    .select(
      "span_id, confidence, decision, attributed_by, project_id, needs_review, attribution_lock",
    )
    .neq("attributed_by", CURRENT_ENGINE)
    .gte("confidence", minConfidence)
    .order("confidence", { ascending: false })
    .limit(limit);

  // Only spans currently in review (either decision=review OR flagged)
  if (!interactionIds) {
    query = query.or("decision.eq.review,needs_review.eq.true");
  }
  if (onlyWithProject) {
    query = query.not("project_id", "is", null);
  }

  const { data: stale, error: staleErr } = await query;
  if (staleErr) {
    return json(
      { ok: false, error: "query_failed", detail: staleErr.message },
      500,
    );
  }
  if (!stale || stale.length === 0) {
    return json({
      ok: true,
      message: "no_stale_spans",
      processed: 0,
      function_version: FUNCTION_VERSION,
    });
  }

  // Filter out human-locked
  const eligible = stale.filter((s) => s.attribution_lock !== "human");

  // ── Step 2: Resolve interaction_ids ──────────────────────────────
  const spanIds = eligible.map((s) => s.span_id);
  const { data: spans, error: spanErr } = await db
    .from("conversation_spans")
    .select("id, interaction_id")
    .in("id", spanIds);

  if (spanErr) {
    return json(
      { ok: false, error: "span_lookup_failed", detail: spanErr.message },
      500,
    );
  }

  const ixMap: Record<string, string> = {};
  (spans || []).forEach((s) => {
    ixMap[s.id] = s.interaction_id;
  });

  let targets: SpanTarget[] = eligible
    .filter((s) => ixMap[s.span_id])
    .map((s) => ({
      span_id: s.span_id,
      interaction_id: ixMap[s.span_id],
      old_confidence: Number(s.confidence),
      old_decision: s.decision,
      old_version: s.attributed_by,
    }));

  // Optional: filter to specific interactions
  if (interactionIds) {
    targets = targets.filter((t) => interactionIds.includes(t.interaction_id));
  }

  // ── Dry run: return preview ──────────────────────────────────────
  if (dryRun) {
    return json({
      ok: true,
      dry_run: true,
      function_version: FUNCTION_VERSION,
      eligible_count: targets.length,
      targets: targets.map((t) => ({
        span_id: t.span_id,
        interaction_id: t.interaction_id,
        old_confidence: t.old_confidence,
        old_decision: t.old_decision,
        old_version: t.old_version,
      })),
    });
  }

  // ── Step 3: Re-process each span ─────────────────────────────────
  const results: Record<string, unknown>[] = [];
  for (const target of targets) {
    const result: Record<string, unknown> = {
      span_id: target.span_id,
      interaction_id: target.interaction_id,
      old_version: target.old_version,
      old_confidence: target.old_confidence,
      old_decision: target.old_decision,
    };

    try {
      // Call context-assembly
      const ctxResp = await fetch(CONTEXT_ASSEMBLY_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": EDGE_SECRET,
        },
        body: JSON.stringify({
          span_id: target.span_id,
          interaction_id: target.interaction_id,
          source: "segment-call",
        }),
      });

      if (!ctxResp.ok) {
        result.status = "context_assembly_failed";
        result.http_status = ctxResp.status;
        result.detail = await ctxResp.text().catch(() => "");
        results.push(result);
        continue;
      }

      const ctxData = await ctxResp.json();
      if (!ctxData?.context_package) {
        result.status = "no_context_package";
        results.push(result);
        continue;
      }

      // Call ai-router
      const routerResp = await fetch(AI_ROUTER_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": EDGE_SECRET,
        },
        body: JSON.stringify({
          context_package: ctxData.context_package,
          dry_run: false,
          source: "segment-call",
        }),
      });

      if (!routerResp.ok) {
        result.status = "ai_router_failed";
        result.http_status = routerResp.status;
        result.detail = await routerResp.text().catch(() => "");
        results.push(result);
        continue;
      }

      const routerData = await routerResp.json();
      result.status = "ok";
      result.new_decision = routerData.decision;
      result.new_confidence = routerData.confidence;
      result.new_project_id = routerData.project_id;
      result.applied = !!routerData.gatekeeper?.applied_project_id;
      results.push(result);
    } catch (err) {
      result.status = "error";
      result.detail = (err as Error).message;
      results.push(result);
    }
  }

  const ok = results.filter((r) => r.status === "ok");
  const summary = {
    total: results.length,
    ok: ok.length,
    upgraded: ok.filter((r) => r.new_decision === "assign" && r.old_decision === "review").length,
    downgraded: ok.filter((r) => r.new_decision === "review" && r.old_decision === "assign").length,
    unchanged: ok.filter((r) => r.new_decision === r.old_decision).length,
    failed: results.filter((r) => r.status !== "ok").length,
  };

  return json({
    ok: true,
    function_version: FUNCTION_VERSION,
    dry_run: false,
    current_engine: CURRENT_ENGINE,
    summary,
    results,
  });
});
