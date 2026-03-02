export type TopLevelGateResult =
  | { ok: true; status: 200 }
  | {
    ok: false;
    status: 401 | 500;
    error_code: "missing_auth" | "server_misconfigured";
    error: string;
  };

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
  if (!providedSecret || providedSecret !== expectedEdgeSecret) {
    return {
      ok: false,
      status: 401,
      error_code: "missing_auth",
      error: "Valid X-Edge-Secret required",
    };
  }

  return { ok: true, status: 200 };
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
