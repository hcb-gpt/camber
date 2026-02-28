/**
 * zapier-call-ingest Edge Function v1.7.1
 *
 * Auth model (consolidated):
 * - Canonical: X-Edge-Secret === EDGE_SHARED_SECRET
 * - Transitional legacy fallback: X-Secret === ZAPIER_INGEST_SECRET|ZAPIER_SECRET
 *
 * Forward: Calls process-call internally using SUPABASE_SERVICE_ROLE_KEY + X-Edge-Secret.
 *
 * v1.7.1: Fix beside auth bypass — move body parse + beside detection BEFORE auth gate.
 * v1.6.0 had beside check pre-auth (worked). v1.7.0 had it post-auth (still 401'd).
 * Now: parse body → beside passthrough (no auth needed) → auth gate → process-call.
 *
 * v1.7.0: Recovered BESIDE_RAW_PASSTHROUGH from lost v1.6.0 deploy (Charter §10).
 * Beside-format payloads (fromPhoneNumber/toPhoneNumber/noteUrl) are normalized
 * and inserted directly into calls_raw with capture_source='beside_zapier'.
 *
 * @version 1.7.1
 * @date 2026-02-28
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const VERSION = "v1.7.1";

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
    event_at_utc: p.createdAt || p.finishedAt || new Date().toISOString(),
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

  // ---- BESIDE_RAW_PASSTHROUGH: detect Beside-format and insert directly ----
  // Beside payloads bypass auth — they arrive from Zapier without edge secret
  // headers. Detection is body-based (fromPhoneNumber/toPhoneNumber/noteUrl).
  // v1.7.1: Moved BEFORE auth gate. v1.7.0 had it after auth (still 401'd).
  if (isBesidePayload(payload)) {
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

    return new Response(
      JSON.stringify({
        ok: true,
        path: "beside_raw_passthrough",
        interaction_id: row.interaction_id,
        capture_source: "beside_zapier",
        version: VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  // ---- Auth gate (canonical + transitional legacy fallback) ----
  // Non-beside payloads must authenticate to reach process-call.
  const incomingXEdgeSecret = req.headers.get("X-Edge-Secret") || "";
  const incomingXSecret = req.headers.get("X-Secret") || "";
  const expectedEdgeSecret = Deno.env.get("EDGE_SHARED_SECRET") || "";
  const expectedLegacySecret = Deno.env.get("ZAPIER_INGEST_SECRET") || Deno.env.get("ZAPIER_SECRET") || "";

  if (!expectedEdgeSecret) {
    await logDiagnostic("AUTH_CONFIG_MISSING", {
      expected: { edge_shared_secret_set: false },
    });
    return new Response(
      JSON.stringify({ error: "server_misconfigured", version: VERSION }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const canonicalValid = incomingXEdgeSecret.length > 0 && incomingXEdgeSecret === expectedEdgeSecret;
  const legacyValid = expectedLegacySecret.length > 0 &&
    incomingXSecret.length > 0 &&
    incomingXSecret === expectedLegacySecret;

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

  const forwardHeaders: Record<string, string> = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${serviceRoleKey}`,
  };
  forwardHeaders["X-Edge-Secret"] = expectedEdgeSecret;

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
      ms: Date.now() - t0,
    },
  };

  return new Response(JSON.stringify(result), {
    status: processCallResponse.status,
    headers: { "Content-Type": "application/json" },
  });
});
