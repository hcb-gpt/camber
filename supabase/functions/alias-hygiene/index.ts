/**
 * alias-hygiene Edge Function v1.0.0
 * Cleanup job that maintains alias data quality
 *
 * @version 1.0.0
 * @date 2026-02-16
 * @purpose Retire aliases for closed projects, expire stale suggestions, detect collisions
 *
 * Called by: Claude agents, cron, manual trigger
 * Auth: Internal pattern (X-Edge-Secret + source allowlist) OR service_role key
 * verify_jwt = false (config.toml)
 *
 * Three operations:
 * 1. Retire aliases for closed/inactive projects (RPC with fallback)
 * 2. Expire stale pending suggestions (>30 days)
 * 3. Detect cross-project alias collisions
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { emitLineage } from "../_shared/lineage.ts";

// ============================================================
// TYPES
// ============================================================

interface AliasHygieneRequest {
  dry_run?: boolean;
}

interface RetiredReport {
  count: number;
  project_ids: string[];
}

interface ExpiredReport {
  count: number;
}

interface Collision {
  alias: string;
  project_count: number;
  project_ids: string[];
}

interface HygieneReport {
  retired: RetiredReport;
  expired_suggestions: ExpiredReport;
  collisions: Collision[];
}

const VERSION = "alias-hygiene_v1.0.0";
const ALLOWED_SOURCES = [
  "agent-teams",
  "claude-chat",
  "alias-hygiene",
  "cron",
  "test",
];

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

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "POST_ONLY" }, 405);
  }

  // ========================================
  // 1. AUTH — X-Edge-Secret OR service_role key
  // ========================================
  const authResult = authenticateRequest(req);
  if (!authResult.ok) {
    return authErrorResponse(authResult.error_code!, authResult.detail);
  }

  // ========================================
  // 2. PARSE BODY
  // ========================================
  let body: AliasHygieneRequest = {};
  try {
    const text = await req.text();
    if (text.trim().length > 0) {
      body = JSON.parse(text);
    }
  } catch {
    return jsonResponse({ ok: false, error: "INVALID_JSON" }, 400);
  }

  const dryRun = body.dry_run === true;

  // ========================================
  // 3. INIT DB CLIENT (service_role)
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ========================================
  // 4. OPERATION 1: Retire aliases for closed projects
  // ========================================
  const retired = await retireClosedProjectAliases(db, dryRun);

  // ========================================
  // 5. OPERATION 2: Expire stale pending suggestions
  // ========================================
  const expiredSuggestions = await expireStaleSuggestions(db, dryRun);

  // ========================================
  // 6. OPERATION 3: Detect cross-project alias collisions
  // ========================================
  const collisions = await detectCollisions(db);

  // ========================================
  // 7. RESPONSE
  // ========================================
  const elapsed = Date.now() - t0;
  const report: HygieneReport = {
    retired,
    expired_suggestions: expiredSuggestions,
    collisions,
  };

  console.log(
    `[alias-hygiene] dry_run=${dryRun} retired=${retired.count} expired=${expiredSuggestions.count} collisions=${collisions.length} ms=${elapsed}`,
  );

  // RUNTIME LINEAGE (fire-and-forget via shared helper)
  emitLineage(db, {
    slug: "alias-hygiene",
    version: VERSION,
    edges: [
      { from: "edge:alias-hygiene", to: "table:public.project_aliases", type: "reads" },
      { from: "edge:alias-hygiene", to: "table:public.projects", type: "reads" },
      { from: "edge:alias-hygiene", to: "view:public.v_project_alias_lookup", type: "reads" },
      { from: "edge:alias-hygiene", to: "table:public.project_aliases", type: "writes" },
      { from: "edge:alias-hygiene", to: "table:public.suggested_aliases", type: "writes" },
    ],
    metadata: { dry_run: dryRun },
  });

  return jsonResponse({
    ok: true,
    version: VERSION,
    dry_run: dryRun,
    report,
    ms: elapsed,
  }, 200);
});

// ============================================================
// OPERATION 1: Retire aliases for closed projects
// ============================================================

async function retireClosedProjectAliases(
  db: ReturnType<typeof createClient>,
  dryRun: boolean,
): Promise<RetiredReport> {
  if (dryRun) {
    // Preview: find aliases that would be retired
    const { data, error } = await db
      .from("project_aliases")
      .select("project_id, projects!inner(id, status)")
      .eq("active", true)
      .in("projects.status", ["closed", "inactive"]);

    if (error) {
      console.error(
        `[alias-hygiene] dry_run retire query failed: ${error.message}`,
      );
      return { count: 0, project_ids: [] };
    }

    const projectIds = [
      ...new Set((data || []).map((r: Record<string, unknown>) => r.project_id as string)),
    ];
    return { count: (data || []).length, project_ids: projectIds };
  }

  // Try RPC first
  const { data: rpcData, error: rpcError } = await db.rpc(
    "retire_aliases_for_closed_projects",
  );

  if (!rpcError && rpcData !== null) {
    // RPC succeeded — parse result
    const result = typeof rpcData === "string" ? JSON.parse(rpcData) : rpcData;
    if (Array.isArray(result)) {
      const projectIds = [
        ...new Set(result.map((r: Record<string, unknown>) => r.project_id as string)),
      ];
      return { count: result.length, project_ids: projectIds };
    }
    return {
      count: typeof result?.count === "number" ? result.count : 0,
      project_ids: result?.project_ids || [],
    };
  }

  // Fallback: direct query
  console.warn(
    `[alias-hygiene] RPC retire_aliases_for_closed_projects unavailable (${rpcError?.message}), using fallback`,
  );

  // First, find which aliases will be retired (for reporting)
  const { data: preview } = await db
    .from("project_aliases")
    .select("project_id, projects!inner(id, status)")
    .eq("active", true)
    .in("projects.status", ["closed", "inactive"]);

  const projectIds = [
    ...new Set((preview || []).map((r: Record<string, unknown>) => r.project_id as string)),
  ];

  // Execute the update via raw SQL since supabase-js doesn't support UPDATE...FROM joins
  const { data: updateData, error: updateError } = await db.rpc(
    "execute_sql",
    {
      query: `
      UPDATE project_aliases SET active = false
      FROM projects
      WHERE project_aliases.project_id = projects.id
        AND projects.status IN ('closed', 'inactive')
        AND project_aliases.active = true
      RETURNING project_aliases.project_id
    `,
    },
  );

  if (updateError) {
    // Last resort: try updating each project individually
    console.error(
      `[alias-hygiene] fallback SQL failed: ${updateError.message}`,
    );
    let count = 0;
    for (const pid of projectIds) {
      const { error: perProjectErr } = await db
        .from("project_aliases")
        .update({ active: false })
        .eq("project_id", pid)
        .eq("active", true);
      if (!perProjectErr) count++;
    }
    return { count, project_ids: projectIds };
  }

  const updatedCount = Array.isArray(updateData) ? updateData.length : 0;
  return { count: updatedCount || (preview || []).length, project_ids: projectIds };
}

// ============================================================
// OPERATION 2: Expire stale pending suggestions
// ============================================================

async function expireStaleSuggestions(
  db: ReturnType<typeof createClient>,
  dryRun: boolean,
): Promise<ExpiredReport> {
  const thirtyDaysAgo = new Date(
    Date.now() - 30 * 24 * 60 * 60 * 1000,
  ).toISOString();

  if (dryRun) {
    const { count, error } = await db
      .from("suggested_aliases")
      .select("*", { count: "exact", head: true })
      .eq("status", "pending")
      .lt("suggested_at", thirtyDaysAgo);

    if (error) {
      console.error(
        `[alias-hygiene] dry_run expire query failed: ${error.message}`,
      );
      return { count: 0 };
    }
    return { count: count || 0 };
  }

  const { data, error } = await db
    .from("suggested_aliases")
    .update({
      status: "rejected",
      reviewed_by: "alias-hygiene",
      reviewed_at: new Date().toISOString(),
    })
    .eq("status", "pending")
    .lt("suggested_at", thirtyDaysAgo)
    .select("id");

  if (error) {
    console.error(
      `[alias-hygiene] expire suggestions failed: ${error.message}`,
    );
    return { count: 0 };
  }

  return { count: (data || []).length };
}

// ============================================================
// OPERATION 3: Detect cross-project alias collisions
// ============================================================

async function detectCollisions(
  db: ReturnType<typeof createClient>,
): Promise<Collision[]> {
  const { data, error } = await db.rpc("execute_sql", {
    query: `
      SELECT lower(alias) as alias_lower, count(DISTINCT project_id) as project_count,
        array_agg(DISTINCT project_id) as project_ids
      FROM v_project_alias_lookup
      GROUP BY lower(alias)
      HAVING count(DISTINCT project_id) > 1
      ORDER BY count(DISTINCT project_id) DESC
    `,
  });

  if (error) {
    // Fallback: query the view directly via supabase-js
    console.warn(
      `[alias-hygiene] collision SQL via RPC failed (${error.message}), trying direct view query`,
    );
    return await detectCollisionsFallback(db);
  }

  if (!data || !Array.isArray(data)) {
    return [];
  }

  return data.map((row: Record<string, unknown>) => ({
    alias: row.alias_lower as string,
    project_count: Number(row.project_count),
    project_ids: Array.isArray(row.project_ids) ? row.project_ids as string[] : [],
  }));
}

async function detectCollisionsFallback(
  db: ReturnType<typeof createClient>,
): Promise<Collision[]> {
  const { data, error } = await db
    .from("v_project_alias_lookup")
    .select("alias, project_id");

  if (error) {
    console.error(
      `[alias-hygiene] collision fallback query failed: ${error.message}`,
    );
    return [];
  }

  // Group by lowercase alias and find duplicates
  const groups = new Map<string, Set<string>>();
  for (const row of data || []) {
    const key = (row.alias as string).toLowerCase();
    if (!groups.has(key)) groups.set(key, new Set());
    groups.get(key)!.add(row.project_id as string);
  }

  const collisions: Collision[] = [];
  for (const [alias, projectIds] of groups) {
    if (projectIds.size > 1) {
      collisions.push({
        alias,
        project_count: projectIds.size,
        project_ids: [...projectIds],
      });
    }
  }

  return collisions.sort((a, b) => b.project_count - a.project_count);
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
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}
