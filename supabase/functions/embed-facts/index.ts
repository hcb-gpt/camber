/**
 * embed-facts Edge Function v1.0.0
 *
 * Purpose:
 * - Embed project_facts rows using OpenAI text-embedding-3-small (1536-dim)
 * - Supports backfill (all rows with NULL embedding) and single-fact modes
 * - Rate-limited: batches of 10 with 100ms inter-batch delay
 *
 * Auth:
 * - Internal only. Requires X-Edge-Secret == EDGE_SHARED_SECRET
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { emitLineage } from "../_shared/lineage.ts";

const FUNCTION_VERSION = "v1.0.0";
const DEFAULT_MODEL = "text-embedding-3-small";
const EMBEDDING_DIMENSIONS = 1536;
const BATCH_SIZE = 10;
const BATCH_DELAY_MS = 100;

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-edge-secret, x-source",
    },
  });
}

function toVectorLiteral(embedding: number[]): string {
  return `[${embedding.join(",")}]`;
}

function composeText(fact_kind: string, fact_payload: unknown): string {
  return `${fact_kind}: ${JSON.stringify(fact_payload)}`;
}

async function createEmbeddings(
  apiKey: string,
  model: string,
  inputs: string[],
): Promise<number[][]> {
  const response = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({ model, input: inputs }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `openai_embeddings_http_${response.status}: ${text.slice(0, 600)}`,
    );
  }

  const payload = await response.json();
  const data = Array.isArray(payload?.data) ? payload.data : [];
  const sorted = data
    .slice()
    .sort((a: any, b: any) => (a?.index ?? 0) - (b?.index ?? 0));
  const embeddings: number[][] = [];

  for (const row of sorted) {
    if (!Array.isArray(row?.embedding)) {
      throw new Error(
        "openai_embeddings_invalid_payload: missing embedding array",
      );
    }
    embeddings.push(row.embedding as number[]);
  }

  if (embeddings.length !== inputs.length) {
    throw new Error(
      `openai_embeddings_count_mismatch: expected=${inputs.length} actual=${embeddings.length}`,
    );
  }

  return embeddings;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return jsonResponse({ ok: true }, 200);
  }

  const startedAt = Date.now();

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "POST only" }, 405);
  }

  // Auth gate
  const edgeSecret = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  if (!expectedSecret || edgeSecret !== expectedSecret) {
    return jsonResponse(
      { ok: false, error: "unauthorized", hint: "X-Edge-Secret required" },
      401,
    );
  }

  // Parse body
  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const mode = String(body.mode || "backfill").trim();
  const factId = body.fact_id ? String(body.fact_id).trim() : null;

  if (mode !== "backfill" && mode !== "single") {
    return jsonResponse(
      {
        ok: false,
        error: "invalid_mode",
        hint: 'mode must be "backfill" or "single"',
      },
      400,
    );
  }

  if (mode === "single" && !factId) {
    return jsonResponse(
      { ok: false, error: "missing_fact_id", hint: "single mode requires fact_id" },
      400,
    );
  }

  // Env checks
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) {
    return jsonResponse({ ok: false, error: "missing_supabase_env" }, 500);
  }

  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) {
    return jsonResponse({ ok: false, error: "missing_openai_api_key" }, 500);
  }

  const db = createClient(supabaseUrl, serviceRole);

  // Fetch rows needing embedding
  let query = db
    .from("project_facts")
    .select("id, fact_kind, fact_payload")
    .is("embedding", null)
    .order("created_at", { ascending: true });

  if (mode === "single" && factId) {
    query = query.eq("id", factId);
  }

  // Cap backfill to 500 rows per invocation to stay within edge function time limits
  query = query.limit(500);

  const { data: rows, error: selectError } = await query;
  if (selectError) {
    console.error("[embed-facts] select failed:", selectError.message);
    return jsonResponse(
      { ok: false, error: "select_failed", detail: selectError.message },
      500,
    );
  }

  const facts = (rows ?? []) as Array<{
    id: string;
    fact_kind: string;
    fact_payload: unknown;
  }>;

  if (facts.length === 0) {
    return jsonResponse({
      ok: true,
      function_version: FUNCTION_VERSION,
      mode,
      processed: 0,
      errors: [],
      duration_ms: Date.now() - startedAt,
      message: "no_facts_to_embed",
    });
  }

  // Process in batches
  let processed = 0;
  const errors: Array<{ id: string; error: string }> = [];

  for (let i = 0; i < facts.length; i += BATCH_SIZE) {
    const batch = facts.slice(i, i + BATCH_SIZE);
    const texts = batch.map((f) => composeText(f.fact_kind, f.fact_payload));

    let embeddings: number[][];
    try {
      embeddings = await createEmbeddings(openaiKey, DEFAULT_MODEL, texts);
    } catch (err: any) {
      const detail = err?.message || "embedding_batch_failed";
      for (const fact of batch) {
        errors.push({ id: fact.id, error: detail });
      }
      continue;
    }

    for (let j = 0; j < batch.length; j++) {
      const fact = batch[j];
      const embedding = embeddings[j];

      if (
        !Array.isArray(embedding) ||
        embedding.length !== EMBEDDING_DIMENSIONS
      ) {
        errors.push({
          id: fact.id,
          error: `embedding_dimension_mismatch_${embedding?.length ?? "null"}`,
        });
        continue;
      }

      const { error: updateError } = await db
        .from("project_facts")
        .update({
          embedding: toVectorLiteral(embedding),
          embedding_model: DEFAULT_MODEL,
          embedding_version: FUNCTION_VERSION,
        })
        .eq("id", fact.id);

      if (updateError) {
        errors.push({ id: fact.id, error: updateError.message });
      } else {
        processed++;
      }
    }

    // Rate limit: delay between batches (skip after last batch)
    if (i + BATCH_SIZE < facts.length) {
      await sleep(BATCH_DELAY_MS);
    }
  }

  // RUNTIME LINEAGE (fire-and-forget via shared helper)
  emitLineage(db, {
    slug: "embed-facts",
    version: FUNCTION_VERSION,
    edges: [
      { from: "edge:embed-facts", to: "table:public.project_facts", type: "reads" },
      { from: "edge:embed-facts", to: "table:public.project_facts", type: "writes" },
    ],
  });

  return jsonResponse({
    ok: true,
    function_version: FUNCTION_VERSION,
    mode,
    processed,
    errors: errors.slice(0, 50),
    total_selected: facts.length,
    error_count: errors.length,
    duration_ms: Date.now() - startedAt,
  });
});
