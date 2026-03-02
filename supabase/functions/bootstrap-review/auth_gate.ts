// auth_gate.ts - Shared authentication logic for bootstrap-review
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
  const projectRef = Deno.env.get("SUPABASE_PROJECT_REF") || "rjhdwidddtfetbwqolof";

  const providedEdgeSecret = req.headers.get("x-edge-secret");
  const bearerToken = getBearerToken(req);
  const apiKey = req.headers.get("apikey");
  const providedBearer = bearerToken || apiKey;

  // 1. Check Edge Secret first (Pattern A)
  if (expectedEdgeSecret && providedEdgeSecret === expectedEdgeSecret) {
    return { ok: true, status: 200, auth: "edge_secret" };
  }

  // 2. Check Bearer Token (Pattern B/C)
  if (providedBearer) {
    // Implicit validation via project ref check + REST probe
    const isValid = await validateBearerViaRestProbe(providedBearer, projectRef);
    if (isValid) {
      return { ok: true, status: 200, auth: "bearer" };
    }
    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth",
      error: "Invalid project anon key",
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

/**
 * Validates a Bearer token by probing the project's own REST API.
 * This handles key drift automatically.
 */
async function validateBearerViaRestProbe(
  token: string,
  projectRef: string,
): Promise<boolean> {
  // Check if it's even a JWT
  if (!token.includes(".")) return false;

  try {
    const url = `https://${projectRef}.supabase.co/rest/v1/`;
    const resp = await fetch(url, {
      method: "GET",
      headers: {
        "apikey": token,
        "Authorization": `Bearer ${token}`,
      },
    });
    // Any non-401/403 means the token was accepted by the gateway
    return resp.status !== 401 && resp.status !== 403;
  } catch (err) {
    console.error("[auth_gate] REST probe failed:", err.message);
    return false;
  }
}
