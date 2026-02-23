/**
 * morning-manifest-ui Edge Function v0.1.0
 *
 * Browser-callable endpoint for Morning Manifest UI.
 * - verify_jwt=true (gateway)
 * - validates bearer token and returns manifest rows + queue summary
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { type ManifestResponse, renderManifestHtml, wantsHtmlResponse } from "./view.ts";

const FUNCTION_VERSION = "v0.1.0";

const BASE_HEADERS = {
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

Deno.serve(async (req: Request) => {
  const startedAt = Date.now();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: BASE_HEADERS });
  }

  if (req.method !== "GET") {
    return json(405, {
      ok: false,
      error: "method_not_allowed",
      detail: "Use GET",
    });
  }

  try {
    const authHeader = req.headers.get("authorization") ?? req.headers.get("Authorization") ?? "";
    const token = extractBearerToken(authHeader);
    if (!token) {
      return json(401, {
        ok: false,
        error: "missing_bearer_token",
        detail: "Authorization: Bearer <jwt> is required",
      });
    }

    const supabaseUrl = mustGetEnv("SUPABASE_URL");
    const serviceRoleKey = mustGetEnv("SUPABASE_SERVICE_ROLE_KEY");

    const db = createClient(supabaseUrl, serviceRoleKey);
    const claims = decodeJwtPayload(token);
    const tokenRole = typeof claims.role === "string" ? claims.role : null;
    const hasSubject = typeof claims.sub === "string" && claims.sub.trim().length > 0;

    let viewer: { id: string; email: string | null; role: string | null } = {
      id: hasSubject ? "" : "service-role",
      email: null,
      role: tokenRole,
    };

    if (hasSubject) {
      const { data: userData, error: userError } = await db.auth.getUser(token);
      if (userError || !userData?.user) {
        return json(401, {
          ok: false,
          error: "invalid_jwt",
          detail: userError?.message ?? "Unable to validate token",
        });
      }
      viewer = {
        id: userData.user.id,
        email: userData.user.email ?? null,
        role: userData.user.role ?? tokenRole,
      };
    } else if (tokenRole !== "service_role") {
      return json(401, {
        ok: false,
        error: "invalid_jwt",
        detail: "token must include sub claim or service_role role",
      });
    }

    const url = new URL(req.url);
    const limit = parseBoundedInt(url.searchParams.get("limit"), 50, 1, 250);
    const wantsHtml = wantsHtmlResponse(req, url);

    const { data: manifestRows, error: manifestError } = await db
      .from("v_morning_manifest")
      .select("*")
      .limit(limit);

    if (manifestError) {
      return json(500, {
        ok: false,
        error: "manifest_query_failed",
        detail: manifestError.message,
      });
    }

    let pendingReviewCount: number | null = null;
    let reviewQueueWarning: string | null = null;
    const { count, error: reviewError } = await db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending");

    if (reviewError) {
      reviewQueueWarning = reviewError.message;
    } else {
      pendingReviewCount = count ?? 0;
    }

    const payload: ManifestResponse = {
      ok: true,
      function_version: FUNCTION_VERSION,
      generated_at: new Date().toISOString(),
      ms: Date.now() - startedAt,
      user: viewer,
      summary: {
        project_row_count: manifestRows?.length ?? 0,
        pending_review_count: pendingReviewCount,
        review_queue_warning: reviewQueueWarning,
      },
      manifest: manifestRows ?? [],
    };

    if (wantsHtml) {
      return html(200, renderManifestHtml(payload, limit));
    }

    return json(200, payload);
  } catch (err) {
    console.error("[morning-manifest-ui] fatal:", err);
    return json(500, {
      ok: false,
      error: "morning_manifest_ui_fatal",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
});

function mustGetEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing_env_${name}`);
  return value;
}

function extractBearerToken(header: string): string | null {
  const trimmed = header.trim();
  if (!trimmed) return null;
  const match = /^Bearer\s+(.+)$/i.exec(trimmed);
  if (!match) return null;
  const token = match[1]?.trim();
  return token ? token : null;
}

function parseBoundedInt(raw: string | null, fallback: number, min: number, max: number): number {
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

function decodeJwtPayload(token: string): Record<string, unknown> {
  const parts = token.split(".");
  if (parts.length < 2) return {};

  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const jsonText = atob(padded);
    const parsed = JSON.parse(jsonText);
    return parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: BASE_HEADERS,
  });
}

function html(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: {
      ...BASE_HEADERS,
      "Content-Type": "text/html; charset=utf-8",
    },
  });
}
