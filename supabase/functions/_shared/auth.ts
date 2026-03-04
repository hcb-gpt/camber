/**
 * Shared Auth Module for Edge Functions
 *
 * @version 1.0.0
 * @date 2026-01-31
 *
 * POLICY (CLAUDE.md):
 * - Internal machine-to-machine calls use verify_jwt=false + X-Edge-Secret + source allowlist
 * - NEVER decode JWT payload (base64/atob) and trust fields without signature verification
 * - User-facing endpoints must use verify_jwt=true or proper supabase.auth.getUser()
 */

export interface AuthResult {
  ok: boolean;
  error_code?: string;
  source?: string;
}

/**
 * Require X-Edge-Secret header matching EDGE_SHARED_SECRET + source in allowlist.
 * Pattern A from CLAUDE.md: internal machine-to-machine auth.
 *
 * @param req - Incoming request
 * @param allowedSources - List of allowed source identifiers (e.g., ['admin-reseed', 'chunk-call'])
 * @returns AuthResult with ok=true if authorized, ok=false with error_code if not
 */
export function requireEdgeSecret(
  req: Request,
  allowedSources: string[],
): AuthResult {
  // 1. Check X-Edge-Secret header
  const edgeSecret = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");

  if (!expectedSecret) {
    console.error("[auth] EDGE_SHARED_SECRET not configured");
    return { ok: false, error_code: "server_misconfigured" };
  }

  if (!edgeSecret) {
    return { ok: false, error_code: "missing_edge_secret" };
  }

  // Constant-time comparison to prevent timing attacks
  if (!constantTimeEqual(edgeSecret, expectedSecret)) {
    return { ok: false, error_code: "invalid_edge_secret" };
  }

  // 2. Check source header is in allowlist
  const source = req.headers.get("X-Source") || req.headers.get("source");

  if (!source) {
    return { ok: false, error_code: "missing_source" };
  }

  if (!allowedSources.includes(source)) {
    console.error(`[auth] Source "${source}" not in allowlist: [${allowedSources.join(", ")}]`);
    return { ok: false, error_code: "source_not_allowed" };
  }

  return { ok: true, source };
}

/**
 * Validate X-Edge-Secret header without source check.
 * Pattern A-lite: for functions that accept both edge-secret and JWT paths.
 * Uses constant-time comparison to prevent timing attacks.
 *
 * @param req - Incoming request
 * @returns true if X-Edge-Secret is present and matches EDGE_SHARED_SECRET
 */
export function validateEdgeSecret(req: Request): boolean {
  const edgeSecret = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  if (!expectedSecret || !edgeSecret) return false;
  return constantTimeEqual(edgeSecret, expectedSecret);
}

/**
 * Constant-time string comparison to prevent timing attacks.
 */
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false;
  }

  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

/**
 * Create a JSON error response with proper status code mapping.
 */
export function authErrorResponse(
  errorCode: string,
  detail?: string,
): Response {
  const statusMap: Record<string, number> = {
    missing_edge_secret: 401,
    invalid_edge_secret: 403,
    missing_source: 401,
    source_not_allowed: 403,
    server_misconfigured: 500,
  };

  const status = statusMap[errorCode] || 400;

  return new Response(
    JSON.stringify({
      ok: false,
      error: errorCode,
      detail: detail || undefined,
    }),
    {
      status,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    },
  );
}
