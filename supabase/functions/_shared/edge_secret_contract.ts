export type EdgeSecretErrorCode =
  | "invalid_edge_secret"
  | "edge_secret_missing"
  | "edge_secret_drift";

export type EdgeSecretContractStatus = "healthy" | "missing" | "drift";

export interface EdgeSecretContract {
  status: EdgeSecretContractStatus;
  current_secret_set: boolean;
  next_secret_set: boolean;
  next_expires_at_utc: string | null;
  next_window_active: boolean;
  next_window_seconds_remaining: number;
  legacy_secret_envs_set: {
    ZAPIER_INGEST_SECRET: boolean;
    ZAPIER_SECRET: boolean;
  };
  drift_reasons: string[];
}

export type EdgeSecretAuthResult =
  | {
    ok: true;
    status: 200;
    matched_slot: "current" | "next";
    contract: EdgeSecretContract;
    current_secret: string;
  }
  | {
    ok: false;
    status: 401 | 403 | 500;
    error_code: EdgeSecretErrorCode;
    error: string;
    contract: EdgeSecretContract;
    current_secret: string;
  };

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

function parseIsoDateMs(value: string | undefined): number | null {
  const trimmed = String(value || "").trim();
  if (!trimmed) return null;
  const ms = Date.parse(trimmed);
  return Number.isFinite(ms) ? ms : null;
}

export interface ResolvedEdgeSecretContractEnv {
  currentSecret: string;
  currentSecretSource: "EDGE_SHARED_SECRET" | "X_EDGE_SECRET" | null;
  currentAliasMismatch: boolean;
  nextSecret: string;
  nextSecretSource: "EDGE_SHARED_SECRET_NEXT" | "X_EDGE_SECRET_NEXT" | null;
  nextAliasMismatch: boolean;
  nextExpiresAtUtc: string;
  legacyZapierIngest: string;
  legacyZapierSecret: string;
}

export function resolveEdgeSecretContractEnv(
  env: Record<string, string | undefined> = Deno.env.toObject(),
): ResolvedEdgeSecretContractEnv {
  // Canonical server secret is EDGE_SHARED_SECRET. X_EDGE_SECRET exists as a local/dev alias
  // (to avoid collisions with other subsystems when exporting credentials into shells).
  const edgeSharedSecret = String(env.EDGE_SHARED_SECRET || "").trim();
  const xEdgeSecret = String(env.X_EDGE_SECRET || "").trim();
  const edgeSharedSecretNext = String(env.EDGE_SHARED_SECRET_NEXT || "").trim();
  const xEdgeSecretNext = String(env.X_EDGE_SECRET_NEXT || "").trim();
  const currentSecret = edgeSharedSecret || xEdgeSecret;
  const nextSecret = edgeSharedSecretNext || xEdgeSecretNext;
  const nextExpiresAtUtc = String(
    env.EDGE_SHARED_SECRET_NEXT_EXPIRES_AT_UTC || env.X_EDGE_SECRET_NEXT_EXPIRES_AT_UTC || "",
  ).trim();

  const legacyZapierIngest = String(env.ZAPIER_INGEST_SECRET || "").trim();
  const legacyZapierSecret = String(env.ZAPIER_SECRET || "").trim();

  return {
    currentSecret,
    nextSecret,
    currentSecretSource: edgeSharedSecret.length > 0
      ? "EDGE_SHARED_SECRET"
      : xEdgeSecret.length > 0
      ? "X_EDGE_SECRET"
      : null,
    currentAliasMismatch: edgeSharedSecret.length > 0 &&
      xEdgeSecret.length > 0 &&
      edgeSharedSecret !== xEdgeSecret,
    nextSecretSource: edgeSharedSecretNext.length > 0
      ? "EDGE_SHARED_SECRET_NEXT"
      : xEdgeSecretNext.length > 0
      ? "X_EDGE_SECRET_NEXT"
      : null,
    nextAliasMismatch: edgeSharedSecretNext.length > 0 &&
      xEdgeSecretNext.length > 0 &&
      edgeSharedSecretNext !== xEdgeSecretNext,
    nextExpiresAtUtc,
    legacyZapierIngest,
    legacyZapierSecret,
  };
}

export function resolveZapierLegacySecretCandidates(
  env: Record<string, string | undefined> = Deno.env.toObject(),
): string[] {
  return Array.from(
    new Set(
      [
        String(env.ZAPIER_INGEST_SECRET || "").trim(),
        String(env.ZAPIER_SECRET || "").trim(),
      ].filter((value) => value.length > 0),
    ),
  );
}

export function evaluateEdgeSecretContract(
  env: Record<string, string | undefined> = Deno.env.toObject(),
  nowMs = Date.now(),
): EdgeSecretContract {
  const values = resolveEdgeSecretContractEnv(env);
  const driftReasons: string[] = [];

  const currentSecretSet = values.currentSecret.length > 0;
  if (!currentSecretSet) driftReasons.push("current_secret_missing");
  if (values.currentAliasMismatch) driftReasons.push("current_secret_alias_mismatch");

  const nextSecretSet = values.nextSecret.length > 0;
  const nextExpiresMs = parseIsoDateMs(values.nextExpiresAtUtc);
  const nextExpiresAtUtc = values.nextExpiresAtUtc || null;
  const nextExpiryMissing = nextSecretSet && !nextExpiresAtUtc;
  const nextExpiryInvalid = nextSecretSet && nextExpiresAtUtc !== null && nextExpiresMs == null;
  const nextWindowActive = nextSecretSet && nextExpiresMs != null && nextExpiresMs > nowMs;
  const nextWindowSecondsRemaining = nextWindowActive && nextExpiresMs != null
    ? Math.max(0, Math.floor((nextExpiresMs - nowMs) / 1000))
    : 0;

  if (nextExpiryMissing) driftReasons.push("next_secret_expiry_missing");
  if (nextExpiryInvalid) driftReasons.push("next_secret_expiry_invalid");
  if (values.nextAliasMismatch) driftReasons.push("next_secret_alias_mismatch");
  if (nextSecretSet && nextExpiresMs != null && nextExpiresMs <= nowMs) {
    driftReasons.push("next_secret_expired");
  }

  const legacySet = {
    ZAPIER_INGEST_SECRET: values.legacyZapierIngest.length > 0,
    ZAPIER_SECRET: values.legacyZapierSecret.length > 0,
  };
  if (legacySet.ZAPIER_INGEST_SECRET || legacySet.ZAPIER_SECRET) {
    driftReasons.push("legacy_secret_env_present");
  }

  const status: EdgeSecretContractStatus = currentSecretSet
    ? (driftReasons.length > 0 ? "drift" : "healthy")
    : "missing";

  return {
    status,
    current_secret_set: currentSecretSet,
    next_secret_set: nextSecretSet,
    next_expires_at_utc: nextExpiresAtUtc,
    next_window_active: nextWindowActive,
    next_window_seconds_remaining: nextWindowSecondsRemaining,
    legacy_secret_envs_set: legacySet,
    drift_reasons: driftReasons,
  };
}

export function authorizeEdgeSecretRequest(
  req: Request,
  env: Record<string, string | undefined> = Deno.env.toObject(),
  nowMs = Date.now(),
): EdgeSecretAuthResult {
  const values = resolveEdgeSecretContractEnv(env);
  const contract = evaluateEdgeSecretContract(env, nowMs);
  const providedSecret = String(
    req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret") || "",
  ).trim();

  if (!values.currentSecret) {
    return {
      ok: false,
      status: 500,
      error_code: "edge_secret_missing",
      error: "X_EDGE_SECRET/EDGE_SHARED_SECRET is not configured",
      contract,
      current_secret: "",
    };
  }

  if (!providedSecret) {
    return {
      ok: false,
      status: 401,
      error_code: "edge_secret_missing",
      error: "X-Edge-Secret header is required",
      contract,
      current_secret: values.currentSecret,
    };
  }

  if (constantTimeEqual(providedSecret, values.currentSecret)) {
    return {
      ok: true,
      status: 200,
      matched_slot: "current",
      contract,
      current_secret: values.currentSecret,
    };
  }

  const nextSecretSet = values.nextSecret.length > 0;
  const nextExpiresMs = parseIsoDateMs(values.nextExpiresAtUtc);
  const nextWindowActive = nextSecretSet && nextExpiresMs != null && nextExpiresMs > nowMs;

  if (nextWindowActive && constantTimeEqual(providedSecret, values.nextSecret)) {
    return {
      ok: true,
      status: 200,
      matched_slot: "next",
      contract,
      current_secret: values.currentSecret,
    };
  }

  if (nextSecretSet && constantTimeEqual(providedSecret, values.nextSecret)) {
    return {
      ok: false,
      status: 403,
      error_code: "edge_secret_drift",
      error: "Provided secret matches an expired/inactive rotation secret",
      contract,
      current_secret: values.currentSecret,
    };
  }

  return {
    ok: false,
    status: 403,
    error_code: "invalid_edge_secret",
    error: "Provided secret does not match the active edge secret contract",
    contract,
    current_secret: values.currentSecret,
  };
}

export function buildEdgeSecretHealthSnapshot(
  env: Record<string, string | undefined> = Deno.env.toObject(),
  nowMs = Date.now(),
) {
  const contract = evaluateEdgeSecretContract(env, nowMs);
  return {
    ok: contract.status === "healthy",
    contract_status: contract.status,
    machine_error_codes: {
      missing: "edge_secret_missing",
      invalid: "invalid_edge_secret",
      drift: "edge_secret_drift",
    },
    ...contract,
  };
}
