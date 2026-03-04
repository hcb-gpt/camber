export type RepairAuthErrorCode =
  | "missing_auth"
  | "invalid_edge_secret"
  | "invalid_auth_token"
  | "server_misconfigured";

export interface RepairAuthResult {
  ok: boolean;
  status: number;
  error_code?: RepairAuthErrorCode;
  detail?: { missing?: string[]; source?: "x-edge-secret" | "authorization"; token?: string | null };
}

function normalizeBearer(raw: string | null): string {
  if (!raw) return "";
  const trimmed = raw.trim();
  return trimmed.toLowerCase().startsWith("bearer ") ? trimmed.slice(7).trim() : trimmed;
}

function safeStringCompare(lhs: string, rhs: string): boolean {
  const lhsBytes = new TextEncoder().encode(lhs);
  const rhsBytes = new TextEncoder().encode(rhs);
  const maxLen = Math.max(lhsBytes.length, rhsBytes.length);
  let result = lhsBytes.length ^ rhsBytes.length;
  for (let i = 0; i < maxLen; i++) {
    const lhsByte = i < lhsBytes.length ? lhsBytes[i] : 0;
    const rhsByte = i < rhsBytes.length ? rhsBytes[i] : 0;
    result |= lhsByte ^ rhsByte;
  }
  return result === 0;
}

export function checkRepairAuthHeaders(
  req: Request,
  edgeSecret: string,
  serviceRoleToken: string,
): RepairAuthResult {
  const configuredEdge = String(edgeSecret || "").trim();
  const configuredToken = String(serviceRoleToken || "").trim();

  if (!configuredEdge && !configuredToken) {
    return {
      ok: false,
      status: 500,
      error_code: "server_misconfigured",
      detail: { missing: ["EDGE_SHARED_SECRET", "SUPABASE_SERVICE_ROLE_KEY"] },
    };
  }

  const edgeHeader = req.headers.get("X-Edge-Secret")?.trim() || "";
  const authHeader = normalizeBearer(req.headers.get("Authorization")) ||
    normalizeBearer(req.headers.get("apikey")) ||
    normalizeBearer(req.headers.get("X-Api-Key"));

  const edgeMatch = configuredEdge && safeStringCompare(edgeHeader, configuredEdge);
  const serviceMatch = configuredToken && safeStringCompare(authHeader, configuredToken);

  if (edgeMatch || serviceMatch) {
    return {
      ok: true,
      status: 200,
      detail: { source: edgeMatch ? "x-edge-secret" : "authorization" },
    };
  }

  if (edgeHeader) {
    return {
      ok: false,
      status: 403,
      error_code: "invalid_edge_secret",
      detail: { source: "x-edge-secret", token: edgeHeader ? "provided" : null },
    };
  }

  if (authHeader) {
    return {
      ok: false,
      status: 403,
      error_code: "invalid_auth_token",
      detail: { source: "authorization" },
    };
  }

  return {
    ok: false,
    status: 401,
    error_code: "missing_auth",
    detail: { source: "authorization" },
  };
}
