/**
 * time-resolver Edge Function v1.1.0
 * Deterministic resolver for scheduler time hints.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { resolveTime } from "../_shared/time_resolver.ts";

const FUNCTION_VERSION = "v1.1.0";
const ALLOWED_SOURCES = ["test", "strat", "operator", "time-resolver", "redline", "scheduler-trigger", "resolve-scheduler-time"];

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({
      ok: false,
      error: "method_not_allowed",
      function_version: FUNCTION_VERSION,
    }, 405);
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) return authErrorResponse(auth.error_code || "auth_failed");

  try {
    const body = await req.json().catch(() => ({}));
    const timeHint = typeof body?.time_hint === "string" ? body.time_hint : "";
    const anchorTs = typeof body?.anchor_ts === "string" && body.anchor_ts.trim().length > 0
      ? body.anchor_ts
      : new Date().toISOString();

    if (!timeHint.trim()) {
      return json({
        ok: false,
        error: "missing_time_hint",
        function_version: FUNCTION_VERSION,
      }, 400);
    }

    const resolution = resolveTime(timeHint, anchorTs, {
      timezone: typeof body?.timezone === "string" ? body.timezone : undefined,
      project_timezone: typeof body?.project_timezone === "string" ? body.project_timezone : undefined,
      user_timezone: typeof body?.user_timezone === "string" ? body.user_timezone : undefined,
    });

    return json({
      ok: true,
      function_version: FUNCTION_VERSION,
      source: auth.source || null,
      resolution,
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    return json({
      ok: false,
      error: "resolver_exception",
      detail: message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
});
