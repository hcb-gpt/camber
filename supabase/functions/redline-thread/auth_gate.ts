export type TopLevelGateResult =
  | { ok: true; status: 200; auth: "edge_secret" | "anon_key" }
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

export function checkTopLevelEdgeSecretOrAnonKey(
  req: Request,
  expectedEdgeSecret = Deno.env.get("EDGE_SHARED_SECRET"),
  expectedAnonKey = Deno.env.get("SUPABASE_ANON_KEY"),
): TopLevelGateResult {
  const providedSecret = req.headers.get("X-Edge-Secret");
  if (expectedEdgeSecret && providedSecret && constantTimeEqual(providedSecret, expectedEdgeSecret)) {
    return { ok: true, status: 200, auth: "edge_secret" };
  }

  const bearerToken = getBearerToken(req);
  const apiKey = req.headers.get("apikey");
  const providedAnonKey = bearerToken || apiKey;

  if (!expectedAnonKey && !expectedEdgeSecret) {
    return {
      ok: false,
      status: 500,
      error_code: "server_misconfigured",
      error: "EDGE_SHARED_SECRET and SUPABASE_ANON_KEY not set",
    };
  }

  if (!providedAnonKey) {
    return {
      ok: false,
      status: 401,
      error_code: "missing_auth",
      error: "X-Edge-Secret or Authorization: Bearer <token> required",
    };
  }

  if (!expectedAnonKey) {
    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth",
      error: "SUPABASE_ANON_KEY not configured",
    };
  }

  if (!constantTimeEqual(providedAnonKey, expectedAnonKey)) {
    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth",
      error: "Invalid Authorization token",
    };
  }

  return { ok: true, status: 200, auth: "anon_key" };
}

export function runTopLevelEdgeSecretProbe(
  req: Request,
  expectedEdgeSecret?: string,
): Response {
  const result = checkTopLevelEdgeSecret(req, expectedEdgeSecret);
  return new Response(JSON.stringify(result), {
    status: result.status,
    headers: { "Content-Type": "application/json" },
  });
}

export function runTopLevelEdgeSecretOrAnonKeyProbe(
  req: Request,
  expectedEdgeSecret?: string,
  expectedAnonKey?: string,
): Response {
  const result = checkTopLevelEdgeSecretOrAnonKey(req, expectedEdgeSecret, expectedAnonKey);
  return new Response(JSON.stringify(result), {
    status: result.status,
    headers: { "Content-Type": "application/json" },
  });
}
