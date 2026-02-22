/**
 * journal-embed-backfill Edge Function v1.0.0
 *
 * Purpose:
 * - Backfill `journal_claims.search_text` + `journal_claims.embedding`
 * - Persist embedding metadata (`embedding_model`, `embedding_version`)
 * - Make `xref_search_journal_claims` immediately usable in production
 *
 * Auth:
 * - Internal only. Requires X-Edge-Secret == EDGE_SHARED_SECRET
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v1.0.1";
const DEFAULT_MODEL = "text-embedding-3-small";
const DEFAULT_EMBEDDING_VERSION = "v1";
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 250;
const DEFAULT_BATCH_SIZE = 20;
const MAX_BATCH_SIZE = 50;
const EMBEDDING_DIMENSIONS = 1536;
const MAX_SEARCH_TEXT_CHARS = 1400;

type ClaimRow = {
  id: string;
  call_id: string | null;
  project_id: string | null;
  claim_type: string | null;
  claim_text: string | null;
  speaker_label: string | null;
  epistemic_status: string | null;
  testimony_type: string | null;
  search_text: string | null;
  embedding: unknown | null;
  embedding_model: string | null;
  embedding_version: string | null;
  created_at: string | null;
};

type FailureClass =
  | "embedding_batch_failed"
  | "embedding_dimension_mismatch"
  | "db_update_failed"
  | "other";

function classifyFailure(errorText: string): FailureClass {
  if (errorText.startsWith("openai_embeddings_") || errorText === "embedding_batch_failed") {
    return "embedding_batch_failed";
  }
  if (errorText.startsWith("embedding_dimension_mismatch_")) {
    return "embedding_dimension_mismatch";
  }
  if (errorText.length > 0) {
    return "db_update_failed";
  }
  return "other";
}

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", "Connection": "keep-alive" },
  });
}

function parseBool(value: unknown, fallback = false): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["1", "true", "yes", "y"].includes(normalized)) return true;
    if (["0", "false", "no", "n"].includes(normalized)) return false;
  }
  return fallback;
}

function parseIntWithBounds(
  value: unknown,
  fallback: number,
  minValue: number,
  maxValue: number,
): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  const rounded = Math.trunc(n);
  if (rounded < minValue) return minValue;
  if (rounded > maxValue) return maxValue;
  return rounded;
}

function normalizeText(input: string | null | undefined): string {
  return (input || "").replace(/\s+/g, " ").trim();
}

function buildSearchText(row: ClaimRow): string {
  const pieces = [
    row.claim_type ? `Claim type: ${normalizeText(row.claim_type)}.` : "",
    row.epistemic_status ? `Status: ${normalizeText(row.epistemic_status)}.` : "",
    row.testimony_type ? `Testimony: ${normalizeText(row.testimony_type)}.` : "",
    row.speaker_label ? `Speaker: ${normalizeText(row.speaker_label)}.` : "",
    normalizeText(row.claim_text),
  ].filter((s) => s.length > 0);

  return normalizeText(pieces.join(" ")).slice(0, MAX_SEARCH_TEXT_CHARS);
}

function toVectorLiteral(embedding: number[]): string {
  return `[${embedding.join(",")}]`;
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
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      input: inputs,
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`openai_embeddings_http_${response.status}: ${text.slice(0, 600)}`);
  }

  const payload = await response.json();
  const data = Array.isArray(payload?.data) ? payload.data : [];
  const sorted = data.slice().sort((a: any, b: any) => (a?.index ?? 0) - (b?.index ?? 0));
  const embeddings: number[][] = [];

  for (const row of sorted) {
    if (!Array.isArray(row?.embedding)) {
      throw new Error("openai_embeddings_invalid_payload: missing embedding array");
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

Deno.serve(async (req: Request) => {
  const startedAt = Date.now();
  const requestId = crypto.randomUUID();
  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse({ ok: false, error: "GET or POST only" }, 405);
  }

  const edgeSecret = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  if (!expectedSecret || edgeSecret !== expectedSecret) {
    return jsonResponse({
      ok: false,
      error: "unauthorized",
      hint: "X-Edge-Secret required",
    }, 401);
  }

  const url = new URL(req.url);
  let body: Record<string, unknown> = {};
  if (req.method === "POST") {
    try {
      body = await req.json();
    } catch {
      body = {};
    }
  }

  const model = String(body.model ?? url.searchParams.get("model") ?? DEFAULT_MODEL).trim();
  const embeddingVersion = String(
    body.embedding_version ??
      body.version ??
      url.searchParams.get("embedding_version") ??
      url.searchParams.get("version") ??
      DEFAULT_EMBEDDING_VERSION,
  ).trim();

  const limit = parseIntWithBounds(
    body.limit ?? url.searchParams.get("limit"),
    DEFAULT_LIMIT,
    1,
    MAX_LIMIT,
  );
  const batchSize = parseIntWithBounds(
    body.batch_size ?? url.searchParams.get("batch_size"),
    DEFAULT_BATCH_SIZE,
    1,
    MAX_BATCH_SIZE,
  );
  const dryRun = parseBool(body.dry_run ?? url.searchParams.get("dry_run"), false);
  const force = parseBool(body.force ?? url.searchParams.get("force"), false);
  const projectId = normalizeText(
    String(body.project_id ?? url.searchParams.get("project_id") ?? ""),
  ) || null;
  const callId = normalizeText(
    String(body.call_id ?? url.searchParams.get("call_id") ?? ""),
  ) || null;

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) {
    return jsonResponse({ ok: false, error: "missing_supabase_env" }, 500);
  }

  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!dryRun && !openaiKey) {
    return jsonResponse({ ok: false, error: "missing_openai_api_key" }, 500);
  }

  const db = createClient(supabaseUrl, serviceRole);

  let countQuery = db
    .from("journal_claims")
    .select("id", { count: "exact", head: true })
    .eq("active", true)
    .not("claim_text", "is", null);

  if (!force) {
    countQuery = countQuery.or("embedding.is.null,search_text.is.null");
  }
  if (projectId) {
    countQuery = countQuery.eq("project_id", projectId);
  }
  if (callId) {
    countQuery = countQuery.eq("call_id", callId);
  }

  const { count: estimatedPending, error: countError } = await countQuery;
  if (countError) {
    console.error("[journal-embed-backfill] count failed:", countError.message);
    return jsonResponse({
      ok: false,
      error: "count_failed",
      detail: countError.message,
    }, 500);
  }

  let rowsQuery = db
    .from("journal_claims")
    .select(
      "id,call_id,project_id,claim_type,claim_text,speaker_label,epistemic_status,testimony_type," +
        "search_text,embedding,embedding_model,embedding_version,created_at",
    )
    .eq("active", true)
    .not("claim_text", "is", null)
    // Prioritize freshest claims so live reliability checks reflect current write health.
    .order("created_at", { ascending: false })
    .limit(limit);

  if (!force) {
    rowsQuery = rowsQuery.or("embedding.is.null,search_text.is.null");
  }
  if (projectId) {
    rowsQuery = rowsQuery.eq("project_id", projectId);
  }
  if (callId) {
    rowsQuery = rowsQuery.eq("call_id", callId);
  }

  const { data: rawRows, error: rowsError } = await rowsQuery;
  if (rowsError) {
    console.error("[journal-embed-backfill] select failed:", rowsError.message);
    return jsonResponse({
      ok: false,
      error: "select_failed",
      detail: rowsError.message,
    }, 500);
  }

  const selectedRows = (rawRows ?? []) as unknown as ClaimRow[];
  const candidateRows = selectedRows.filter((row) => {
    if (!force) return true;
    return (
      !row.embedding ||
      !row.search_text ||
      row.embedding_model !== model ||
      row.embedding_version !== embeddingVersion
    );
  });

  if (candidateRows.length === 0) {
    console.log(
      JSON.stringify({
        event: "journal_embed_backfill_summary",
        request_id: requestId,
        stage_metrics: {
          selected_rows: selectedRows.length,
          candidate_rows: 0,
          prepared_rows: 0,
          batch_count: 0,
          batch_failures: 0,
          update_attempted: 0,
          updated_count: 0,
          failed_count: 0,
        },
        outcome: "no_eligible_claims",
      }),
    );
    return jsonResponse({
      ok: true,
      function_version: FUNCTION_VERSION,
      request_id: requestId,
      model,
      embedding_version: embeddingVersion,
      dry_run: dryRun,
      force,
      limit,
      batch_size: batchSize,
      estimated_pending: estimatedPending || 0,
      selected_rows: 0,
      updated_count: 0,
      failed_count: 0,
      duration_ms: Date.now() - startedAt,
      message: "no_eligible_claims",
    });
  }

  const preparedRows = candidateRows
    .map((row) => ({ row, searchText: buildSearchText(row) }))
    .filter((item) => item.searchText.length > 0);

  if (preparedRows.length === 0) {
    console.warn(
      JSON.stringify({
        event: "journal_embed_backfill_zero_write_warning",
        request_id: requestId,
        reason: "all_candidate_rows_missing_search_text",
        stage_metrics: {
          selected_rows: selectedRows.length,
          candidate_rows: candidateRows.length,
          prepared_rows: 0,
          batch_count: 0,
          batch_failures: 0,
          update_attempted: 0,
          updated_count: 0,
          failed_count: candidateRows.length,
        },
      }),
    );
    return jsonResponse({
      ok: true,
      function_version: FUNCTION_VERSION,
      request_id: requestId,
      model,
      embedding_version: embeddingVersion,
      dry_run: dryRun,
      force,
      limit,
      batch_size: batchSize,
      estimated_pending: estimatedPending || 0,
      selected_rows: candidateRows.length,
      updated_count: 0,
      failed_count: candidateRows.length,
      stage_metrics: {
        selected_rows: selectedRows.length,
        candidate_rows: candidateRows.length,
        prepared_rows: 0,
        batch_count: 0,
        batch_failures: 0,
        update_attempted: 0,
      },
      zero_write_warning: {
        warning: true,
        reason: "all_candidate_rows_missing_search_text",
      },
      duration_ms: Date.now() - startedAt,
      message: "all_candidate_rows_missing_search_text",
    });
  }

  if (dryRun) {
    console.log(
      JSON.stringify({
        event: "journal_embed_backfill_dry_run",
        request_id: requestId,
        stage_metrics: {
          selected_rows: selectedRows.length,
          candidate_rows: candidateRows.length,
          prepared_rows: preparedRows.length,
          batch_count: Math.ceil(preparedRows.length / batchSize),
          batch_failures: 0,
          update_attempted: 0,
          updated_count: 0,
          failed_count: 0,
        },
      }),
    );
    return jsonResponse({
      ok: true,
      function_version: FUNCTION_VERSION,
      request_id: requestId,
      model,
      embedding_version: embeddingVersion,
      dry_run: true,
      force,
      limit,
      batch_size: batchSize,
      estimated_pending: estimatedPending || 0,
      selected_rows: candidateRows.length,
      prepared_rows: preparedRows.length,
      stage_metrics: {
        selected_rows: selectedRows.length,
        candidate_rows: candidateRows.length,
        prepared_rows: preparedRows.length,
        batch_count: Math.ceil(preparedRows.length / batchSize),
        batch_failures: 0,
        update_attempted: 0,
      },
      sample_ids: preparedRows.slice(0, 10).map((r) => r.row.id),
      duration_ms: Date.now() - startedAt,
    });
  }

  const failures: { id: string; error: string }[] = [];
  const failureClassCounts: Record<FailureClass, number> = {
    embedding_batch_failed: 0,
    embedding_dimension_mismatch: 0,
    db_update_failed: 0,
    other: 0,
  };
  let updatedCount = 0;
  let failedCount = 0;
  let batchFailures = 0;
  let updateAttempted = 0;

  for (let i = 0; i < preparedRows.length; i += batchSize) {
    const chunk = preparedRows.slice(i, i + batchSize);
    const inputs = chunk.map((item) => item.searchText);
    let embeddings: number[][];

    try {
      embeddings = await createEmbeddings(openaiKey!, model, inputs);
    } catch (error: any) {
      const detail = error?.message || "embedding_batch_failed";
      batchFailures++;
      const klass = classifyFailure(detail);
      for (const item of chunk) {
        failures.push({ id: item.row.id, error: detail });
        failedCount++;
        failureClassCounts[klass]++;
      }
      continue;
    }

    for (let j = 0; j < chunk.length; j++) {
      const current = chunk[j];
      const embedding = embeddings[j];
      if (!Array.isArray(embedding) || embedding.length !== EMBEDDING_DIMENSIONS) {
        const errorText = `embedding_dimension_mismatch_${embedding?.length ?? "null"}`;
        failures.push({
          id: current.row.id,
          error: errorText,
        });
        failedCount++;
        failureClassCounts[classifyFailure(errorText)]++;
        continue;
      }

      updateAttempted++;
      const { error: updateError } = await db
        .from("journal_claims")
        .update({
          search_text: current.searchText,
          embedding: toVectorLiteral(embedding),
          embedding_model: model,
          embedding_version: embeddingVersion,
        })
        .eq("id", current.row.id);

      if (updateError) {
        failures.push({ id: current.row.id, error: updateError.message });
        failedCount++;
        failureClassCounts[classifyFailure(updateError.message)]++;
      } else {
        updatedCount++;
      }
    }
  }

  const stageMetrics = {
    selected_rows: selectedRows.length,
    candidate_rows: candidateRows.length,
    prepared_rows: preparedRows.length,
    batch_count: Math.ceil(preparedRows.length / batchSize),
    batch_failures: batchFailures,
    update_attempted: updateAttempted,
    updated_count: updatedCount,
    failed_count: failedCount,
  };

  if (preparedRows.length > 0 && updatedCount === 0) {
    console.warn(
      JSON.stringify({
        event: "journal_embed_backfill_zero_write_warning",
        request_id: requestId,
        reason: failedCount > 0 ? "all_updates_failed" : "no_updates_attempted",
        stage_metrics: stageMetrics,
        failure_class_counts: failureClassCounts,
      }),
    );
  } else {
    console.log(
      JSON.stringify({
        event: "journal_embed_backfill_summary",
        request_id: requestId,
        stage_metrics: stageMetrics,
        failure_class_counts: failureClassCounts,
      }),
    );
  }

  return jsonResponse({
    ok: true,
    function_version: FUNCTION_VERSION,
    request_id: requestId,
    model,
    embedding_version: embeddingVersion,
    dry_run: false,
    force,
    limit,
    batch_size: batchSize,
    filters: {
      project_id: projectId,
      call_id: callId,
    },
    estimated_pending: estimatedPending || 0,
    selected_rows: candidateRows.length,
    prepared_rows: preparedRows.length,
    updated_count: updatedCount,
    failed_count: failedCount,
    stage_metrics: stageMetrics,
    failure_class_counts: failureClassCounts,
    zero_write_warning: preparedRows.length > 0 && updatedCount === 0
      ? {
        warning: true,
        reason: failedCount > 0 ? "all_updates_failed" : "no_updates_attempted",
      }
      : {
        warning: false,
      },
    failures: failures.slice(0, 25),
    duration_ms: Date.now() - startedAt,
  });
});
