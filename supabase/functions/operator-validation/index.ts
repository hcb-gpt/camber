/**
 * operator-validation Edge Function v0.2.0
 *
 * Purpose:
 * - GET: Read spans from v_operator_span_why with existing feedback map
 * - POST: Write verdict (CORRECT/INCORRECT/UNSURE) to attribution_validation_feedback (auth required)
 *
 * Auth: verify_jwt=true at the gateway. GET and POST require Bearer JWT.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v0.2.2";
const CURRENT_ENGINE = "ai-router-v1.19.0";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

interface AuthResult {
  user: { id: string; email?: string } | null;
}

async function tryAuth(req: Request, supabaseUrl: string): Promise<AuthResult> {
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return { user: null };

  const userClient = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: `Bearer ${token}` } } },
  );
  const { data, error } = await userClient.auth.getUser();
  if (error || !data?.user) return { user: null };
  return { user: { id: data.user.id, email: data.user.email ?? undefined } };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) {
    return json({ ok: false, error: "missing_supabase_env" }, 500);
  }

  const db = createClient(supabaseUrl, serviceRole);

  // --- GET: fetch spans + feedback (gateway JWT required) ---
  if (req.method === "GET") {
    const auth = await tryAuth(req, supabaseUrl);

    const url = new URL(req.url);
    const filter = url.searchParams.get("filter") || "all";
    const limit = Math.min(
      Number(url.searchParams.get("limit") || "100"),
      500,
    );

    let query = db
      .from("v_operator_span_why")
      .select("*")
      .order("attributed_at", { ascending: false })
      .limit(limit);

    if (filter === "needs_review") {
      query = query.eq("decision", "review");
    } else if (filter === "assigned") {
      query = query.eq("decision", "assign");
    }

    const engine = url.searchParams.get("engine") || "current";
    if (engine === "current") {
      query = query.eq("attributed_by", CURRENT_ENGINE);
    }

    const { data: spans, error: spanErr } = await query;
    if (spanErr) {
      return json(
        { ok: false, error: "span_query_failed", detail: spanErr.message },
        500,
      );
    }

    const spanIds = (spans ?? [])
      .map((s: Record<string, unknown>) => s.span_id)
      .filter(Boolean);
    const feedbackMap: Record<string, string> = {};

    if (spanIds.length > 0) {
      const { data: fb } = await db
        .from("attribution_validation_feedback")
        .select("span_id, verdict, created_at")
        .in("span_id", spanIds)
        .order("created_at", { ascending: false });

      if (fb) {
        for (
          const row of fb as Array<{ span_id: string; verdict: string }>
        ) {
          if (!feedbackMap[row.span_id]) {
            feedbackMap[row.span_id] = row.verdict;
          }
        }
      }
    }

    return json({
      ok: true,
      function_version: FUNCTION_VERSION,
      user: auth.user ? { email: auth.user.email, id: auth.user.id } : null,
      count: (spans ?? []).length,
      spans: spans ?? [],
      feedback_map: feedbackMap,
    });
  }

  // --- POST: submit verdict (auth required) ---
  if (req.method === "POST") {
    const auth = await tryAuth(req, supabaseUrl);
    if (!auth.user) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json({ ok: false, error: "invalid_json" }, 400);
    }

    const spanId = body.span_id ? String(body.span_id).trim() : null;
    const rawVerdict = body.verdict ? String(body.verdict).trim().toUpperCase() : null;
    const notes = body.notes ? String(body.notes).trim() : null;

    if (!spanId) {
      return json({ ok: false, error: "missing_span_id" }, 400);
    }
    if (
      !rawVerdict ||
      !["CORRECT", "INCORRECT", "UNSURE"].includes(rawVerdict)
    ) {
      return json({
        ok: false,
        error: "invalid_verdict",
        hint: "Must be CORRECT, INCORRECT, or UNSURE",
      }, 400);
    }

    const { error: upsertErr } = await db
      .from("attribution_validation_feedback")
      .upsert({
        span_id: spanId,
        verdict: rawVerdict,
        notes: notes,
        interaction_id: body.interaction_id ? String(body.interaction_id) : null,
        project_id: body.project_id ? String(body.project_id) : null,
        created_by: auth.user.id,
        source: "operator-validation-ui",
      }, { onConflict: "span_id,source" });

    if (upsertErr) {
      return json(
        { ok: false, error: "insert_failed", detail: upsertErr.message },
        500,
      );
    }

    return json({
      ok: true,
      function_version: FUNCTION_VERSION,
      span_id: spanId,
      verdict: rawVerdict,
    });
  }

  return json({ ok: false, error: "method_not_allowed" }, 405);
});
