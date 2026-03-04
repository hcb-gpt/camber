/**
 * triage-telemetry Edge Function
 *
 * Accepts client-side truth-forcing telemetry events (iOS) and persists them to `diagnostic_logs`.
 *
 * Auth:
 * - Internal machine-to-machine: X-Edge-Secret (EDGE_SHARED_SECRET) + X-Source allowlist.
 *   This avoids granting public anon callers write access to diagnostic_logs.
 *
 * @version 1.0.0
 * @date 2026-03-04
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_NAME = "triage-telemetry";
const FUNCTION_VERSION = "triage-telemetry_v1.0.0";

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-edge-secret, x-source",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function json(data: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  // Internal auth gate (Pattern A from CLAUDE.md)
  const auth = requireEdgeSecret(req, ["ios_redline"]);
  if (!auth.ok) return authErrorResponse(auth.error_code || "invalid_edge_secret");

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const eventName = body?.event_name;
  const surface = body?.surface;
  const eventType = body?.event_type;
  const occurredAtUtc = body?.occurred_at_utc;
  const payload = body?.payload ?? null;

  if (!isNonEmptyString(eventName)) return json({ ok: false, error: "missing_event_name" }, 400);
  if (!isNonEmptyString(surface)) return json({ ok: false, error: "missing_surface" }, 400);
  if (!isNonEmptyString(eventType)) return json({ ok: false, error: "missing_event_type" }, 400);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("[triage-telemetry] missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
    return json({ ok: false, error: "server_misconfigured" }, 500);
  }

  const db = createClient(supabaseUrl, serviceRoleKey);

  const metadata = {
    source: auth.source || "missing",
    event_name: String(eventName).trim(),
    surface: String(surface).trim(),
    event_type: String(eventType).trim(),
    occurred_at_utc: isNonEmptyString(occurredAtUtc) ? occurredAtUtc.trim() : null,
    payload,
    headers: {
      // Helpful for tracing without leaking secrets.
      user_agent: req.headers.get("User-Agent") || null,
    },
  };

  const { error } = await db.from("diagnostic_logs").insert({
    function_name: FUNCTION_NAME,
    function_version: FUNCTION_VERSION,
    log_level: "info",
    message: String(eventName).trim().slice(0, 200),
    metadata,
  });

  if (error) {
    console.error("[triage-telemetry] diagnostic_logs insert failed:", error.message);
    return json({ ok: false, error: "db_insert_failed" }, 500);
  }

  return json({
    ok: true,
    version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
});

