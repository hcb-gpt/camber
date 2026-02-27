/**
 * zapier-call-ingest Edge Function v1.5.0
 *
 * Auth model (consolidated):
 * - Canonical: X-Edge-Secret === EDGE_SHARED_SECRET
 * - Transitional legacy fallback: X-Secret === ZAPIER_INGEST_SECRET|ZAPIER_SECRET
 *
 * Forward: Calls process-call internally using SUPABASE_SERVICE_ROLE_KEY + X-Edge-Secret.
 *
 * v1.5.0 CHANGES (ingestion diagnostics):
 * - Promote payload_text to transcript_text when parse fallback fires (rescue plain-text transcripts)
 * - Log raw body shape (field names, types) when interaction_id missing (diagnose Zapier format changes)
 *
 * @version 1.5.0
 * @date 2026-02-27
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const VERSION = "v1.5.0";

async function logDiagnostic(message: string, metadata: Record<string, any>) {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const sb = createClient(supabaseUrl, serviceRoleKey);
    await sb.from("diagnostic_logs").insert({
      function_name: "zapier-call-ingest",
      function_version: VERSION,
      log_level: "error",
      message,
      metadata,
    });
  } catch (e) {
    console.error("Failed to write diagnostic log:", e);
  }
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "POST only", version: VERSION }),
      { status: 405, headers: { "Content-Type": "application/json" } },
    );
  }

  // ---- Auth (canonical + transitional legacy fallback) ----
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

  // Legacy path should be temporary; keep a minimal audit signal.
  if (legacyValid && !canonicalValid) {
    await logDiagnostic("AUTH_LEGACY_SUCCESS", {
      incoming: { x_secret_len: incomingXSecret.length },
      expected: { zapier_legacy_secret_set: true },
      action: "deprecate_x_secret_after_zapier_update",
    });
  }

  // ---- Parse incoming body ----
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
      // Robust fallback: some Zapier steps pass plain text into payload_json.
      // Keep the request flowing by lifting raw text into payload_text and
      // forwarding remaining fields unchanged.
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

  // If payload_text exists (from parse fallback) and no transcript field, promote it.
  // This rescues transcript data when Zapier sends plain text in payload_json.
  if (payload.payload_text && !payload.transcript && !payload.transcript_text) {
    payload.transcript_text = payload.payload_text;
    ingestWarnings.push("payload_text_promoted_to_transcript_text");
  }

  // Diagnostic: log raw body shape when no interaction_id present (helps diagnose Zapier format changes)
  if (!payload.interaction_id && !payload.call_id) {
    await logDiagnostic("MISSING_INTERACTION_ID", {
      raw_body_keys: Object.keys(rawBody).sort(),
      payload_keys: Object.keys(payload).sort(),
      has_payload_json: rawBody.payload_json !== undefined,
      payload_json_type: typeof rawBody.payload_json,
      payload_json_snippet: rawBody.payload_json
        ? String(rawBody.payload_json).slice(0, 200)
        : null,
      warnings: ingestWarnings,
    });
  }

  // Always stamp ingest provenance as zapier to avoid upstream payload source leakage.
  payload.source = "zapier";

  const zapierMeta = {
    zap_id: req.headers.get("X-Zapier-Zap-ID") || null,
    run_id: req.headers.get("X-Zapier-Run-ID") || null,
    timestamp: req.headers.get("X-Zapier-Timestamp") || null,
    source_header: req.headers.get("X-Source") || null,
    idempotency_key: req.headers.get("Idempotency-Key") || null,
  };
  payload._zapier_ingest_meta = zapierMeta;

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
