/**
 * project-query Edge Function v1.0.0
 *
 * Wave-2 project-scoped query interface for consumption surfaces.
 * Read-only aggregation across live project views + optional project-state RPC.
 *
 * Mandatory implementation-note citation:
 * - report__data_consolidation_proof_packet_v1__20260222
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_VERSION = "v1.0.0";
const IMPLEMENTATION_CITATION = "report__data_consolidation_proof_packet_v1__20260222";
const JSON_HEADERS = { "Content-Type": "application/json" };

// Internal callers that are allowed to invoke this endpoint.
const ALLOWED_SOURCES = [
  "dev-cli",
  "ops",
  "codex",
  "strat-query",
  "morning-digest",
  "project-query-test",
];

interface QueryInput {
  project_id?: string;
  limit: number;
  include_system_state: boolean;
  include_belief_snapshot: boolean;
  include_rpc: boolean;
}

interface RpcResult {
  source: string;
  payload: unknown;
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: JSON_HEADERS });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse({ ok: false, error: "GET or POST only" }, 405);
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code || "source_not_allowed");
  }

  let input: QueryInput;
  try {
    input = await parseInput(req);
  } catch (err) {
    return jsonResponse(
      {
        ok: false,
        error: "invalid_request",
        detail: err instanceof Error ? err.message : String(err),
      },
      400,
    );
  }

  if (input.project_id && !isUuid(input.project_id)) {
    return jsonResponse(
      { ok: false, error: "invalid_project_id", detail: "project_id must be UUID" },
      400,
    );
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const warnings: string[] = [];
  let projectFeed: unknown[] = [];
  let projectSystemState: unknown = null;
  let projectBeliefSnapshot: unknown = null;
  let projectStateRpc: RpcResult | null = null;

  const { data: feedData, error: feedError } = await fetchProjectFeed(
    db,
    input.project_id,
    input.limit,
  );
  if (feedError) {
    return jsonResponse(
      {
        ok: false,
        error: "project_feed_query_failed",
        detail: feedError.message,
        citation: IMPLEMENTATION_CITATION,
      },
      500,
    );
  }
  projectFeed = feedData || [];

  if (!input.project_id) {
    if (input.include_system_state || input.include_belief_snapshot || input.include_rpc) {
      warnings.push("project_id missing: project-level snapshots/RPC skipped");
    }
  } else {
    if (input.include_system_state) {
      const { data, warning } = await fetchProjectRowById(db, "v_project_system_state", input.project_id);
      projectSystemState = data;
      if (warning) warnings.push(warning);
    }

    if (input.include_belief_snapshot) {
      const { data, warning } = await fetchProjectRowById(db, "v_project_belief_snapshot", input.project_id);
      projectBeliefSnapshot = data;
      if (warning) warnings.push(warning);
    }

    if (input.include_rpc) {
      const rpc = await fetchProjectStateRpc(db, input.project_id);
      projectStateRpc = rpc.result;
      warnings.push(...rpc.warnings);
    }
  }

  return jsonResponse(
    {
      ok: true,
      generated_at: new Date().toISOString(),
      function_version: FUNCTION_VERSION,
      citation: IMPLEMENTATION_CITATION,
      source: auth.source,
      query: input,
      data: {
        project_feed: projectFeed,
        project_system_state: projectSystemState,
        project_belief_snapshot: projectBeliefSnapshot,
        project_state_rpc: projectStateRpc,
      },
      warnings,
      ms: Date.now() - t0,
    },
    200,
  );
});

function jsonResponse(data: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: JSON_HEADERS,
  });
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

async function parseInput(req: Request): Promise<QueryInput> {
  const defaults: QueryInput = {
    limit: 10,
    include_system_state: true,
    include_belief_snapshot: true,
    include_rpc: true,
  };

  if (req.method === "GET") {
    const url = new URL(req.url);
    const project_id = url.searchParams.get("project_id") || undefined;
    const limit = parseIntSafe(url.searchParams.get("limit"), defaults.limit, 1, 50);
    const include_system_state = parseBool(url.searchParams.get("include_system_state"), true);
    const include_belief_snapshot = parseBool(url.searchParams.get("include_belief_snapshot"), true);
    const include_rpc = parseBool(url.searchParams.get("include_rpc"), true);
    return { project_id, limit, include_system_state, include_belief_snapshot, include_rpc };
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const project_id = asOptionalString(body.project_id);
  const limit = parseIntSafe(body.limit, defaults.limit, 1, 50);
  const include_system_state = parseBool(body.include_system_state, true);
  const include_belief_snapshot = parseBool(body.include_belief_snapshot, true);
  const include_rpc = parseBool(body.include_rpc, true);
  return { project_id, limit, include_system_state, include_belief_snapshot, include_rpc };
}

function asOptionalString(value: unknown): string | undefined {
  if (typeof value === "string" && value.trim().length > 0) return value.trim();
  return undefined;
}

function parseBool(value: unknown, fallback: boolean): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const v = value.trim().toLowerCase();
    if (["1", "true", "yes", "on"].includes(v)) return true;
    if (["0", "false", "no", "off"].includes(v)) return false;
  }
  return fallback;
}

function parseIntSafe(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  const n = typeof value === "number" ? value : typeof value === "string" ? Number.parseInt(value, 10) : Number.NaN;
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

async function fetchProjectFeed(
  db: any,
  projectId: string | undefined,
  limit: number,
): Promise<{ data: unknown[] | null; error: { message: string } | null }> {
  let query = db.from("v_project_feed").select("*");

  if (projectId) {
    query = query.eq("project_id", projectId).limit(1);
  } else {
    query = query.order("active_journal_claims", { ascending: false }).limit(limit);
  }

  const { data, error } = await query;
  return { data: data || [], error: error ? { message: error.message } : null };
}

async function fetchProjectRowById(
  db: any,
  relation: string,
  projectId: string,
): Promise<{ data: unknown; warning?: string }> {
  const attempts = ["project_id", "id"];
  for (const column of attempts) {
    const { data, error } = await db
      .from(relation)
      .select("*")
      .eq(column, projectId)
      .limit(1);
    if (!error) return { data: (data && data.length > 0) ? data[0] : null };
  }
  return { data: null, warning: `${relation} unavailable or missing project key in current schema` };
}

async function fetchProjectStateRpc(
  db: any,
  projectId: string,
): Promise<{ result: RpcResult | null; warnings: string[] }> {
  const warnings: string[] = [];
  const attempts: Array<{ fn: string; args: Record<string, unknown> }> = [
    { fn: "fn_project_system_state", args: { p_project_id: projectId } },
    { fn: "get_project_state_snapshot", args: { p_project_id: projectId } },
    { fn: "get_project_belief_snapshot", args: { p_project_id: projectId } },
  ];

  for (const attempt of attempts) {
    const { data, error } = await db.rpc(attempt.fn, attempt.args);
    if (!error) {
      return {
        result: {
          source: attempt.fn,
          payload: data,
        },
        warnings,
      };
    }
    warnings.push(`rpc ${attempt.fn} unavailable: ${error.message}`);
  }

  return { result: null, warnings };
}
