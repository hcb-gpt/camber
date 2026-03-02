export type TopLevelGateResult =
  | { ok: true; status: 200; auth: "edge_secret" | "bearer" }
  | {
    ok: false;
    status: 401 | 403 | 500;
    error_code: "missing_auth" | "invalid_auth" | "server_misconfigured";
    error: string;
  };

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

function getBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
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
const BEARER_CACHE_MAX_ENTRIES = 64;

function cacheSet(token: string, ok: boolean): void {
  if (bearerValidationCache.size >= BEARER_CACHE_MAX_ENTRIES) {
    const first = bearerValidationCache.keys().next().value;
    if (first) bearerValidationCache.delete(first);
  }
  bearerValidationCache.set(token, { ok, expiresAtMs: Date.now() + BEARER_CACHE_TTL_MS });
}

async function validateSupabaseAnonKeyViaRest(
  supabaseUrl: string,
  token: string,
): Promise<boolean> {
  const cached = bearerValidationCache.get(token);
  if (cached && cached.expiresAtMs > Date.now()) return cached.ok;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1500);

  try {
    const url = `${supabaseUrl.replace(/\/$/, "")}/rest/v1/`;
    const resp = await fetch(url, {
      method: "GET",
      headers: {
        apikey: token,
        Authorization: `Bearer ${token}`,
      },
      signal: controller.signal,
    });
    const ok = resp.ok;
    cacheSet(token, ok);
    return ok;
  } catch {
    cacheSet(token, false);
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

export function checkTopLevelEdgeSecret(
  req: Request,
  expectedEdgeSecret = Deno.env.get("EDGE_SHARED_SECRET"),
): TopLevelGateResult {
  if (!expectedEdgeSecret) {
    return {
      ok: false,
      status: 500,
      error_code: "server_misconfigured",
      error: "EDGE_SHARED_SECRET not set",
    };
  }

  const providedSecret = req.headers.get("X-Edge-Secret");
  if (!providedSecret) {
    return {
      ok: false,
      status: 401,
      error_code: "missing_auth",
      error: "Valid X-Edge-Secret required",
    };
  }

  if (!constantTimeEqual(providedSecret, expectedEdgeSecret)) {
    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth",
      error: "Valid X-Edge-Secret required",
    };
  }

  return { ok: true, status: 200, auth: "edge_secret" };
}

export async function checkTopLevelEdgeSecretOrAnonKey(
  req: Request,
  expectedEdgeSecret = Deno.env.get("EDGE_SHARED_SECRET"),
  expectedAnonKey = Deno.env.get("SUPABASE_ANON_KEY"),
  supabaseUrl = Deno.env.get("SUPABASE_URL"),
): Promise<TopLevelGateResult> {
  const providedSecret = req.headers.get("X-Edge-Secret");
  if (expectedEdgeSecret && providedSecret && constantTimeEqual(providedSecret, expectedEdgeSecret)) {
    return { ok: true, status: 200, auth: "edge_secret" };
  }

  const bearerToken = getBearerToken(req);
  const apiKey = req.headers.get("apikey");
  const providedBearer = bearerToken || apiKey;

  if (!providedBearer) {
    return {
      ok: false,
      status: 401,
      error_code: "missing_auth",
      error: "X-Edge-Secret or Authorization: Bearer <token> required",
    };
  }

  // Fast path when env is correct (and for unit tests).
  if (expectedAnonKey && constantTimeEqual(providedBearer, expectedAnonKey)) {
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

  const payload = parseJwtPayload(providedBearer);
  const role = String(payload?.role || "").trim();
  const ref = String(payload?.ref || "").trim();

  if (role !== "anon") {
    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth",
      error: "Valid X-Edge-Secret or Supabase anon key required",
    };
  }

  // Defensive check: ensure the token claims match this Supabase project ref.
  // NOTE: signature is implicitly verified by the `/rest/v1/` probe below.
  try {
    const hostRef = new URL(supabaseUrl).host.split(".")[0] || "";
    if (ref && hostRef && ref !== hostRef) {
      return {
        ok: false,
        status: 403,
        error_code: "invalid_auth",
        error: "Valid X-Edge-Secret or Supabase anon key required",
      };
    }
  } catch {
    // If SUPABASE_URL is malformed, treat as misconfigured.
    return {
      ok: false,
      status: 500,
      error_code: "server_misconfigured",
      error: "SUPABASE_URL invalid",
    };
  }

  const restOk = await validateSupabaseAnonKeyViaRest(supabaseUrl, providedBearer);
  if (!restOk) {
    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth",
      error: "Valid X-Edge-Secret or Supabase anon key required",
    };
  }

  return { ok: true, status: 200, auth: "bearer" };
}

export function runTopLevelEdgeSecretProbe(
  req: Request,
  expectedEdgeSecret?: string,
  functionVersion?: string,
): Response {
  const result = checkTopLevelEdgeSecret(req, expectedEdgeSecret);
  return new Response(
    JSON.stringify({ ...result, function_version: functionVersion }),
    {
      status: result.status,
      headers: { "Content-Type": "application/json" },
    },
  );
}

export async function runTopLevelEdgeSecretOrAnonKeyProbe(
  req: Request,
  expectedEdgeSecret?: string,
  expectedAnonKey?: string,
  supabaseUrl?: string,
  functionVersion?: string,
): Promise<Response> {
  const result = await checkTopLevelEdgeSecretOrAnonKey(req, expectedEdgeSecret, expectedAnonKey, supabaseUrl);
  return new Response(
    JSON.stringify({ ...result, function_version: functionVersion }),
    {
      status: result.status,
      headers: { "Content-Type": "application/json" },
    },
  );
}
