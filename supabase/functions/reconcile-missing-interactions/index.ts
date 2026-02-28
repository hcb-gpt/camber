import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "reconcile-missing-interactions_v1.0.0";
const CONTRACT_VERSION = "reconcile-missing-interactions_contract_v1";

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

function json(data: unknown, requestId: string, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
      ...metaHeaders(requestId),
    },
  });
}

function clampLimit(value: unknown): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 200;
  return Math.min(1000, Math.max(1, Math.floor(parsed)));
}

type ReconcileResult = {
  scanned_count: number;
  inserted_count: number;
  inserted_interaction_ids: string[];
};

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

  const dryRun = body?.dry_run === true;
  const limit = clampLimit(body?.limit);

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

  if (dryRun) {
    const { data: candidates, error: candidatesErr } = await db
      .from("calls_raw")
      .select("interaction_id,event_at_utc,ingested_at_utc")
      .eq("is_shadow", false)
      .not("interaction_id", "is", null)
      .order("ingested_at_utc", { ascending: false, nullsFirst: false })
      .limit(limit);
    if (candidatesErr) {
      return json({
        ok: false,
        error: candidatesErr.message,
        request_id: requestId,
        contract_version: CONTRACT_VERSION,
        function_version: FUNCTION_VERSION,
      }, requestId, 500);
    }

    const interactionIds = (candidates || [])
      .map((row: any) => String(row.interaction_id || ""))
      .filter((value) => value.length > 0);
    const uniqueIds = [...new Set(interactionIds)];

    const existingSet = new Set<string>();
    const chunkSize = 200;
    for (let i = 0; i < uniqueIds.length; i += chunkSize) {
      const chunk = uniqueIds.slice(i, i + chunkSize);
      const { data: existingRows, error: existingErr } = await db
        .from("interactions")
        .select("interaction_id")
        .in("interaction_id", chunk);
      if (existingErr) {
        return json({
          ok: false,
          error: existingErr.message,
          request_id: requestId,
          contract_version: CONTRACT_VERSION,
          function_version: FUNCTION_VERSION,
        }, requestId, 500);
      }
      for (const row of existingRows || []) {
        const interactionId = String((row as any).interaction_id || "");
        if (interactionId) existingSet.add(interactionId);
      }
    }

    const missing = uniqueIds.filter((interactionId) => !existingSet.has(interactionId));

    return json({
      ok: true,
      dry_run: true,
      requested_limit: limit,
      scanned_count: uniqueIds.length,
      missing_count: missing.length,
      sample_missing_interaction_ids: missing.slice(0, 20),
      request_id: requestId,
      contract_version: CONTRACT_VERSION,
      function_version: FUNCTION_VERSION,
    }, requestId, 200);
  }

  const { data, error } = await db.rpc("reconcile_calls_raw_to_interactions", {
    p_limit: limit,
  });
  if (error) {
    return json({
      ok: false,
      error: error.message,
      request_id: requestId,
      contract_version: CONTRACT_VERSION,
      function_version: FUNCTION_VERSION,
    }, requestId, 500);
  }

  const result: ReconcileResult | null = Array.isArray(data)
    ? (data[0] as ReconcileResult | null)
    : (data as ReconcileResult | null);

  return json({
    ok: true,
    dry_run: false,
    requested_limit: limit,
    scanned_count: result?.scanned_count ?? 0,
    inserted_count: result?.inserted_count ?? 0,
    inserted_interaction_ids: result?.inserted_interaction_ids ?? [],
    request_id: requestId,
    contract_version: CONTRACT_VERSION,
    function_version: FUNCTION_VERSION,
  }, requestId, 200);
});
