import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "report-data-issue_v1.0.0";
const CONTRACT_VERSION = "report-data-issue_contract_v1";

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-edge-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function metaHeaders(requestId: string): Record<string, string> {
  return {
    "x-request-id": requestId,
    "x-contract-version": CONTRACT_VERSION,
    "x-function-version": FUNCTION_VERSION,
  };
}

function json(
  data: unknown,
  requestId: string,
  status = 200,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
      ...metaHeaders(requestId),
    },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  const requestId = req.headers.get("x-request-id") || crypto.randomUUID();

  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: { ...corsHeaders(), ...metaHeaders(requestId) },
    });
  }

  if (req.method !== "POST") {
    return json({
      ok: false,
      error: "method_not_allowed",
      request_id: requestId,
      contract_version: CONTRACT_VERSION,
      function_version: FUNCTION_VERSION,
    }, requestId, 405);
  }

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    return json({
      ok: false,
      error: "invalid_json",
      request_id: requestId,
      contract_version: CONTRACT_VERSION,
      function_version: FUNCTION_VERSION,
    }, requestId, 400);
  }

  const screen = String(body?.screen || "").trim();
  if (!screen) {
    return json({
      ok: false,
      error: "screen_required",
      request_id: requestId,
      contract_version: CONTRACT_VERSION,
      function_version: FUNCTION_VERSION,
    }, requestId, 400);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({
      ok: false,
      error: "missing_supabase_env",
      request_id: requestId,
      contract_version: CONTRACT_VERSION,
      function_version: FUNCTION_VERSION,
    }, requestId, 500);
  }

  const db = createClient(supabaseUrl, serviceRoleKey);
  const payloadJson = {
    screen,
    contact_id: body?.contact_id ?? null,
    phone: body?.phone ?? null,
    interaction_id: body?.interaction_id ?? null,
    queue_id: body?.queue_id ?? null,
    request_id: body?.request_id ?? null,
    contract_version: body?.contract_version ?? null,
    note: body?.note ?? null,
    app_request_id: requestId,
  };

  const { data, error } = await db
    .from("redline_data_issue_reports")
    .insert({
      screen,
      contact_id: body?.contact_id ?? null,
      phone: body?.phone ?? null,
      interaction_id: body?.interaction_id ?? null,
      queue_id: body?.queue_id ?? null,
      request_id: body?.request_id ?? null,
      contract_version: body?.contract_version ?? null,
      note: body?.note ?? null,
      payload_json: payloadJson,
    })
    .select("id")
    .single();

  if (error) {
    return json({
      ok: false,
      error: error.message,
      request_id: requestId,
      contract_version: CONTRACT_VERSION,
      function_version: FUNCTION_VERSION,
    }, requestId, 500);
  }

  return json({
    ok: true,
    report_id: data?.id ?? null,
    request_id: requestId,
    contract_version: CONTRACT_VERSION,
    function_version: FUNCTION_VERSION,
  }, requestId, 200);
});
