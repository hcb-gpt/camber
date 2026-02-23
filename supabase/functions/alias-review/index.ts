/**
 * alias-review Edge Function v1.0.0
 * Review and approve/reject suggested project aliases
 *
 * @version 1.0.0
 * @date 2026-02-16
 * @purpose List pending alias suggestions and approve/reject them
 *
 * Called by: Claude agents (Agent Teams) on behalf of CHAD
 * Auth: Internal pattern (X-Edge-Secret + source allowlist) OR service_role key
 * verify_jwt = false (config.toml)
 *
 * GET:  List pending suggestions with collision detection
 * POST: Approve or reject suggestions in batch
 *
 * Approve path:
 *   1. Try promote_alias RPC
 *   2. Fallback: direct INSERT into project_aliases + UPDATE suggested_aliases
 *   Idempotency: ON CONFLICT (project_id, lower(alias)) WHERE active=true DO NOTHING
 *
 * Reject path:
 *   UPDATE suggested_aliases SET status='rejected', reviewed_at, reviewed_by
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

// ============================================================
// TYPES
// ============================================================

interface ApproveRejectRequest {
  action: "approve" | "reject";
  suggestion_ids: string[];
  reviewed_by: string;
}

const MAX_BATCH = 100;
const DEFAULT_LIMIT = 50;
const VERSION = "alias-review_v1.0.0";
const ALLOWED_SOURCES = ["agent-teams", "claude-chat", "alias-review", "test"];

// ============================================================
// MAIN
// ============================================================

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(),
    });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse(
      { ok: false, error: "METHOD_NOT_ALLOWED", detail: "GET or POST only" },
      405,
    );
  }

  // ========================================
  // 1. AUTH — X-Edge-Secret OR service_role key
  // ========================================
  const authResult = authenticateRequest(req);
  if (!authResult.ok) {
    return authErrorResponse(authResult.error_code!, authResult.detail);
  }

  // ========================================
  // 2. INIT DB CLIENT (service_role)
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ========================================
  // 3. ROUTE BY METHOD
  // ========================================
  if (req.method === "GET") {
    return await handleGet(db, req, t0);
  }
  return await handlePost(db, req, t0);
});

// ============================================================
// GET — List pending suggestions
// ============================================================

async function handleGet(
  db: ReturnType<typeof createClient>,
  req: Request,
  t0: number,
): Promise<Response> {
  const url = new URL(req.url);
  const limitParam = url.searchParams.get("limit");
  const limit = limitParam ? Math.min(Math.max(parseInt(limitParam, 10), 1), 200) : DEFAULT_LIMIT;

  // Fetch pending suggestions joined with projects
  const { data: suggestions, error: fetchErr } = await db
    .from("suggested_aliases")
    .select("id, project_id, alias, alias_type, source, confidence, rationale, suggested_at, projects(name)")
    .eq("status", "pending")
    .order("suggested_at", { ascending: true })
    .limit(limit);

  if (fetchErr) {
    console.error(`[alias-review] Failed to fetch suggestions: ${fetchErr.message}`);
    return jsonResponse({
      ok: false,
      error: "FETCH_FAILED",
      detail: fetchErr.message,
    }, 500);
  }

  // Check for collisions for each suggestion
  const results = [];
  for (const s of suggestions || []) {
    const collisions = await findCollisions(db, s.alias, s.project_id);
    const projectName = s.projects && typeof s.projects === "object" && "name" in s.projects
      ? (s.projects as { name: string }).name
      : null;

    results.push({
      id: s.id,
      project_id: s.project_id,
      project_name: projectName,
      alias: s.alias,
      alias_type: s.alias_type,
      source: s.source,
      confidence: s.confidence,
      rationale: s.rationale,
      suggested_at: s.suggested_at,
      collisions,
    });
  }

  const elapsed = Date.now() - t0;
  console.log(
    `[alias-review] GET pending=${results.length} limit=${limit} ms=${elapsed}`,
  );

  return jsonResponse({
    ok: true,
    version: VERSION,
    pending_count: results.length,
    suggestions: results,
    ms: elapsed,
  }, 200);
}

// ============================================================
// GET HELPER — Find alias collisions
// ============================================================

async function findCollisions(
  db: ReturnType<typeof createClient>,
  alias: string,
  excludeProjectId: string,
): Promise<{ project_id: string; project_name: string }[]> {
  // v_project_alias_lookup only has (project_id, alias) — no project_name.
  // Query the view for collisions, then resolve names from projects table.
  const { data, error } = await db
    .from("v_project_alias_lookup")
    .select("project_id")
    .ilike("alias", alias)
    .neq("project_id", excludeProjectId);

  if (error || !data || data.length === 0) {
    return [];
  }

  const projectIds = [...new Set(data.map((r: { project_id: string }) => r.project_id))];
  const { data: projects } = await db
    .from("projects")
    .select("id, name")
    .in("id", projectIds);

  const nameMap = new Map((projects || []).map((p: { id: string; name: string }) => [p.id, p.name]));
  return projectIds.map((pid: string) => ({
    project_id: pid,
    project_name: nameMap.get(pid) || "unknown",
  }));
}

// ============================================================
// POST — Approve/reject suggestions
// ============================================================

async function handlePost(
  db: ReturnType<typeof createClient>,
  req: Request,
  t0: number,
): Promise<Response> {
  // Parse body
  let body: ApproveRejectRequest;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ ok: false, error: "INVALID_JSON" }, 400);
  }

  // Validate action
  if (body.action !== "approve" && body.action !== "reject") {
    return jsonResponse({
      ok: false,
      error: "INVALID_ACTION",
      detail: "action must be 'approve' or 'reject'",
    }, 400);
  }

  // Validate suggestion_ids
  if (!body.suggestion_ids || !Array.isArray(body.suggestion_ids)) {
    return jsonResponse({
      ok: false,
      error: "MISSING_SUGGESTION_IDS",
      detail: "Request must include a suggestion_ids array",
    }, 400);
  }

  if (body.suggestion_ids.length === 0) {
    return jsonResponse({
      ok: false,
      error: "EMPTY_SUGGESTION_IDS",
      detail: "suggestion_ids array must not be empty",
    }, 400);
  }

  if (body.suggestion_ids.length > MAX_BATCH) {
    return jsonResponse({
      ok: false,
      error: "BATCH_TOO_LARGE",
      detail: `Max ${MAX_BATCH} suggestions per request, got ${body.suggestion_ids.length}`,
    }, 400);
  }

  if (!body.reviewed_by || body.reviewed_by.trim().length === 0) {
    return jsonResponse({
      ok: false,
      error: "MISSING_REVIEWED_BY",
      detail: "reviewed_by is required",
    }, 400);
  }

  // Validate each ID is a UUID
  for (let i = 0; i < body.suggestion_ids.length; i++) {
    if (!isValidUUID(body.suggestion_ids[i])) {
      return jsonResponse({
        ok: false,
        error: "INVALID_SUGGESTION_ID",
        detail: `suggestion_ids[${i}] is not a valid UUID`,
      }, 400);
    }
  }

  // Process each suggestion
  const results: Record<string, unknown>[] = [];
  let successCount = 0;
  let errorCount = 0;

  for (let i = 0; i < body.suggestion_ids.length; i++) {
    const id = body.suggestion_ids[i];
    const result = body.action === "approve"
      ? await approveOne(db, id, body.reviewed_by, i)
      : await rejectOne(db, id, body.reviewed_by, i);

    results.push(result);
    if (result.ok) {
      successCount++;
    } else {
      errorCount++;
    }
  }

  const elapsed = Date.now() - t0;
  console.log(
    `[alias-review] POST action=${body.action} total=${body.suggestion_ids.length} ok=${successCount} err=${errorCount} ms=${elapsed}`,
  );

  // RUNTIME LINEAGE (fire-and-forget)
  try {
    const lineageEdges: { from: string; to: string; type: string }[] = [
      { from: "edge:alias-review", to: "table:public.suggested_aliases", type: "reads" },
      { from: "edge:alias-review", to: "table:public.projects", type: "reads" },
      { from: "edge:alias-review", to: "view:public.v_project_alias_lookup", type: "reads" },
      { from: "edge:alias-review", to: "table:public.project_aliases", type: "reads" },
      { from: "edge:alias-review", to: "table:public.project_aliases", type: "writes" },
      { from: "edge:alias-review", to: "table:public.suggested_aliases", type: "writes" },
    ];
    const { error: lineageErr } = await db.from("evidence_events").upsert({
      source_type: "lineage",
      source_id: `alias-review:${body.action}:${Date.now()}`,
      source_run_id: "alias-review:" + VERSION,
      transcript_variant: "baseline",
      metadata: {
        edges: lineageEdges,
        pipeline_version: VERSION,
        action: body.action,
      },
    }, { onConflict: "source_type,source_id,transcript_variant" });
    if (lineageErr) console.warn(`lineage_emit: ${lineageErr.message}`);
  } catch { /* lineage must never block */ }

  return jsonResponse({
    ok: errorCount === 0,
    version: VERSION,
    action: body.action,
    total: body.suggestion_ids.length,
    success_count: successCount,
    error_count: errorCount,
    results,
    ms: elapsed,
  }, errorCount === 0 ? 200 : 207);
}

// ============================================================
// CORE: Approve one suggestion
// ============================================================

async function approveOne(
  db: ReturnType<typeof createClient>,
  suggestionId: string,
  reviewedBy: string,
  index: number,
): Promise<Record<string, unknown>> {
  try {
    // Try RPC first
    const { data: rpcData, error: rpcErr } = await db.rpc("promote_alias", {
      p_suggestion_id: suggestionId,
      p_reviewed_by: reviewedBy,
    });

    if (!rpcErr) {
      const result = typeof rpcData === "string" ? JSON.parse(rpcData) : rpcData;
      // Check cross-project collisions (informational)
      const alias = result?.alias || result?.alias_text;
      const projectId = result?.project_id;
      let collisions: { project_id: string; project_name: string }[] = [];
      if (alias && projectId) {
        collisions = await findCollisions(db, alias, projectId);
      }
      return {
        ok: true,
        index,
        method: "rpc",
        ...result,
        has_collisions: collisions.length > 0,
        collisions,
      };
    }

    // RPC not available — fall back to direct writes
    console.warn(
      `[alias-review] promote_alias RPC unavailable (${rpcErr.message}), falling back to direct writes`,
    );

    // Read the suggestion
    const { data: suggestion, error: readErr } = await db
      .from("suggested_aliases")
      .select("id, project_id, alias, alias_type, source, confidence")
      .eq("id", suggestionId)
      .eq("status", "pending")
      .single();

    if (readErr || !suggestion) {
      return {
        ok: false,
        index,
        error: "SUGGESTION_NOT_FOUND",
        detail: readErr?.message ||
          `No pending suggestion with id=${suggestionId}`,
      };
    }

    // Check if alias already exists (idempotency — no unique constraint, only partial index)
    const { data: existing } = await db
      .from("project_aliases")
      .select("id")
      .eq("project_id", suggestion.project_id)
      .ilike("alias", suggestion.alias)
      .eq("active", true)
      .limit(1);

    if (existing && existing.length > 0) {
      // Already exists — skip insert, still mark suggestion approved
    } else {
      // INSERT into project_aliases
      const { error: insertErr } = await db
        .from("project_aliases")
        .insert({
          project_id: suggestion.project_id,
          alias: suggestion.alias,
          alias_type: suggestion.alias_type,
          source: "alias-review",
          confidence: suggestion.confidence,
          active: true,
        });

      if (insertErr) {
        return {
          ok: false,
          index,
          error: "INSERT_FAILED",
          detail: insertErr.message,
        };
      }
    }

    // UPDATE suggested_aliases status
    const { error: updateErr } = await db
      .from("suggested_aliases")
      .update({
        status: "approved",
        reviewed_at: new Date().toISOString(),
        reviewed_by: reviewedBy,
      })
      .eq("id", suggestionId);

    if (updateErr) {
      return {
        ok: false,
        index,
        error: "STATUS_UPDATE_FAILED",
        detail: updateErr.message,
      };
    }

    // Check cross-project collisions (informational)
    const collisions = await findCollisions(
      db,
      suggestion.alias,
      suggestion.project_id,
    );

    return {
      ok: true,
      index,
      method: "direct",
      suggestion_id: suggestionId,
      alias: suggestion.alias,
      project_id: suggestion.project_id,
      has_collisions: collisions.length > 0,
      collisions,
    };
  } catch (err) {
    console.error(
      `[alias-review] Unexpected error approving suggestion[${index}]:`,
      err,
    );
    return {
      ok: false,
      index,
      error: "UNEXPECTED_ERROR",
      detail: String(err),
    };
  }
}

// ============================================================
// CORE: Reject one suggestion
// ============================================================

async function rejectOne(
  db: ReturnType<typeof createClient>,
  suggestionId: string,
  reviewedBy: string,
  index: number,
): Promise<Record<string, unknown>> {
  try {
    const { error } = await db
      .from("suggested_aliases")
      .update({
        status: "rejected",
        reviewed_at: new Date().toISOString(),
        reviewed_by: reviewedBy,
      })
      .eq("id", suggestionId)
      .eq("status", "pending");

    if (error) {
      return {
        ok: false,
        index,
        error: "REJECT_FAILED",
        detail: error.message,
      };
    }

    return { ok: true, index, suggestion_id: suggestionId };
  } catch (err) {
    console.error(
      `[alias-review] Unexpected error rejecting suggestion[${index}]:`,
      err,
    );
    return {
      ok: false,
      index,
      error: "UNEXPECTED_ERROR",
      detail: String(err),
    };
  }
}

// ============================================================
// AUTH HELPER
// ============================================================

interface ExtendedAuthResult {
  ok: boolean;
  error_code?: string;
  detail?: string;
  method?: string;
}

function authenticateRequest(req: Request): ExtendedAuthResult {
  // Method 1: X-Edge-Secret (internal agent pattern)
  const edgeSecret = req.headers.get("X-Edge-Secret");
  if (edgeSecret) {
    const result = requireEdgeSecret(req, ALLOWED_SOURCES);
    if (result.ok) {
      return { ok: true, method: "edge_secret", detail: result.source };
    }
    return {
      ok: false,
      error_code: result.error_code,
      detail: `edge_secret: ${result.error_code}`,
    };
  }

  // Method 2: Service role key in Authorization header
  const authHeader = req.headers.get("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.replace("Bearer ", "");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (serviceRoleKey && token === serviceRoleKey) {
      return { ok: true, method: "service_role" };
    }
    return {
      ok: false,
      error_code: "invalid_auth_token",
      detail: "Only service_role key or X-Edge-Secret accepted",
    };
  }

  return {
    ok: false,
    error_code: "missing_edge_secret",
    detail: "Provide X-Edge-Secret header or Authorization: Bearer <service_role_key>",
  };
}

// ============================================================
// HELPERS
// ============================================================

function jsonResponse(
  data: Record<string, unknown>,
  status: number,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, x-source, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    .test(str);
}
