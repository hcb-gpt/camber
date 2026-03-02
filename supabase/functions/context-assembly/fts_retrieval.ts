/**
 * M2-A: Full-Text Search Retrieval Module
 * ========================================
 *
 * Queries project_facts using Postgres full-text search (plainto_tsquery)
 * against an expression GIN index on to_tsvector('english', search_text).
 *
 * The search_text column is a GENERATED ALWAYS column created by M2-C migration,
 * combining fact_kind + fact_payload fields (feature, value, notes).
 *
 * Feature-flagged via RETRIEVAL_FTS_ENABLED env var (default: false).
 *
 * Time constraints: as_of_at <= t_call AND observed_at <= t_call
 * Same-call exclusion: drops facts sourced from the current interaction.
 *
 * @version 1.0.0
 * @date 2026-02-15
 */

/** A single FTS-matched fact result */
export interface FtsFactResult {
  fact_id: string;
  project_id: string;
  fact_kind: string;
  fact_payload: Record<string, unknown>;
  as_of_at: string;
  observed_at: string;
  fts_rank: number;
  interaction_id: string | null;
  evidence_event_id: string | null;
}

/** Options for the FTS query */
interface FtsQueryOptions {
  /** The span/transcript text to match against */
  span_text: string;
  /** Candidate project IDs to scope to (empty = unscoped) */
  candidate_project_ids: string[];
  /** The call timestamp for time-window filtering */
  t_call: string;
  /** The current interaction_id for same-call exclusion */
  current_interaction_id: string;
  /** Evidence event IDs for the current call (same-call exclusion) */
  current_evidence_event_ids: Set<string>;
  /** Maximum results to return (default 20) */
  limit?: number;
}

// The tsvector expression used in the GIN index (must match migration exactly)
const TSV_EXPR = "to_tsvector('english', pf.search_text)";

/**
 * Run full-text search query against project_facts.
 *
 * Uses plainto_tsquery('english', $span_text) against the expression index
 * on search_text. Applies time-window and same-call exclusion filters.
 *
 * Returns results ordered by ts_rank descending, capped at limit.
 */
export async function queryFtsFacts(
  db: any,
  options: FtsQueryOptions,
): Promise<FtsFactResult[]> {
  const {
    span_text,
    candidate_project_ids,
    t_call,
    current_interaction_id,
    current_evidence_event_ids,
    limit = 20,
  } = options;

  if (!span_text || span_text.trim().length === 0) {
    return [];
  }

  // Truncate span_text to a reasonable size for FTS query generation.
  // plainto_tsquery handles long strings fine but there's no benefit
  // past the point where the query plan is saturated.
  const MAX_QUERY_CHARS = 3000;
  const queryText = span_text.length > MAX_QUERY_CHARS ? span_text.slice(0, MAX_QUERY_CHARS) : span_text;

  // Over-fetch to account for same-call exclusion filtering
  const fetchLimit = limit * 2;

  // Try raw SQL via exec_sql RPC to get ts_rank scoring
  const rpcResult = await queryFtsWithRank(
    db,
    queryText,
    candidate_project_ids,
    t_call,
    fetchLimit,
  );

  if (rpcResult !== null) {
    return applyExclusions(
      rpcResult,
      current_interaction_id,
      current_evidence_event_ids,
      limit,
    );
  }

  // Fallback: use Supabase .textSearch() on search_text (no ts_rank, position-based ranking)
  return await queryFtsFallback(db, options);
}

/**
 * Primary path: use exec_sql RPC to get ts_rank from Postgres.
 * Returns null if RPC is unavailable.
 */
async function queryFtsWithRank(
  db: any,
  queryText: string,
  candidateProjectIds: string[],
  tCall: string,
  fetchLimit: number,
): Promise<FtsFactResult[] | null> {
  let query: string;
  let params: any[];

  if (candidateProjectIds.length > 0) {
    query = `
      SELECT
        pf.id AS fact_id,
        pf.project_id,
        pf.fact_kind,
        pf.fact_payload,
        pf.as_of_at,
        pf.observed_at,
        pf.interaction_id,
        pf.evidence_event_id,
        ts_rank(${TSV_EXPR}, plainto_tsquery('english', $1)) AS fts_rank
      FROM project_facts pf
      WHERE ${TSV_EXPR} @@ plainto_tsquery('english', $1)
        AND pf.project_id = ANY($2)
        AND pf.as_of_at <= $3::timestamptz
        AND pf.observed_at <= $3::timestamptz
      ORDER BY fts_rank DESC
      LIMIT $4
    `;
    params = [queryText, candidateProjectIds, tCall, fetchLimit];
  } else {
    query = `
      SELECT
        pf.id AS fact_id,
        pf.project_id,
        pf.fact_kind,
        pf.fact_payload,
        pf.as_of_at,
        pf.observed_at,
        pf.interaction_id,
        pf.evidence_event_id,
        ts_rank(${TSV_EXPR}, plainto_tsquery('english', $1)) AS fts_rank
      FROM project_facts pf
      WHERE ${TSV_EXPR} @@ plainto_tsquery('english', $1)
        AND pf.as_of_at <= $2::timestamptz
        AND pf.observed_at <= $2::timestamptz
      ORDER BY fts_rank DESC
      LIMIT $3
    `;
    params = [queryText, tCall, fetchLimit];
  }

  const { data, error } = await db.rpc("exec_sql", {
    query,
    params,
  }).catch(() => ({ data: null, error: { message: "rpc_unavailable" } }));

  if (error || !data) return null;

  return (data as any[]).map((row: any) => ({
    fact_id: String(row.fact_id || ""),
    project_id: String(row.project_id),
    fact_kind: String(row.fact_kind),
    fact_payload: row.fact_payload,
    as_of_at: String(row.as_of_at),
    observed_at: String(row.observed_at),
    fts_rank: Number(row.fts_rank) || 0,
    interaction_id: row.interaction_id ? String(row.interaction_id) : null,
    evidence_event_id: row.evidence_event_id ? String(row.evidence_event_id) : null,
  }));
}

/**
 * Fallback query when exec_sql RPC is not available.
 * Uses Supabase PostgREST .textSearch() on the search_text column.
 * PostgREST supports FTS via textSearch() which translates to @@ operator.
 * No ts_rank scoring available so we use position-based ranking.
 */
async function queryFtsFallback(
  db: any,
  options: FtsQueryOptions,
): Promise<FtsFactResult[]> {
  const {
    span_text,
    candidate_project_ids,
    t_call,
    current_interaction_id,
    current_evidence_event_ids,
    limit = 20,
  } = options;

  if (candidate_project_ids.length === 0) return [];

  const fetchLimit = limit * 2;

  const builder = db
    .from("project_facts")
    .select("id, project_id, fact_kind, fact_payload, as_of_at, observed_at, interaction_id, evidence_event_id")
    .in("project_id", candidate_project_ids)
    .lte("as_of_at", t_call)
    .lte("observed_at", t_call)
    .textSearch("search_text", span_text, { type: "plain", config: "english" })
    .order("as_of_at", { ascending: false })
    .limit(fetchLimit);

  const { data: rows, error } = await builder;

  if (error || !rows) return [];

  // Assign position-based rank (1.0 for first, decreasing)
  return applyExclusions(
    (rows as any[]).map((row: any, idx: number) => ({
      fact_id: String(row.id || ""),
      project_id: String(row.project_id),
      fact_kind: String(row.fact_kind),
      fact_payload: row.fact_payload,
      as_of_at: String(row.as_of_at),
      observed_at: String(row.observed_at),
      fts_rank: 1.0 / (1 + idx), // Position-based proxy rank
      interaction_id: row.interaction_id ? String(row.interaction_id) : null,
      evidence_event_id: row.evidence_event_id ? String(row.evidence_event_id) : null,
    })),
    current_interaction_id,
    current_evidence_event_ids,
    limit,
  );
}

/**
 * Apply same-call exclusion filtering and cap results.
 */
function applyExclusions(
  rows: FtsFactResult[],
  currentInteractionId: string,
  currentEvidenceEventIds: Set<string>,
  limit: number,
): FtsFactResult[] {
  const results: FtsFactResult[] = [];
  for (const row of rows) {
    if (row.interaction_id && row.interaction_id === currentInteractionId) continue;
    if (row.evidence_event_id && currentEvidenceEventIds.has(row.evidence_event_id)) continue;
    results.push(row);
    if (results.length >= limit) break;
  }
  return results;
}
