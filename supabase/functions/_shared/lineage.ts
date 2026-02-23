/**
 * Shared lineage + fire-and-forget utilities.
 *
 * Prevents the Date.now()-in-source_id antipattern (unbounded row growth)
 * and provides a non-blocking invocation wrapper.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type DB = ReturnType<typeof createClient>;

export interface LineageEdge {
  from: string;
  to: string;
  type: string;
}

export interface EmitLineageOpts {
  slug: string;
  version: string;
  edges: LineageEdge[];
  qualifier?: string;
  metadata?: Record<string, unknown>;
}

/**
 * Deterministic lineage source_id — idempotent across re-invocations.
 * Same (slug, version, qualifier) always produces the same key,
 * so onConflict upserts update rather than insert.
 */
export function lineageSourceId(
  slug: string,
  version: string,
  qualifier?: string,
): string {
  return qualifier ? `${slug}:${qualifier}:lineage:${version}` : `${slug}:lineage:${version}`;
}

/**
 * Emit a runtime lineage edge to evidence_events (fire-and-forget).
 * Uses deterministic source_id so re-invocations upsert the same row.
 * Never throws, never blocks the caller.
 */
export function emitLineage(db: DB, opts: EmitLineageOpts): void {
  const sourceId = lineageSourceId(opts.slug, opts.version, opts.qualifier);
  db.from("evidence_events").upsert({
    source_type: "lineage",
    source_id: sourceId,
    source_run_id: `${opts.slug}:${opts.version}`,
    transcript_variant: "baseline",
    metadata: {
      edges: opts.edges,
      pipeline_version: opts.version,
      ...opts.metadata,
    },
  }, { onConflict: "source_type,source_id,transcript_variant" })
    .then(({ error }: { error: { message: string } | null }) => {
      if (error) console.warn(`lineage_emit[${opts.slug}]: ${error.message}`);
    })
    .catch((e: Error) => {
      console.warn(`lineage_emit[${opts.slug}]: ${e.message}`);
    });
}

/**
 * True fire-and-forget — executes async function without blocking caller.
 * Catches and logs errors; never throws.
 */
export function fireAndForget(
  fn: () => Promise<unknown>,
  label: string,
): void {
  fn().catch((e: Error) => console.error(`[${label}] fire-and-forget error:`, e.message));
}
