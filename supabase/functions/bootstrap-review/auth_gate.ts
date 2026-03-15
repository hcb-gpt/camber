// auth_gate.ts - Shared authentication logic for bootstrap-review (auth-gated)

export type TopLevelGateResult =
  | { ok: true; status: 200; auth: "edge_secret" | "bearer" }
  | {
    ok: false;
    status: 401 | 403 | 500;
    error_code: "missing_auth" | "invalid_auth" | "server_misconfigured";
    error: string;
  };

/**
 * Validates X-Edge-Secret OR Authorization: Bearer <anonKey>
 * Following Pattern C: Dual Auth.
 */
export async function checkTopLevelEdgeSecretOrAnonKey(
  req: Request,
): Promise<TopLevelGateResult> {
  const expectedEdgeSecret = Deno.env.get("EDGE_SHARED_SECRET");
  const expectedAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");

  const providedEdgeSecret = req.headers.get("X-Edge-Secret");
  const bearerToken = getBearerToken(req);
  const apiKey = req.headers.get("apikey");

  const providedBearerCandidates = [bearerToken, apiKey]
    .map((value) => value?.trim())
    .filter((value): value is string => Boolean(value));

  // 1. Check Edge Secret first (Pattern A)
  if (expectedEdgeSecret && providedEdgeSecret && constantTimeEqual(providedEdgeSecret, expectedEdgeSecret)) {
    return { ok: true, status: 200, auth: "edge_secret" };
  }

  // 2. Check Bearer Token (Pattern B/C)
  if (providedBearerCandidates.length > 0) {
    // Fast path when env is correct (and for unit tests).
    if (expectedAnonKey && providedBearerCandidates.some((token) => constantTimeEqual(token, expectedAnonKey))) {
      return { ok: true, status: 200, auth: "bearer" };
    }

    if (!supabaseUrl) {
      return {
        ok: false,
        status: 500,
        error_code: "server_misconfigured",
        error: "SUPABASE_URL not set",
      };
    }

    let hostRef = "";
    try {
      hostRef = new URL(supabaseUrl).host.split(".")[0] || "";
    } catch {
      return {
        ok: false,
        status: 500,
        error_code: "server_misconfigured",
        error: "SUPABASE_URL invalid",
      };
    }

    // Try bearer token first, then apikey fallback. This avoids false negatives when one header
    // is malformed but the other is valid (clients commonly send both).
    for (const providedBearer of providedBearerCandidates) {
      // Defensive: ensure token looks like a Supabase anon key.
      const payload = parseJwtPayload(providedBearer);
      const role = String(payload?.role || "").trim();
      if (role !== "anon") continue;

      // Defensive: ensure the token claims match this Supabase project ref.
      // NOTE: signature is implicitly verified by the `/rest/v1/` probe below.
      const ref = String(payload?.ref || "").trim();
      if (ref && hostRef && ref !== hostRef) continue;

      const isValid = await validateSupabaseAnonKeyViaRest(supabaseUrl, providedBearer);
      if (isValid) return { ok: true, status: 200, auth: "bearer" };
    }

    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth",
      error: "Valid X-Edge-Secret or Supabase anon key required",
    };
  }

  return {
    ok: false,
    status: 401,
    error_code: "missing_auth",
    error: "X-Edge-Secret or Authorization Bearer required",
  };
}

function getBearerToken(req: Request): string | null {
  const auth = req.headers.get("Authorization");
  if (!auth) return null;
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

function base64UrlDecodeToString(b64url: string): string {
  const padded = b64url + "=".repeat((4 - (b64url.length % 4)) % 4);
  const b64 = padded.replace(/-/g, "+").replace(/_/g, "/");
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function parseJwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const payloadJson = base64UrlDecodeToString(parts[1]);
    const payload = JSON.parse(payloadJson);
    if (!payload || typeof payload !== "object") return null;
    return payload as Record<string, unknown>;
  } catch {
    return null;
  }
}

type CacheEntry = { ok: boolean; expiresAtMs: number };
const bearerValidationCache = new Map<string, CacheEntry>();
const BEARER_CACHE_TTL_MS = 5 * 60 * 1000;
const BEARER_CACHE_ERROR_TTL_MS = 2 * 1000;
const BEARER_CACHE_MAX_ENTRIES = 64;

function cacheSet(token: string, ok: boolean, ttlMs: number = BEARER_CACHE_TTL_MS): void {
  if (bearerValidationCache.size >= BEARER_CACHE_MAX_ENTRIES) {
    const first = bearerValidationCache.keys().next().value;
    if (first) bearerValidationCache.delete(first);
  }
  bearerValidationCache.set(token, { ok, expiresAtMs: Date.now() + ttlMs });
}

async function validateSupabaseAnonKeyViaRest(
  supabaseUrl: string,
  token: string,
): Promise<boolean> {
  const cached = bearerValidationCache.get(token);
  if (cached && cached.expiresAtMs > Date.now()) return cached.ok;

  const url = `${supabaseUrl.replace(/\/$/, "")}/rest/v1/`;

  const attempts = 3;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2500);

    try {
      const resp = await fetch(url, {
        method: "GET",
        headers: {
          apikey: token,
          Authorization: `Bearer ${token}`,
        },
        signal: controller.signal,
      });

      if (resp.ok) {
        cacheSet(token, true);
        return true;
      }

      // Treat 5xx as transient (edge incident / upstream flake), not an auth failure.
      if (resp.status >= 500 && attempt < attempts) {
        await new Promise((resolve) => setTimeout(resolve, 150 * attempt));
        continue;
      }

      const ok = resp.ok;
      cacheSet(token, ok);
      return ok;
    } catch (error) {
      // Network/timeout errors are often transient; retry a couple times and avoid caching a
      // long-lived "invalid" result on failures that aren't actually auth-related.
      const isLastAttempt = attempt >= attempts;
      if (!isLastAttempt) {
        await new Promise((resolve) => setTimeout(resolve, 150 * attempt));
        continue;
      }

      console.warn(
        `[bootstrap-review:auth_gate] rest probe failed after ${attempts} attempts: ${
          (error as Error)?.message || String(error)
        }`,
      );
      cacheSet(token, false, BEARER_CACHE_ERROR_TTL_MS);
      return false;
    } finally {
      clearTimeout(timeout);
    }
  }

  cacheSet(token, false, BEARER_CACHE_ERROR_TTL_MS);
  return false;
}
