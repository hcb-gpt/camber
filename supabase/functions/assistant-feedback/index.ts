import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "assistant-feedback_v1.0.0";

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type, x-request-id",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function json(data: unknown, status = 200, requestId?: string): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders(),
      "Content-Type": "application/json",
      ...(requestId ? { "x-request-id": requestId } : {}),
      "x-function-version": FUNCTION_VERSION,
    },
  });
}

function toStringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed", request_id: requestId }, 405, requestId);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json({ ok: false, error: "missing_supabase_config", request_id: requestId }, 500, requestId);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json", request_id: requestId }, 400, requestId);
  }

  const messageId = toStringOrNull(body.message_id);
  const messageRole = toStringOrNull(body.message_role);
  const feedback = toStringOrNull(body.feedback);
  if (!messageId || !messageRole || !feedback) {
    return json({ ok: false, error: "missing_required_fields", request_id: requestId }, 400, requestId);
  }

  const note = toStringOrNull(body.note);
  const upstreamRequestId = toStringOrNull(body.request_id) ?? requestId;
  const contactIdRaw = toStringOrNull(body.contact_id);
  const projectIdRaw = toStringOrNull(body.project_id);
  const prompt = toStringOrNull(body.prompt);
  const responseExcerpt = toStringOrNull(body.response_excerpt);

  const contactId = contactIdRaw && isValidUUID(contactIdRaw) ? contactIdRaw : null;
  const projectId = projectIdRaw && isValidUUID(projectIdRaw) ? projectIdRaw : null;

  const db = createClient(supabaseUrl, serviceKey);
  const { data, error } = await db
    .from("assistant_feedback")
    .insert({
      message_id: messageId,
      message_role: messageRole,
      feedback,
      note,
      request_id: upstreamRequestId,
      contact_id: contactId,
      project_id: projectId,
      prompt,
      response_excerpt: responseExcerpt,
    })
    .select("id")
    .maybeSingle();

  if (error) {
    return json(
      { ok: false, error: error.message, request_id: upstreamRequestId },
      500,
      requestId,
    );
  }

  return json(
    { ok: true, feedback_id: data?.id ?? null, request_id: upstreamRequestId },
    200,
    requestId,
  );
});

