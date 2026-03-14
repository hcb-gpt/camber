const GMAIL_API_BASE_URL = "https://gmail.googleapis.com/gmail/v1/users/me";
export const GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly";
export const GMAIL_TOKEN_URL = "https://oauth2.googleapis.com/token";

function readEnv(env: Record<string, string> | Deno.Env | undefined, name: string): string {
  if (!env) return "";
  if (typeof (env as Deno.Env).get === "function") {
    return String((env as Deno.Env).get(name) || "");
  }
  return String((env as Record<string, string>)[name] || "");
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    for (const byte of chunk) binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array {
  const normalized = base64UrlToBase64(value);
  const binary = atob(normalized);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function base64UrlToBase64(value: string): string {
  const raw = String(value || "").replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  if (!raw) return "";
  const padLength = (4 - (raw.length % 4)) % 4;
  return `${raw}${"=".repeat(padLength)}`;
}

function toBase64Url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function pemToPkcs8(pemRaw: string): ArrayBuffer {
  const pem = String(pemRaw || "").replace(/\\n/g, "\n");
  const normalized = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const bytes = base64ToBytes(normalized);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

async function buildSignedJwt(claims: Record<string, unknown>, privateKeyPem: string): Promise<string> {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) {
    throw new Error("crypto_subtle_unavailable");
  }

  const header = { alg: "RS256", typ: "JWT" };
  const signingInput = `${toBase64Url(JSON.stringify(header))}.${toBase64Url(JSON.stringify(claims))}`;
  const key = await subtle.importKey(
    "pkcs8",
    pemToPkcs8(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${toBase64Url(new Uint8Array(signature))}`;
}

export function parseServiceAccountFromEnv(env: Record<string, string> | Deno.Env | undefined) {
  const rawJson = readEnv(env, "GMAIL_SERVICE_ACCOUNT_JSON");
  const legacyRawJson = readEnv(env, "GOOGLE_SERVICE_ACCOUNT_JSON");
  const serviceAccountJson = rawJson || legacyRawJson;
  if (serviceAccountJson) {
    try {
      const parsed = JSON.parse(serviceAccountJson);
      if (typeof parsed?.client_email === "string" && typeof parsed?.private_key === "string") {
        return {
          client_email: parsed.client_email,
          private_key: parsed.private_key,
          subject: typeof parsed?.subject === "string" ? parsed.subject : null,
        };
      }
    } catch {
      // Fall through to discrete env vars.
    }
  }

  const clientEmail = readEnv(env, "GMAIL_SERVICE_ACCOUNT_EMAIL") || readEnv(env, "GOOGLE_SERVICE_ACCOUNT_EMAIL");
  const privateKey = readEnv(env, "GMAIL_SERVICE_ACCOUNT_PRIVATE_KEY")
    || readEnv(env, "GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY");
  const subject = readEnv(env, "GMAIL_IMPERSONATED_USER")
    || readEnv(env, "GMAIL_SERVICE_ACCOUNT_SUBJECT")
    || readEnv(env, "GOOGLE_IMPERSONATED_USER")
    || readEnv(env, "GOOGLE_SERVICE_ACCOUNT_SUBJECT")
    || null;
  if (!clientEmail || !privateKey) return null;
  return { client_email: clientEmail, private_key: privateKey, subject };
}

async function getAccessTokenFromRefreshToken({
  env,
  warnings,
  fetchImpl,
}: {
  env: Record<string, string> | Deno.Env | undefined;
  warnings: string[];
  fetchImpl: typeof fetch;
}): Promise<string | null> {
  const clientId = readEnv(env, "GMAIL_OAUTH_CLIENT_ID") || readEnv(env, "GOOGLE_CLIENT_ID");
  const clientSecret = readEnv(env, "GMAIL_OAUTH_CLIENT_SECRET") || readEnv(env, "GOOGLE_CLIENT_SECRET");
  const refreshToken = readEnv(env, "GMAIL_OAUTH_REFRESH_TOKEN") || readEnv(env, "GOOGLE_REFRESH_TOKEN");
  if (!clientId || !clientSecret || !refreshToken) return null;

  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: refreshToken,
    grant_type: "refresh_token",
  });

  const response = await fetchImpl(GMAIL_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  if (!response.ok) {
    warnings.push(`gmail_refresh_failed_http_${response.status}`);
    return null;
  }

  const json = await response.json().catch(() => null);
  const token = typeof json?.access_token === "string" ? json.access_token : null;
  if (!token) warnings.push("gmail_refresh_missing_access_token");
  return token;
}

async function getAccessTokenFromServiceAccount({
  env,
  warnings,
  fetchImpl,
}: {
  env: Record<string, string> | Deno.Env | undefined;
  warnings: string[];
  fetchImpl: typeof fetch;
}): Promise<string | null> {
  const serviceAccount = parseServiceAccountFromEnv(env);
  if (!serviceAccount) return null;

  const now = Math.floor(Date.now() / 1000);
  const claims: Record<string, unknown> = {
    iss: serviceAccount.client_email,
    scope: GMAIL_SCOPE,
    aud: GMAIL_TOKEN_URL,
    iat: now,
    exp: now + 3600,
  };

  if (serviceAccount.subject) {
    claims.sub = serviceAccount.subject;
  } else {
    warnings.push("gmail_service_account_no_subject");
  }

  let assertion;
  try {
    assertion = await buildSignedJwt(claims, serviceAccount.private_key);
  } catch (error) {
    warnings.push(`gmail_service_account_sign_failed:${String((error as Error)?.message || error).slice(0, 80)}`);
    return null;
  }

  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion,
  });

  const response = await fetchImpl(GMAIL_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  if (!response.ok) {
    warnings.push(`gmail_service_account_token_failed_http_${response.status}`);
    return null;
  }

  const json = await response.json().catch(() => null);
  const token = typeof json?.access_token === "string" ? json.access_token : null;
  if (!token) warnings.push("gmail_service_account_missing_access_token");
  return token;
}

export async function resolveGmailAccessToken({
  env,
  warnings = [],
  fetchImpl = fetch,
}: {
  env?: Record<string, string> | Deno.Env;
  warnings?: string[];
  fetchImpl?: typeof fetch;
} = {}) {
  const staticToken = readEnv(env, "GMAIL_OAUTH_ACCESS_TOKEN");
  if (staticToken) {
    return { token: staticToken, authMode: "static_access_token" };
  }

  const refreshTokenValue = await getAccessTokenFromRefreshToken({ env, warnings, fetchImpl });
  if (refreshTokenValue) {
    return { token: refreshTokenValue, authMode: "oauth_refresh_token" };
  }

  const serviceAccountToken = await getAccessTokenFromServiceAccount({ env, warnings, fetchImpl });
  if (serviceAccountToken) {
    return { token: serviceAccountToken, authMode: "service_account" };
  }

  warnings.push("gmail_auth_unconfigured");
  return { token: null, authMode: null };
}

export async function gmailApiGetJson({
  token,
  path,
  params = {},
  fetchImpl = fetch,
}: {
  token: string;
  path: string;
  params?: Record<string, unknown>;
  fetchImpl?: typeof fetch;
}) {
  const url = new URL(`${GMAIL_API_BASE_URL}/${String(path || "").replace(/^\/+/, "")}`);
  for (const [key, value] of Object.entries(params || {})) {
    if (value === undefined || value === null) continue;
    if (Array.isArray(value)) {
      for (const item of value) url.searchParams.append(key, String(item));
    } else {
      url.searchParams.set(key, String(value));
    }
  }

  let response: Response;
  try {
    response = await fetchImpl(url.toString(), {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
    });
  } catch {
    return { ok: false, status: 0, json: null };
  }

  const json = await response.json().catch(() => null);
  return { ok: response.ok, status: response.status, json };
}
