/**
 * zapier-call-ingest Edge Function v1.9.1
 *
 * Auth model (consolidated):
 * - Canonical: X-Edge-Secret === EDGE_SHARED_SECRET
 * - Transitional legacy fallback: X-Secret === ZAPIER_INGEST_SECRET|ZAPIER_SECRET
 *
 * Forward: Calls process-call internally using SUPABASE_SERVICE_ROLE_KEY + X-Edge-Secret.
 *
 * v1.9.0: Fix Go-style timestamp parsing from Beside. Beside sends timestamps like
 * "2026-02-27 18:54:37.777013 +0000 UTC" which Postgres can't parse (trailing " UTC").
 * Added normalizeTimestamp() to strip timezone name suffix and fix offset format.
 *
 * v1.9.1: Require X-Edge-Secret for Beside payload path (no legacy bypass).
 *
 * v1.8.1: Remove Beside auth bypass (Beside payloads must authenticate).
 *
 * v1.8.0: Beside passthrough now forwards to process-call after upsert for full
 * pipeline normalization (interactions row, contact link, AI attribution).
 * Forward is best-effort — upsert success = 200 to Zapier regardless.
 *
 * v1.7.1: Fix beside auth bypass — move body parse + beside detection BEFORE auth gate.
 * v1.7.0: Recovered BESIDE_RAW_PASSTHROUGH from lost v1.6.0 deploy (Charter §10).
 *
 * @version 1.9.1
 * @date 2026-03-01
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { authorizeEdgeSecretRequest } from "../_shared/edge_secret_contract.ts";

const VERSION = "v1.9.1";

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

async function logDiagnostic(
  message: string,
  metadata: Record<string, any>,
  level: "error" | "info" = "error",
) {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const sb = createClient(supabaseUrl, serviceRoleKey);
    await sb.from("diagnostic_logs").insert({
      function_name: "zapier-call-ingest",
      function_version: VERSION,
      log_level: level,
      message,
      metadata,
    });
  } catch (e) {
    console.error("Failed to write diagnostic log:", e);
  }
}

/** Detect Beside-format call payloads by presence of Beside-specific fields. */
function isBesidePayload(p: any): boolean {
  return !!(p && (p.fromPhoneNumber || p.toPhoneNumber || p.noteUrl));
}

/**
 * Normalize timestamps from Beside (Go-style) into Postgres-safe format.
 * Handles: "2026-02-27 18:54:37.777013 +0000 UTC" → "2026-02-27 18:54:37.777013 +00:00"
 * Also handles: already-valid ISO 8601, Z-suffix, space-separated no TZ.
 */
function normalizeTimestamp(ts: string | null | undefined): string | null {
  if (!ts) return null;
  // Strip Go-style trailing timezone name (UTC, EST, PST, etc.)
  let normalized = ts.replace(/\s+[A-Z]{2,5}$/, "");
  // Ensure offset format: +0000 → +00:00
  normalized = normalized.replace(/(\+|-)(\d{2})(\d{2})$/, "$1$2:$3");
  return normalized;
}

/** Normalize a Beside-format payload into a calls_raw insert row. */
function besideToCallsRaw(p: any, zapierMeta: any): Record<string, any> {
  const interactionId = p.id || p.interaction_id || `beside_${Date.now()}`;
  const direction = String(p.direction || "").toLowerCase().includes("outbound") ? "outbound" : "inbound";
  const isOutbound = direction === "outbound";

  return {
    interaction_id: interactionId,
    channel: "call",
    direction,
    other_party_name: isOutbound ? (p.toName || null) : (p.fromName || null),
    other_party_phone: isOutbound ? (p.toPhoneNumber || null) : (p.fromPhoneNumber || null),
    owner_name: isOutbound ? (p.fromName || null) : (p.toName || null),
    owner_phone: isOutbound ? (p.fromPhoneNumber || null) : (p.toPhoneNumber || null),
    event_at_utc: normalizeTimestamp(p.createdAt) || normalizeTimestamp(p.finishedAt) || new Date().toISOString(),
    summary: p.summary || p.title || null,
    transcript: p.transcript || null,
    recording_url: p.recordingUrl || null,
    beside_note_url: p.noteUrl || null,
    raw_snapshot_json: p,
    capture_source: "beside_zapier",
    pipeline_version: VERSION,
    is_shadow: false,
    ingested_at_utc: new Date().toISOString(),
    received_at_utc: new Date().toISOString(),
    zap_id: zapierMeta.zap_id,
    zapier_run_id: zapierMeta.run_id,
    zapier_zap_id: zapierMeta.zap_id,
  };
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "POST only", version: VERSION }),
      { status: 405, headers: { "Content-Type": "application/json" } },
    );
  }

  // ---- Parse incoming body FIRST (needed for beside detection before auth) ----
  let rawBody: any;
  try {
    rawBody = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "invalid_json", version: VERSION }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  // ---- Unwrap payload_json ----
  const ingestWarnings: string[] = [];
  let payload: any;
  if (rawBody.payload_json && typeof rawBody.payload_json === "string") {
    try {
      payload = JSON.parse(rawBody.payload_json);
    } catch (e: any) {
      ingestWarnings.push("payload_json_non_json_string_fallback");
      payload = { ...rawBody, payload_text: rawBody.payload_json };
      delete payload.payload_json;
      await logDiagnostic("PAYLOAD_JSON_PARSE_FALLBACK", {
        detail: e?.message || "unknown",
        snippet: String(rawBody.payload_json || "").slice(0, 160),
      });
    }
  } else if (rawBody.payload_json && typeof rawBody.payload_json === "object") {
    payload = rawBody.payload_json;
  } else {
    payload = rawBody;
  }

  payload.source = "zapier";

  const zapierMeta = {
    zap_id: req.headers.get("X-Zapier-Zap-ID") || null,
    run_id: req.headers.get("X-Zapier-Run-ID") || null,
    timestamp: req.headers.get("X-Zapier-Timestamp") || null,
    source_header: req.headers.get("X-Source") || null,
    idempotency_key: req.headers.get("Idempotency-Key") || null,
  };
  payload._zapier_ingest_meta = zapierMeta;

  // ---- Auth materials (canonical + legacy) ----
  const incomingXEdgeSecret = req.headers.get("X-Edge-Secret") || "";
  const incomingXSecret = req.headers.get("X-Secret") || "";
  const expectedLegacySecret = Deno.env.get("ZAPIER_INGEST_SECRET") || Deno.env.get("ZAPIER_SECRET") || "";

  const authResult = authorizeEdgeSecretRequest(req);
  const canonicalValid = authResult.ok;
  
  if (!authResult.ok && authResult.error_code === "edge_secret_missing" && authResult.status === 500) {
    await logDiagnostic("AUTH_CONFIG_MISSING", {
      expected: { edge_shared_secret_set: false },
    });
    return new Response(
      JSON.stringify({ error: "server_misconfigured", version: VERSION }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const legacyValid = expectedLegacySecret.length > 0 &&
    incomingXSecret.length > 0 &&
    constantTimeEqual(incomingXSecret, expectedLegacySecret);

  // ---- BESIDE_RAW_PASSTHROUGH: detect Beside-format and insert directly ----
  // SECURITY: Beside payloads must authenticate via canonical X-Edge-Secret only.
  // Detection is body-based (fromPhoneNumber/toPhoneNumber/noteUrl).
  if (isBesidePayload(payload)) {
    if (!canonicalValid) {
      // Truth-forcing metric/log line (no secrets). Lets us detect misrouted callers quickly.
      console.warn(
        `[zapier-call-ingest] KPI_EVENT BESIDE_AUTH_REJECTED version=${VERSION} x_edge_secret_present=${
          incomingXEdgeSecret.length > 0 ? 1 : 0
        } legacy_secret_present=${incomingXSecret.length > 0 ? 1 : 0}`,
      );
      await logDiagnostic("BESIDE_AUTH_REJECTED", {
        incoming: {
          x_edge_secret_len: incomingXEdgeSecret.length,
          x_secret_len: incomingXSecret.length,
        },
        expected: {
          edge_shared_secret_set: true,
          zapier_legacy_secret_set: expectedLegacySecret.length > 0,
        },
      });

      return new Response(
        JSON.stringify({
          error: "invalid_token",
          version: VERSION,
        }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const sb = createClient(supabaseUrl, serviceRoleKey);

    const row = besideToCallsRaw(payload, zapierMeta);
    const { error: insertErr } = await sb.from("calls_raw").upsert(row, {
      onConflict: "interaction_id",
      ignoreDuplicates: true,
    });

    const fieldsReceived = Object.keys(payload).filter((k) => payload[k] != null && k !== "_zapier_ingest_meta");
    await logDiagnostic("BESIDE_RAW_PASSTHROUGH", {
      interaction_id: row.interaction_id,
      fields_received: fieldsReceived,
      insert_ok: !insertErr,
      insert_error: insertErr?.message || null,
    }, "info");

    if (insertErr) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: "beside_passthrough_insert_failed",
          detail: insertErr.message,
          version: VERSION,
          ms: Date.now() - t0,
        }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    // Best-effort forward to process-call for full pipeline normalization
    // (interactions row, contact link, AI attribution). Upsert already
    // succeeded so Zapier gets 200 regardless of forward outcome.
    // Enrich payload with normalized event_at_utc so process-call can use it.
    const forwardPayload = {
      ...payload,
      event_at_utc: row.event_at_utc,
      interaction_id: row.interaction_id,
    };
    let forwardStatus: number | null = null;
    let forwardError: string | null = null;
    try {
      const pcUrl = `${supabaseUrl}/functions/v1/process-call`;
      const edgeSecret = authResult.ok ? authResult.current_secret : Deno.env.get("EDGE_SHARED_SECRET") || "";
      const pcResp = await fetch(pcUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${serviceRoleKey}`,
          "X-Edge-Secret": edgeSecret,
        },
        body: JSON.stringify(forwardPayload),
      });
      forwardStatus = pcResp.status;
      if (!pcResp.ok) {
        forwardError = await pcResp.text().catch(() => "unreadable");
      }
    } catch (e: any) {
      forwardError = e.message || "fetch_failed";
    }

    await logDiagnostic("BESIDE_PROCESS_CALL_FORWARD", {
      interaction_id: row.interaction_id,
      forward_status: forwardStatus,
      forward_error: forwardError,
      forward_ok: forwardStatus !== null && forwardStatus >= 200 && forwardStatus < 300,
    }, forwardError ? "error" : "info");

    return new Response(
      JSON.stringify({
        ok: true,
        path: "beside_raw_passthrough",
        interaction_id: row.interaction_id,
        capture_source: "beside_zapier",
        process_call_status: forwardStatus,
        process_call_error: forwardError,
        version: VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  // ---- Auth gate (canonical + transitional legacy fallback) ----
  // Non-beside payloads must authenticate to reach process-call.
  if (!canonicalValid && !legacyValid) {
    await logDiagnostic("AUTH_MISMATCH", {
      incoming: {
        x_edge_secret_len: incomingXEdgeSecret.length,
        x_secret_len: incomingXSecret.length,
      },
      expected: {
        edge_shared_secret_set: true,
        zapier_legacy_secret_set: expectedLegacySecret.length > 0,
      },
    });

    return new Response(
      JSON.stringify({
        error: "invalid_token",
        version: VERSION,
      }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  if (legacyValid && !canonicalValid) {
    await logDiagnostic("AUTH_LEGACY_SUCCESS", {
      incoming: { x_secret_len: incomingXSecret.length },
      expected: { zapier_legacy_secret_set: true },
      action: "deprecate_x_secret_after_zapier_update",
    });
  }

  // ---- Forward to process-call ----
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const activeEdgeSecret = authResult.ok ? authResult.current_secret : Deno.env.get("EDGE_SHARED_SECRET") || "";

  const forwardHeaders: Record<string, string> = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${serviceRoleKey}`,
  };
  forwardHeaders["X-Edge-Secret"] = activeEdgeSecret;

  const processCallUrl = `${supabaseUrl}/functions/v1/process-call`;
  const forwardOnce = async (): Promise<Response> => {
    return await fetch(
      processCallUrl,
      {
        method: "POST",
        headers: forwardHeaders,
        body: JSON.stringify(payload),
      },
    );
  };

  let processCallResponse: Response;
  try {
    processCallResponse = await forwardOnce();
  } catch (e: any) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "process_call_fetch_failed",
        detail: e.message,
        version: VERSION,
        ms: Date.now() - t0,
      }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    );
  }

  // Retry once on transient process-call 401, then return upstream status as-is.
  if (processCallResponse.status === 401) {
    await logDiagnostic("PROCESS_CALL_RETRY", {
      first_status: 401,
      wait_ms: 500,
      interaction_id: payload.interaction_id || payload.call_id || null,
      source: payload.source || null,
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    try {
      processCallResponse = await forwardOnce();
    } catch (e: any) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: "process_call_fetch_failed_after_retry",
          detail: e.message,
          version: VERSION,
          ms: Date.now() - t0,
        }),
        { status: 502, headers: { "Content-Type": "application/json" } },
      );
    }
  }

  const responseBody = await processCallResponse.text();
  let parsed: any;
  try {
    parsed = JSON.parse(responseBody);
  } catch {
    parsed = { raw: responseBody };
  }

  const result = {
    ...parsed,
    _ingest: {
      version: VERSION,
      zapier_meta: zapierMeta,
      auth_mode: canonicalValid ? "canonical_x_edge_secret" : "legacy_x_secret",
      process_call_status: processCallResponse.status,
      warnings: ingestWarnings,
      debug_anon_len: Deno.env.get("SUPABASE_ANON_KEY")?.length || 0,
      ms: Date.now() - t0,
    },
  };

  return new Response(JSON.stringify(result), {
    status: processCallResponse.status,
    headers: { "Content-Type": "application/json" },
  });
});
