/**
 * gt-apply Edge Function v1.0.0
 * Batch ground-truth correction endpoint for agent-driven GT review
 *
 * @version 1.0.0
 * @date 2026-02-15
 * @purpose Apply human GT corrections to span_attributions via apply_gt_correction RPC
 *
 * Called by: Claude agents (Agent Teams) on behalf of CHAD
 * Auth: Internal pattern (X-Edge-Secret + source allowlist) OR service_role key
 * verify_jwt = false (config.toml)
 *
 * Write path (per correction):
 *   span_attributions: applied_project_id, attribution_lock='human', needs_review=false
 *   override_log: audit row with idempotency_key
 *
 * Hard rules:
 * - Never downgrade human lock (RPC enforces via monotonic trigger)
 * - Fail closed: any RPC failure returns error for that correction, not silent 200
 * - Batch limit: 100 corrections per request
 * - Stopline 2: human > AI > null (monotonic), enforced by DB trigger
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

// ============================================================
// TYPES
// ============================================================

interface Correction {
  /** UUID of the span — OR provide interaction_id + span_index */
  span_id?: string;
  /** Interaction ID for span lookup (used with span_index) */
  interaction_id?: string;
  /** Span index within interaction (used with interaction_id) */
  span_index?: number;
  /** UUID of the project — OR provide project_name */
  project_id?: string;
  /** Project name for ILIKE lookup */
  project_name?: string;
  /** Who is applying the correction (default: CHAD) */
  corrected_by?: string;
  /** Optional notes */
  notes?: string;
}

interface GtApplyRequest {
  corrections: Correction[];
  /** Optional batch ID for audit grouping */
  batch_id?: string;
}

const MAX_BATCH = 100;
const VERSION = "gt-apply_v1.0.0";
const ALLOWED_SOURCES = ["agent-teams", "claude-chat", "gt-apply", "test"];

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
  // 2. PARSE + VALIDATE BODY
  // ========================================
  let body: GtApplyRequest;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ ok: false, error: "INVALID_JSON" }, 400);
  }

  if (!body.corrections || !Array.isArray(body.corrections)) {
    return jsonResponse({
      ok: false,
      error: "MISSING_CORRECTIONS",
      detail: "Request must include a corrections array",
    }, 400);
  }

  if (body.corrections.length === 0) {
    return jsonResponse({
      ok: false,
      error: "EMPTY_CORRECTIONS",
      detail: "Corrections array must not be empty",
    }, 400);
  }

  if (body.corrections.length > MAX_BATCH) {
    return jsonResponse({
      ok: false,
      error: "BATCH_TOO_LARGE",
      detail: `Max ${MAX_BATCH} corrections per request, got ${body.corrections.length}`,
    }, 400);
  }

  // Validate each correction has enough identifiers
  for (let i = 0; i < body.corrections.length; i++) {
    const c = body.corrections[i];
    const hasSpanId = c.span_id && isValidUUID(c.span_id);
    const hasLookup = c.interaction_id && typeof c.span_index === "number";
    if (!hasSpanId && !hasLookup) {
      return jsonResponse({
        ok: false,
        error: "INVALID_SPAN_IDENTIFIER",
        detail: `Correction[${i}]: provide span_id (UUID) or interaction_id + span_index`,
      }, 400);
    }
    const hasProjectId = c.project_id && isValidUUID(c.project_id);
    const hasProjectName = c.project_name && c.project_name.trim().length > 0;
    if (!hasProjectId && !hasProjectName) {
      return jsonResponse({
        ok: false,
        error: "INVALID_PROJECT_IDENTIFIER",
        detail: `Correction[${i}]: provide project_id (UUID) or project_name`,
      }, 400);
    }
  }

  // ========================================
  // 3. INIT DB CLIENT (service_role)
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const batchId = body.batch_id ||
    `gt_batch_${Date.now()}_${crypto.randomUUID().slice(0, 8)}`;

  // ========================================
  // 4. RESOLVE + APPLY EACH CORRECTION
  // ========================================
  const results: Record<string, unknown>[] = [];
  let successCount = 0;
  let errorCount = 0;

  for (let i = 0; i < body.corrections.length; i++) {
    const c = body.corrections[i];
    const correctionResult = await applyOneCorrection(db, c, batchId, i);
    results.push(correctionResult);
    if (correctionResult.ok) {
      successCount++;
    } else {
      errorCount++;
    }
  }

  // ========================================
  // 5. RESPONSE
  // ========================================
  const elapsed = Date.now() - t0;
  console.log(
    `[gt-apply] batch=${batchId} total=${body.corrections.length} ok=${successCount} err=${errorCount} ms=${elapsed}`,
  );

  // RUNTIME LINEAGE (fire-and-forget)
  try {
    const lineageEdges: { from: string; to: string; type: string }[] = [
      { from: "edge:gt-apply", to: "table:public.conversation_spans", type: "reads" },
      { from: "edge:gt-apply", to: "table:public.projects", type: "reads" },
      { from: "edge:gt-apply", to: "table:public.span_attributions", type: "writes" },
      { from: "edge:gt-apply", to: "table:public.override_log", type: "writes" },
    ];
    const { error: lineageErr } = await db.from("evidence_events").upsert({
      source_type: "lineage",
      source_id: batchId,
      source_run_id: "gt-apply:" + VERSION,
      transcript_variant: "baseline",
      metadata: { edges: lineageEdges, pipeline_version: VERSION },
    }, { onConflict: "source_type,source_id,transcript_variant" });
    if (lineageErr) console.warn(`lineage_emit: ${lineageErr.message}`);
  } catch { /* lineage must never block */ }

  return jsonResponse({
    ok: errorCount === 0,
    version: VERSION,
    batch_id: batchId,
    total: body.corrections.length,
    success_count: successCount,
    error_count: errorCount,
    results,
    ms: elapsed,
  }, errorCount === 0 ? 200 : 207);
});

// ============================================================
// CORE: Apply one correction
// ============================================================

async function applyOneCorrection(
  db: ReturnType<typeof createClient>,
  c: Correction,
  batchId: string,
  index: number,
): Promise<Record<string, unknown>> {
  try {
    // Step 1: Resolve span_id
    let spanId = c.span_id;
    if (!spanId || !isValidUUID(spanId)) {
      const { data: spanRow, error: spanErr } = await db
        .from("conversation_spans")
        .select("id")
        .eq("interaction_id", c.interaction_id!)
        .eq("span_index", c.span_index!)
        .eq("is_superseded", false)
        .single();

      if (spanErr || !spanRow) {
        return {
          ok: false,
          index,
          error: "SPAN_NOT_FOUND",
          detail: `No active span for interaction_id=${c.interaction_id} span_index=${c.span_index}`,
        };
      }
      spanId = spanRow.id;
    }

    // Step 2: Resolve project_id
    let projectId = c.project_id;
    if (!projectId || !isValidUUID(projectId)) {
      const { data: projRow, error: projErr } = await db
        .from("projects")
        .select("id, project_name")
        .ilike("project_name", c.project_name!.trim())
        .limit(1)
        .single();

      if (projErr || !projRow) {
        return {
          ok: false,
          index,
          error: "PROJECT_NOT_FOUND",
          detail: `No project matching name "${c.project_name}"`,
        };
      }
      projectId = projRow.id;
    }

    // Step 3: Call RPC
    const { data, error } = await db.rpc("apply_gt_correction", {
      p_span_id: spanId,
      p_project_id: projectId,
      p_corrected_by: c.corrected_by || "CHAD",
      p_notes: c.notes || null,
      p_batch_id: batchId,
    });

    if (error) {
      console.error(
        `[gt-apply] RPC failed for correction[${index}]: ${error.message}`,
      );
      return {
        ok: false,
        index,
        error: "RPC_FAILED",
        detail: error.message,
      };
    }

    const result = typeof data === "string" ? JSON.parse(data) : data;
    return { ...result, index };
  } catch (err) {
    console.error(
      `[gt-apply] Unexpected error for correction[${index}]:`,
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
    // Not a service role key — reject (no JWT auth on this endpoint)
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

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    .test(str);
}
