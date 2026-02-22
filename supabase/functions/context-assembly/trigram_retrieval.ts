/**
 * M2-B: Trigram Fuzzy Matching Retrieval Module
 * ==============================================
 *
 * Queries project_facts using pg_trgm similarity (%) operator
 * against the shared search_text generated column (created by M2-C migration).
 *
 * Feature-flagged via RETRIEVAL_TRGM_ENABLED env var (default: false).
 *
 * Time constraints: as_of_at <= t_call AND observed_at <= t_call
 * Same-call exclusion: drops facts sourced from the current interaction.
 *
 * @version 1.0.0
 * @date 2026-02-15
 */

/** A single trigram-matched fact result */
export interface TrigramFactResult {
  project_id: string;
  fact_kind: string;
  fact_payload: any;
  as_of_at: string;
  observed_at: string;
  trgm_score: number;
  interaction_id: string | null;
  evidence_event_id: string | null;
}

/** Options for the trigram query */
interface TrigramQueryOptions {
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

/**
 * Run trigram similarity query against project_facts.
 *
 * Uses the % operator (pg_trgm similarity threshold, default 0.3)
 * with the GIN trigram index on search_text.
 *
 * Returns results ranked by trgm_score descending, with same-call
 * exclusion applied.
 */
export async function queryTrigramFacts(
  db: any,
  options: TrigramQueryOptions,
): Promise<TrigramFactResult[]> {
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

  // Truncate span_text to avoid excessive query payload (pg_trgm handles long strings
  // but there's no benefit past a certain length for similarity matching)
  const MAX_QUERY_CHARS = 2000;
  const queryText = span_text.length > MAX_QUERY_CHARS ? span_text.slice(0, MAX_QUERY_CHARS) : span_text;

  // Build the raw SQL query using pg_trgm similarity function.
  // The % operator uses the GIN trigram index on search_text.
  // We fetch more than needed to allow for same-call exclusion filtering.
  const fetchLimit = limit * 2;

  let query: string;
  let params: any[];

  if (candidate_project_ids.length > 0) {
    // Scoped to candidate projects
    query = `
      SELECT
        pf.project_id,
        pf.fact_kind,
        pf.fact_payload,
        pf.as_of_at,
        pf.observed_at,
        pf.interaction_id,
        pf.evidence_event_id,
        similarity(pf.search_text, $1) AS trgm_score
      FROM project_facts pf
      WHERE pf.search_text % $1
        AND pf.project_id = ANY($2)
        AND pf.as_of_at <= $3::timestamptz
        AND pf.observed_at <= $3::timestamptz
      ORDER BY trgm_score DESC
      LIMIT $4
    `;
    params = [queryText, candidate_project_ids, t_call, fetchLimit];
  } else {
    // Unscoped (all projects)
    query = `
      SELECT
        pf.project_id,
        pf.fact_kind,
        pf.fact_payload,
        pf.as_of_at,
        pf.observed_at,
        pf.interaction_id,
        pf.evidence_event_id,
        similarity(pf.search_text, $1) AS trgm_score
      FROM project_facts pf
      WHERE pf.search_text % $1
        AND pf.as_of_at <= $2::timestamptz
        AND pf.observed_at <= $2::timestamptz
      ORDER BY trgm_score DESC
      LIMIT $3
    `;
    params = [queryText, t_call, fetchLimit];
  }

  const { data, error } = await db.rpc("exec_sql", {
    query,
    params,
  }).catch(() => ({ data: null, error: { message: "rpc_unavailable" } }));

  // Fallback: if exec_sql RPC is not available, use Supabase PostgREST with raw filter.
  // This is a best-effort approach since PostgREST doesn't natively support pg_trgm.
  if (error || !data) {
    // Try direct Supabase query as fallback (limited: no similarity scoring).
    // This won't use the trigram index but provides some functionality.
    return await queryTrigramFallback(db, options);
  }

  // Apply same-call exclusion and return
  const results: TrigramFactResult[] = [];
  for (const row of (data as any[])) {
    const rowInteractionId = row.interaction_id ? String(row.interaction_id) : null;
    const rowEvidenceEventId = row.evidence_event_id ? String(row.evidence_event_id) : null;

    // Same-call exclusion
    if (rowInteractionId && rowInteractionId === current_interaction_id) continue;
    if (rowEvidenceEventId && current_evidence_event_ids.has(rowEvidenceEventId)) continue;

    results.push({
      project_id: String(row.project_id),
      fact_kind: String(row.fact_kind),
      fact_payload: row.fact_payload,
      as_of_at: String(row.as_of_at),
      observed_at: String(row.observed_at),
      trgm_score: Number(row.trgm_score) || 0,
      interaction_id: rowInteractionId,
      evidence_event_id: rowEvidenceEventId,
    });

    if (results.length >= limit) break;
  }

  return results;
}

/**
 * Fallback query when exec_sql RPC is not available.
 * Fetches project_facts for candidate projects with time constraints,
 * then computes trigram-like similarity in JS.
 */
async function queryTrigramFallback(
  db: any,
  options: TrigramQueryOptions,
): Promise<TrigramFactResult[]> {
  const {
    span_text,
    candidate_project_ids,
    t_call,
    current_interaction_id,
    current_evidence_event_ids,
    limit = 20,
  } = options;

  if (candidate_project_ids.length === 0) return [];

  const fetchLimit = limit * 3;

  const { data: rows, error } = await db
    .from("project_facts")
    .select(
      "project_id, fact_kind, fact_payload, as_of_at, observed_at, interaction_id, evidence_event_id, search_text",
    )
    .in("project_id", candidate_project_ids)
    .lte("as_of_at", t_call)
    .lte("observed_at", t_call)
    .order("as_of_at", { ascending: false })
    .limit(fetchLimit);

  if (error || !rows) return [];

  // Compute simple JS-based trigram similarity as fallback
  const queryTrigrams = computeTrigrams(span_text.toLowerCase().slice(0, 2000));

  const scored: TrigramFactResult[] = [];
  for (const row of rows as any[]) {
    const rowInteractionId = row.interaction_id ? String(row.interaction_id) : null;
    const rowEvidenceEventId = row.evidence_event_id ? String(row.evidence_event_id) : null;

    if (rowInteractionId && rowInteractionId === current_interaction_id) continue;
    if (rowEvidenceEventId && current_evidence_event_ids.has(rowEvidenceEventId)) continue;

    // Use search_text if available (generated column), else reconstruct
    const factText = row.search_text ? String(row.search_text).toLowerCase() : [
      String(row.fact_kind),
      (row.fact_payload || {}).feature || "",
      (row.fact_payload || {}).value != null ? String((row.fact_payload || {}).value) : "",
      (row.fact_payload || {}).notes || "",
    ].join(" ").toLowerCase();
    const factTrigrams = computeTrigrams(factText);
    const score = trigramSimilarity(queryTrigrams, factTrigrams);

    if (score >= 0.15) {
      scored.push({
        project_id: String(row.project_id),
        fact_kind: String(row.fact_kind),
        fact_payload: row.fact_payload,
        as_of_at: String(row.as_of_at),
        observed_at: String(row.observed_at),
        trgm_score: Math.round(score * 1000) / 1000,
        interaction_id: rowInteractionId,
        evidence_event_id: rowEvidenceEventId,
      });
    }
  }

  scored.sort((a, b) => b.trgm_score - a.trgm_score);
  return scored.slice(0, limit);
}

/** Compute set of trigrams from a string (matching pg_trgm behavior). */
function computeTrigrams(text: string): Set<string> {
  const padded = "  " + text + " ";
  const trigrams = new Set<string>();
  for (let i = 0; i <= padded.length - 3; i++) {
    trigrams.add(padded.slice(i, i + 3));
  }
  return trigrams;
}

/** Compute Jaccard-like trigram similarity (matches pg_trgm's similarity()). */
function trigramSimilarity(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let intersection = 0;
  for (const t of a) {
    if (b.has(t)) intersection++;
  }
  const union = a.size + b.size - intersection;
  return union === 0 ? 0 : intersection / union;
}
