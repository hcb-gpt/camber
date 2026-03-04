/**
 * triage-telemetry Edge Function
 *
 * Accepts client-side truth-forcing telemetry events (iOS) and persists them for KPI dashboards.
 *
 * Auth:
 * - Internal machine-to-machine: X-Edge-Secret (X_EDGE_SECRET/EDGE_SHARED_SECRET) + X-Source allowlist.
 *
 * @version 1.1.0
 * @date 2026-03-04
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_NAME = "triage-telemetry";
const FUNCTION_VERSION = "triage-telemetry_v1.1.0";

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

function asString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function asInt(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === "string") {
    const n = Number.parseInt(value, 10);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function asBool(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") {
    const v = value.trim().toLowerCase();
    if (v === "true" || v === "1") return true;
    if (v === "false" || v === "0") return false;
  }
  return null;
}

function isLearningLoopMetricEvent(eventType: string): boolean {
  return [
    "pick_time_sample",
    "write_action",
    "undo_tap",
    "auth_lock_ui_disabled",
    "auth_lock_blocked",
  ].includes(eventType);
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
  const eventTypeRaw = body?.event_type;
  const occurredAtUtc = body?.occurred_at_utc;
  const payload = body?.payload ?? null;

  if (!isNonEmptyString(eventName)) return json({ ok: false, error: "missing_event_name" }, 400);
  if (!isNonEmptyString(surface)) return json({ ok: false, error: "missing_surface" }, 400);
  if (!isNonEmptyString(eventTypeRaw)) return json({ ok: false, error: "missing_event_type" }, 400);

  const eventType = String(eventTypeRaw).trim();

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("[triage-telemetry] missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
    return json({ ok: false, error: "server_misconfigured" }, 500);
  }

  const db = createClient(supabaseUrl, serviceRoleKey);

  const warnings: string[] = [];

  // 1) KPI ingestion (canonical)
  if (isLearningLoopMetricEvent(eventType)) {
    const createdAt = isNonEmptyString(occurredAtUtc) ? occurredAtUtc.trim() : undefined;
    const p = payload ?? {};
    const sessionId = asString(p?.session_id) ?? null;

    if (eventType === "pick_time_sample") {
      const queueId = asString(p?.queue_id);
      const elapsedMs = asInt(p?.elapsed_ms);
      const source = asString(p?.source);
      const hadAiSuggestion = asBool(p?.had_ai_suggestion);
      const evidenceCount = asInt(p?.evidence_count);
      if (!queueId) return json({ ok: false, error: "missing_queue_id" }, 400);
      if (elapsedMs == null) return json({ ok: false, error: "missing_elapsed_ms" }, 400);
      if (!source) return json({ ok: false, error: "missing_source" }, 400);

      const { error } = await db.from("camber_metrics_pick_time").insert({
        created_at: createdAt,
        queue_id: queueId,
        elapsed_ms: elapsedMs,
        surface: String(surface).trim(),
        source,
        had_ai_suggestion: hadAiSuggestion ?? false,
        evidence_count: evidenceCount ?? 0,
        session_id: sessionId,
      });
      if (error) {
        console.error("[triage-telemetry] camber_metrics_pick_time insert failed:", error.message);
        return json({ ok: false, error: "db_insert_failed", table: "camber_metrics_pick_time" }, 500);
      }
    } else if (eventType === "write_action") {
      const queueId = asString(p?.queue_id);
      const requestId = asString(p?.request_id);
      const actionType = asString(p?.action);
      if (!queueId) return json({ ok: false, error: "missing_queue_id" }, 400);
      if (!requestId) return json({ ok: false, error: "missing_request_id" }, 400);
      if (!actionType) return json({ ok: false, error: "missing_action" }, 400);

      const { error } = await db.from("camber_metrics_write_actions").insert({
        created_at: createdAt,
        queue_id: queueId,
        request_id: requestId,
        action_type: actionType,
        surface: String(surface).trim(),
        session_id: sessionId,
      });
      if (error) {
        console.error("[triage-telemetry] camber_metrics_write_actions insert failed:", error.message);
        return json(
          { ok: false, error: "db_insert_failed", table: "camber_metrics_write_actions" },
          500,
        );
      }
    } else if (eventType === "undo_tap") {
      const queueId = asString(p?.queue_id);
      const undoOf = asString(p?.undo_of);
      const ageMs = asInt(p?.age_ms);
      if (!queueId) return json({ ok: false, error: "missing_queue_id" }, 400);
      if (!undoOf) return json({ ok: false, error: "missing_undo_of" }, 400);
      if (ageMs == null) return json({ ok: false, error: "missing_age_ms" }, 400);

      const { error } = await db.from("camber_metrics_undo_events").insert({
        created_at: createdAt,
        queue_id: queueId,
        undo_of: undoOf,
        age_ms: ageMs,
        surface: String(surface).trim(),
        session_id: sessionId,
      });
      if (error) {
        console.error("[triage-telemetry] camber_metrics_undo_events insert failed:", error.message);
        return json({ ok: false, error: "db_insert_failed", table: "camber_metrics_undo_events" }, 500);
      }
    } else if (eventType === "auth_lock_ui_disabled") {
      const statusCode = asInt(p?.status_code);
      if (statusCode == null) return json({ ok: false, error: "missing_status_code" }, 400);

      const { error } = await db.from("camber_metrics_auth_friction").insert({
        created_at: createdAt,
        status_code: statusCode,
        friction_type: "AUTH_LOCK_UI_DISABLED",
        action_type: null,
        surface: String(surface).trim(),
        queue_id: asString(p?.queue_id),
        session_id: sessionId,
      });
      if (error) {
        console.error("[triage-telemetry] camber_metrics_auth_friction insert failed:", error.message);
        return json(
          { ok: false, error: "db_insert_failed", table: "camber_metrics_auth_friction" },
          500,
        );
      }
    } else if (eventType === "auth_lock_blocked") {
      const statusCode = asInt(p?.status_code);
      if (statusCode == null) return json({ ok: false, error: "missing_status_code" }, 400);

      const { error } = await db.from("camber_metrics_auth_friction").insert({
        created_at: createdAt,
        status_code: statusCode,
        friction_type: "AUTH_LOCK_BLOCKED",
        action_type: asString(p?.action),
        surface: String(surface).trim(),
        queue_id: asString(p?.queue_id),
        session_id: sessionId,
      });
      if (error) {
        console.error("[triage-telemetry] camber_metrics_auth_friction insert failed:", error.message);
        return json(
          { ok: false, error: "db_insert_failed", table: "camber_metrics_auth_friction" },
          500,
        );
      }
    }
  }

  // 2) Diagnostic log (best-effort; do not fail KPI ingestion if this insert fails)
  const metadata = {
    source: auth.source || "missing",
    event_name: String(eventName).trim(),
    surface: String(surface).trim(),
    event_type: eventType,
    occurred_at_utc: isNonEmptyString(occurredAtUtc) ? occurredAtUtc.trim() : null,
    payload,
    headers: {
      // Helpful for tracing without leaking secrets.
      user_agent: req.headers.get("User-Agent") || null,
    },
  };

  const { error: diagError } = await db.from("diagnostic_logs").insert({
    function_name: FUNCTION_NAME,
    function_version: FUNCTION_VERSION,
    log_level: "info",
    message: String(eventName).trim().slice(0, 200),
    metadata,
  });

  if (diagError) {
    warnings.push("diagnostic_logs_insert_failed");
    console.error("[triage-telemetry] diagnostic_logs insert failed:", diagError.message);
  }

  return json({
    ok: true,
    version: FUNCTION_VERSION,
    metrics_event: isLearningLoopMetricEvent(eventType),
    warnings: warnings.length > 0 ? warnings : undefined,
    ms: Date.now() - t0,
  });
});

