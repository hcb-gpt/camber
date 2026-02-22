/**
 * RRF (Reciprocal Rank Fusion) module for multi-channel retrieval.
 *
 * Merges results from structured, FTS, trigram, and vector retrieval channels
 * into a single ranked list using the standard RRF formula:
 *   score(d) = SUM(1 / (k + rank_i))  for each channel i where d appears
 *
 * @version 1.0.0
 * @date 2026-02-15
 */

// Re-use existing types from context-assembly
import type { ProjectFactRow } from "./rrf_types.ts";

// ============================================================
// TYPES
// ============================================================

/** Per-channel rank positions for a single candidate fact. */
export interface ChannelRanks {
  structured?: number;
  fts?: number;
  trgm?: number;
  vector?: number;
}

/** A candidate fact from any retrieval channel, with per-channel rank and fused score. */
export interface RankedCandidate {
  fact_id: string;
  project_id: string;
  fact: ProjectFactRow;
  ranks: ChannelRanks;
  rrf_score?: number;
}

/** Result from a single retrieval channel (before fusion). */
export interface ChannelResult {
  channel: keyof ChannelRanks;
  facts: { fact_id: string; project_id: string; fact: ProjectFactRow }[];
}

// ============================================================
// RRF FUSION
// ============================================================

/**
 * Fuse candidates from multiple retrieval channels using Reciprocal Rank Fusion.
 *
 * @param candidates - Array of RankedCandidate with per-channel ranks already set
 * @param k - RRF smoothing constant (default 60, standard value from Cormack et al.)
 * @returns Candidates sorted by descending rrf_score
 */
export function rrfFuse(candidates: RankedCandidate[], k = 60): RankedCandidate[] {
  for (const c of candidates) {
    c.rrf_score = 0;
    for (const rank of Object.values(c.ranks)) {
      if (rank != null) {
        c.rrf_score += 1 / (k + rank);
      }
    }
  }
  return candidates.sort((a, b) => (b.rrf_score ?? 0) - (a.rrf_score ?? 0));
}

/**
 * Merge results from multiple retrieval channels into a unified RankedCandidate array.
 * Deduplicates by fact_id, recording each channel's rank for the same fact.
 *
 * @param channelResults - Results from each active channel
 * @returns Merged candidates with per-channel ranks
 */
export function mergeChannelResults(channelResults: ChannelResult[]): RankedCandidate[] {
  const byFactId = new Map<string, RankedCandidate>();

  for (const cr of channelResults) {
    for (let rank = 0; rank < cr.facts.length; rank++) {
      const item = cr.facts[rank];
      let existing = byFactId.get(item.fact_id);
      if (!existing) {
        existing = {
          fact_id: item.fact_id,
          project_id: item.project_id,
          fact: item.fact,
          ranks: {},
        };
        byFactId.set(item.fact_id, existing);
      }
      // Record 1-based rank for this channel (RRF uses 1-based ranking)
      existing.ranks[cr.channel] = rank + 1;
    }
  }

  return Array.from(byFactId.values());
}

/**
 * Full RRF pipeline: merge channel results, fuse, return top-N.
 *
 * @param channelResults - Results from each active retrieval channel
 * @param topN - Max results to return (default 20)
 * @param k - RRF smoothing constant (default 60)
 * @returns Top-N candidates sorted by RRF score
 */
export function rrfPipeline(
  channelResults: ChannelResult[],
  topN = 20,
  k = 60,
): RankedCandidate[] {
  const merged = mergeChannelResults(channelResults);
  const fused = rrfFuse(merged, k);
  return fused.slice(0, topN);
}
