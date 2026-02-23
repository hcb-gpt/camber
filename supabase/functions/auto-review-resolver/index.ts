/**
 * auto-review-resolver Edge Function v1.1.1
 * Inline auto-review resolver (no SQL migration dependency).
 *
 * Behavior:
 * - Auto-resolve review_queue items with confidence >= high threshold
 * - Auto-dismiss review_queue items with confidence < low threshold
 * - Leave middle band for human review
 *
 * Auth:
 * - X-Edge-Secret + source allowlist
 * - OR service role key in Authorization Bearer token
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { emitLineage } from "../_shared/lineage.ts";

const VERSION = "auto-review-resolver_v1.1.1";
const DEFAULT_HIGH_CONF = 0.85;
const DEFAULT_LOW_CONF = 0.20;
const DEFAULT_LIMIT = 500;
const ALLOWED_SOURCES = [
  "agent-teams",
  "auto-review-resolver",
  "cron",
  "claude-chat",
  "test",
];

interface AutoReviewResolverRequest {
  dry_run?: boolean;
  limit?: number;
  high_confidence_threshold?: number;
  low_confidence_threshold?: number;
  actor?: string;
}

interface ExtendedAuthResult {
  ok: boolean;
  error_code?: string;
  detail?: string;
  method?: string;
}

interface ReviewQueueRow {
  id: string;
  span_id: string | null;
  interaction_id: string | null;
  created_at: string;
  context_payload: Record<string, unknown> | null;
}

interface ResolverCandidate {
  review_queue_id: string;
  span_id: string | null;
  interaction_id: string | null;
  created_at: string;
  candidate_project_id: string | null;
  candidate_confidence: number | null;
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "POST_ONLY" }, 405);
  }

  const auth = authenticateRequest(req);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code || "missing_edge_secret", auth.detail);
  }

  let body: AutoReviewResolverRequest = {};
  try {
    const text = await req.text();
    if (text.trim().length > 0) {
      body = JSON.parse(text);
    }
  } catch {
    return jsonResponse({ ok: false, error: "INVALID_JSON" }, 400);
  }

  const dryRun = body.dry_run === true;
  const limit = Number.isInteger(body.limit) ? Number(body.limit) : DEFAULT_LIMIT;
  const high = typeof body.high_confidence_threshold === "number" ? body.high_confidence_threshold : DEFAULT_HIGH_CONF;
  const low = typeof body.low_confidence_threshold === "number" ? body.low_confidence_threshold : DEFAULT_LOW_CONF;
  const actor = (body.actor && body.actor.trim()) || "system:auto_review_resolver_edge";

  if (!Number.isFinite(high) || !Number.isFinite(low) || low < 0 || high > 1 || low >= high) {
    return jsonResponse({
      ok: false,
      error: "INVALID_THRESHOLDS",
      detail: "Require 0 <= low_confidence_threshold < high_confidence_threshold <= 1",
    }, 400);
  }
  if (!Number.isInteger(limit) || limit < 1 || limit > 5000) {
    return jsonResponse({
      ok: false,
      error: "INVALID_LIMIT",
      detail: "limit must be an integer between 1 and 5000",
    }, 400);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: rows, error: fetchError } = await db
    .from("review_queue")
    .select("id, span_id, interaction_id, created_at, context_payload")
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(limit);

  if (fetchError) {
    return jsonResponse({
      ok: false,
      error: "FETCH_FAILED",
      detail: fetchError.message,
      params: { dry_run: dryRun, high, low, limit, actor },
    }, 500);
  }

  const candidates = ((rows ?? []) as ReviewQueueRow[]).map(normalizeCandidate);
  const withConfidenceCount = candidates.filter((c) => c.candidate_confidence !== null).length;
  const missingConfidenceCount = Math.max(candidates.length - withConfidenceCount, 0);
  const highCandidates = candidates.filter((c) =>
    c.candidate_confidence !== null &&
    c.candidate_confidence >= high &&
    c.candidate_confidence <= 1
  );
  const lowCandidates = candidates.filter((c) =>
    c.candidate_confidence !== null &&
    c.candidate_confidence >= 0 &&
    c.candidate_confidence < low
  );
  const middleCandidates = Math.max(
    candidates.length - highCandidates.length - lowCandidates.length,
    0,
  );

  if (dryRun) {
    return jsonResponse({
      ok: true,
      version: VERSION,
      auth_method: auth.method,
      params: { dry_run: dryRun, high, low, limit, actor },
      result: {
        ok: true,
        dry_run: true,
        scanned: candidates.length,
        bands: {
          high_auto_resolve_candidates: highCandidates.length,
          low_auto_dismiss_candidates: lowCandidates.length,
          human_review_candidates: middleCandidates,
        },
        confidence_coverage: {
          with_confidence: withConfidenceCount,
          missing_confidence: missingConfidenceCount,
        },
        sample: {
          high_review_queue_ids: highCandidates.slice(0, 20).map((c) => c.review_queue_id),
          low_review_queue_ids: lowCandidates.slice(0, 20).map((c) => c.review_queue_id),
        },
      },
      ms: Date.now() - t0,
    }, 200);
  }

  let lowDismissed = 0;
  let lowDismissError: string | null = null;
  if (lowCandidates.length > 0) {
    const { data: dismissedRows, error: dismissError } = await db
      .from("review_queue")
      .update({
        status: "dismissed",
        resolved_at: new Date().toISOString(),
        resolved_by: actor,
        resolution_action: "auto_dismiss",
        resolution_notes: "auto_low_confidence",
      })
      .in("id", lowCandidates.map((c) => c.review_queue_id))
      .eq("status", "pending")
      .select("id");

    if (dismissError) {
      lowDismissError = dismissError.message;
    } else {
      lowDismissed = dismissedRows?.length ?? 0;
    }
  }

  const highResult = await resolveHighConfidenceCandidates(db, highCandidates, actor);

  if (lowDismissError && highResult.resolver_errors.length > 0) {
    return jsonResponse({
      ok: false,
      error: "APPLY_FAILED",
      detail: "Both low-dismiss and high-resolve paths had errors",
      params: { dry_run: dryRun, high, low, limit, actor },
      result: {
        scanned: candidates.length,
        bands: {
          high_auto_resolve_candidates: highCandidates.length,
          low_auto_dismiss_candidates: lowCandidates.length,
          human_review_candidates: middleCandidates,
        },
        applied: {
          high_auto_resolved: highResult.high_resolved,
          high_fallback_resolved: highResult.high_fallback_resolved,
          high_already_terminal: highResult.high_already_terminal,
          high_missing_project: highResult.high_missing_project,
          high_resolver_errors: highResult.high_resolver_errors,
          low_auto_dismissed: lowDismissed,
          low_dismiss_error: lowDismissError,
        },
        resolver_errors: highResult.resolver_errors.slice(0, 20),
      },
      ms: Date.now() - t0,
    }, 500);
  }

  // RUNTIME LINEAGE (fire-and-forget via shared helper)
  emitLineage(db, {
    slug: "auto-review-resolver",
    version: VERSION,
    edges: [
      { from: "edge:auto-review-resolver", to: "table:public.review_queue", type: "reads" },
      { from: "edge:auto-review-resolver", to: "table:public.review_queue", type: "writes" },
      { from: "edge:auto-review-resolver", to: "table:public.span_attributions", type: "writes" },
      { from: "edge:auto-review-resolver", to: "table:public.journal_claims", type: "writes" },
    ],
  });

  return jsonResponse({
    ok: true,
    version: VERSION,
    auth_method: auth.method,
    params: { dry_run: dryRun, high, low, limit, actor },
    result: {
      ok: true,
      dry_run: false,
      scanned: candidates.length,
      bands: {
        high_auto_resolve_candidates: highCandidates.length,
        low_auto_dismiss_candidates: lowCandidates.length,
        human_review_candidates: middleCandidates,
      },
      confidence_coverage: {
        with_confidence: withConfidenceCount,
        missing_confidence: missingConfidenceCount,
      },
      applied: {
        high_auto_resolved: highResult.high_resolved,
        high_fallback_resolved: highResult.high_fallback_resolved,
        high_already_terminal: highResult.high_already_terminal,
        high_missing_project: highResult.high_missing_project,
        high_resolver_errors: highResult.high_resolver_errors,
        low_auto_dismissed: lowDismissed,
        low_dismiss_error: lowDismissError,
      },
      resolver_errors: highResult.resolver_errors.slice(0, 20),
    },
    ms: Date.now() - t0,
  }, 200);
});

async function resolveHighConfidenceCandidates(
  db: any,
  candidates: ResolverCandidate[],
  actor: string,
): Promise<{
  high_resolved: number;
  high_fallback_resolved: number;
  high_already_terminal: number;
  high_missing_project: number;
  high_resolver_errors: number;
  resolver_errors: string[];
}> {
  let highResolved = 0;
  let highFallbackResolved = 0;
  let highAlreadyTerminal = 0;
  let highMissingProject = 0;
  let highResolverErrors = 0;
  const resolverErrors: string[] = [];

  for (const candidate of candidates) {
    if (!candidate.candidate_project_id) {
      highMissingProject += 1;
      continue;
    }

    const { data, error } = await (db as any).rpc("resolve_review_item", {
      p_review_queue_id: candidate.review_queue_id,
      p_chosen_project_id: candidate.candidate_project_id,
      p_notes: "auto_high_confidence",
      p_user_id: actor,
    });

    if (error) {
      if (error.message.includes("invalid input syntax for type uuid")) {
        const fallback = await applyHighConfidenceFallback(db, candidate, actor);
        if (fallback.ok) {
          highFallbackResolved += 1;
          continue;
        }
        highResolverErrors += 1;
        resolverErrors.push(`${candidate.review_queue_id}: ${fallback.detail}`);
        continue;
      }
      highResolverErrors += 1;
      resolverErrors.push(`${candidate.review_queue_id}: ${error.message}`);
      continue;
    }

    const result = parseJsonSafe(data);
    if (result.ok === true) {
      if (result.was_already_resolved === true) {
        highAlreadyTerminal += 1;
      } else {
        highResolved += 1;
      }
      continue;
    }

    highResolverErrors += 1;
    resolverErrors.push(
      `${candidate.review_queue_id}: resolve_review_item returned not ok`,
    );
  }

  return {
    high_resolved: highResolved,
    high_fallback_resolved: highFallbackResolved,
    high_already_terminal: highAlreadyTerminal,
    high_missing_project: highMissingProject,
    high_resolver_errors: highResolverErrors,
    resolver_errors: resolverErrors,
  };
}

async function applyHighConfidenceFallback(
  db: any,
  candidate: ResolverCandidate,
  actor: string,
): Promise<{ ok: boolean; detail: string }> {
  if (!candidate.candidate_project_id) {
    return { ok: false, detail: "fallback_failed: missing candidate_project_id" };
  }

  const nowIso = new Date().toISOString();
  let attrRows: Array<{ id: string }> | null = null;
  if (candidate.span_id) {
    const { data, error: attrError } = await db
      .from("span_attributions")
      .update({
        applied_project_id: candidate.candidate_project_id,
        attribution_lock: "human",
        needs_review: false,
        decision: "assign",
        applied_at_utc: nowIso,
      })
      .eq("span_id", candidate.span_id)
      .eq("needs_review", true)
      .select("id");

    if (attrError) {
      return { ok: false, detail: `fallback_failed: span_attributions update error: ${attrError.message}` };
    }
    attrRows = data;
  }

  const { data: queueRows, error: queueError } = await db
    .from("review_queue")
    .update({
      status: "resolved",
      resolved_at: nowIso,
      resolved_by: actor,
      resolution_action: "auto_resolve",
      resolution_notes: candidate.span_id ? "auto_high_confidence_fallback" : "auto_high_confidence_queue_only_no_span",
    })
    .eq("id", candidate.review_queue_id)
    .eq("status", "pending")
    .select("id");

  if (queueError) {
    return { ok: false, detail: `fallback_failed: review_queue update error: ${queueError.message}` };
  }
  if (!queueRows || queueRows.length === 0) {
    return { ok: false, detail: "fallback_failed: no review_queue row updated" };
  }

  if (candidate.span_id && attrRows && attrRows.length > 0) {
    const { error: claimConfirmErr } = await db
      .from("journal_claims")
      .update({
        claim_project_id: candidate.candidate_project_id,
        attribution_decision: "assign",
        claim_confirmation_state: "confirmed",
        confirmed_at: nowIso,
        confirmed_by: "auto_review_resolver",
      })
      .eq("source_span_id", candidate.span_id)
      .eq("active", true);

    if (claimConfirmErr) {
      return { ok: false, detail: `fallback_failed: journal_claims update error: ${claimConfirmErr.message}` };
    }
  }

  return {
    ok: true,
    detail: candidate.span_id ? "fallback_applied" : "fallback_applied_queue_only_no_span",
  };
}

function normalizeCandidate(row: ReviewQueueRow): ResolverCandidate {
  const payload = isRecord(row.context_payload) ? row.context_payload : {};
  const candidateProjectId = coerceUuid(payload["candidate_project_id"]) ??
    coerceUuid(firstCandidateProjectId(payload["candidates"])) ??
    coerceUuid(firstCandidateProjectId(payload["candidate_projects"]));
  const candidateConfidence = coerceNumber(payload["candidate_confidence"]) ??
    coerceNumber(payload["confidence"]);

  return {
    review_queue_id: row.id,
    span_id: row.span_id,
    interaction_id: row.interaction_id,
    created_at: row.created_at,
    candidate_project_id: candidateProjectId,
    candidate_confidence: candidateConfidence,
  };
}

function firstCandidateProjectId(value: unknown): string | null {
  if (!Array.isArray(value) || value.length === 0) return null;
  const first = value[0];
  if (!isRecord(first)) return null;
  if (typeof first["project_id"] === "string") return first["project_id"];
  if (typeof first["id"] === "string") return first["id"];
  return null;
}

function coerceNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!/^[-+]?\d*\.?\d+$/.test(trimmed)) return null;
  const parsed = Number(trimmed);
  return Number.isFinite(parsed) ? parsed : null;
}

function coerceUuid(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return isValidUuid(value) ? value : null;
}

function isValidUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJsonSafe(value: unknown): Record<string, unknown> {
  if (isRecord(value)) return value;
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value);
      return isRecord(parsed) ? parsed : {};
    } catch {
      return {};
    }
  }
  return {};
}

function authenticateRequest(req: Request): ExtendedAuthResult {
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

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authHeader = req.headers.get("Authorization");
  const bearerToken = extractBearerToken(authHeader);
  const apiKeyHeader = req.headers.get("apikey")?.trim() ?? "";

  if (serviceRoleKey) {
    if (bearerToken && bearerToken === serviceRoleKey) {
      return { ok: true, method: "service_role_authorization" };
    }
    if (apiKeyHeader && apiKeyHeader === serviceRoleKey) {
      return { ok: true, method: "service_role_apikey" };
    }
  }

  if (bearerToken || apiKeyHeader) {
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

function extractBearerToken(authHeader: string | null): string {
  if (!authHeader) return "";
  const parts = authHeader.trim().split(/\s+/);
  if (parts.length < 2) return "";
  return parts[0].toLowerCase() === "bearer" ? parts.slice(1).join(" ").trim() : "";
}

function jsonResponse(data: Record<string, unknown>, status: number): Response {
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
