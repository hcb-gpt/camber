#!/usr/bin/env -S deno run --allow-env --allow-net --allow-read
/**
 * Redline iOS Learning Loop — Queue Forcing-State Mix (v1)
 *
 * Purpose:
 *   Replace "opinions" with a single decision-relevant datapoint:
 *   what mix of forcing states is currently arriving in the triage queue.
 *
 * Why this matters:
 *   The iOS truth surface should prioritize the dominant forcing state.
 *
 * Usage:
 *   deno run --allow-env --allow-net --allow-read scripts/triage_queue_bucket_mix_v1.ts
 *   deno run --allow-env --allow-net --allow-read scripts/triage_queue_bucket_mix_v1.ts --json
 *   deno run --allow-env --allow-net --allow-read scripts/triage_queue_bucket_mix_v1.ts --limit 100 --max-age-days 21
 */

import { parse } from "https://deno.land/std@0.224.0/flags/mod.ts";

type Bucket = "PICK_REQUIRED" | "FAST_CONFIRM" | "NEEDS_SPLIT" | "PIPELINE_DEFECT";

type TruthGraphLane =
  | "process-call"
  | "segment-call"
  | "ai-router"
  | "journal"
  | "sms-ingest"
  | "unknown";

type TruthGraphResponse = {
  ok: boolean;
  interaction_id?: string;
  lane?: TruthGraphLane;
  hydration?: Record<string, boolean>;
};

type QueueItem = {
  id: string;
  span_id: string;
  interaction_id: string;
  reason_codes?: string[];
  reasons?: string[];
  confidence?: number | null;
  ai_guess_project_id?: string | null;
  context_payload?: Record<string, unknown> | null;
};

type QueueResponse = {
  ok: boolean;
  items?: QueueItem[];
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
const flags = parse(Deno.args, {
  boolean: ["json", "skip-truth-graph", "help"],
  string: ["fast-confirm-threshold"],
  default: {
    json: false,
    "skip-truth-graph": false,
    help: false,
    limit: 100,
    "max-age-days": 21,
    "fast-confirm-threshold": "0.92",
  },
});

if (flags.help) {
  console.log(`
Queue Forcing-State Mix (v1)

FLAGS:
  --limit N                 Queue fetch limit (default: 100; edge clamps to 100)
  --max-age-days N          Freshness window (default: 21)
  --fast-confirm-threshold  Confidence threshold for FAST_CONFIRM (default: 0.92)
  --skip-truth-graph        Skip truth_graph calls (faster, less accurate)
  --json                    JSON output only
  --help                    Show help
`);
  Deno.exit(0);
}

const limit = Math.min(Math.max(Number(flags.limit) || 100, 1), 100);
const maxAgeDays = Math.min(Math.max(Number(flags["max-age-days"]) || 21, 1), 365);
const fastConfirmThreshold = Math.min(
  Math.max(Number(flags["fast-confirm-threshold"]) || 0.92, 0.0),
  1.0,
);
const skipTruthGraph = Boolean(flags["skip-truth-graph"]);

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------
function requireEnv(key: string): string {
  const val = Deno.env.get(key);
  if (!val) throw new Error(`Missing required env var: ${key}`);
  return val;
}

async function loadCredentials(): Promise<void> {
  const credPath = `${Deno.env.get("HOME")}/.camber/credentials.env`;
  try {
    const text = await Deno.readTextFile(credPath);
    for (const line of text.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eqIdx = trimmed.indexOf("=");
      if (eqIdx < 0) continue;
      const key = trimmed.slice(0, eqIdx).replace(/^export\s+/, "").trim();
      let val = trimmed.slice(eqIdx + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      if (!Deno.env.get(key)) Deno.env.set(key, val);
    }
  } catch {
    // ok: env must be pre-set via `source scripts/load-env.sh`
  }
}

await loadCredentials();

const SUPABASE_URL = requireEnv("SUPABASE_URL").replace(/\/$/, "");
const ANON_KEY = String(Deno.env.get("SUPABASE_ANON_KEY") || "").trim();
const EDGE_SECRET = String(Deno.env.get("EDGE_SHARED_SECRET") || "").trim();

if (!ANON_KEY && !EDGE_SECRET) {
  throw new Error("Missing auth: set SUPABASE_ANON_KEY (preferred) or EDGE_SHARED_SECRET.");
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
async function fetchJson<T>(url: string): Promise<T> {
  const headers: Record<string, string> = {};
  // Prefer anon key for read-only metrics; allow edge secret as fallback.
  if (ANON_KEY) {
    headers.Authorization = `Bearer ${ANON_KEY}`;
    headers.apikey = ANON_KEY;
  }
  if (EDGE_SECRET) {
    headers["X-Edge-Secret"] = EDGE_SECRET;
  }
  const resp = await fetch(url, {
    headers,
  });
  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    throw new Error(`HTTP ${resp.status} from ${url}: ${body.slice(0, 300)}`);
  }
  return await resp.json() as T;
}

function isNeedsSplit(item: QueueItem): boolean {
  const codes = new Set(
    [...(item.reason_codes || []), ...(item.reasons || [])]
      .map((c) => String(c || "").trim().toLowerCase())
      .filter(Boolean),
  );
  const needsSplitCodes = new Set([
    "needs_split",
    "multi_project",
    "multi_project_span",
    "multi_project_detected",
  ]);
  for (const code of codes) {
    if (needsSplitCodes.has(code)) return true;
  }
  const taxonomy = String((item.context_payload || {})["taxonomy_state"] || "").trim().toUpperCase();
  return taxonomy === "NEEDS_SPLIT";
}

function hasWeakAnchor(item: QueueItem): boolean {
  const codes = new Set(
    [...(item.reason_codes || []), ...(item.reasons || [])]
      .map((c) => String(c || "").trim().toLowerCase())
      .filter(Boolean),
  );
  return codes.has("weak_anchor");
}

function decideBucket(
  item: QueueItem,
  truthGraph: TruthGraphResponse | null,
): Bucket {
  if (truthGraph && truthGraph.ok) {
    const lane = String(truthGraph.lane || "unknown").trim() as TruthGraphLane;
    // Only hard-block on lanes that imply the human can't safely label because
    // key substrate is missing (raw/spans/attributions). Journal gaps are a
    // reliability concern but should not block learning-loop writes.
    const blockingDefectLanes = new Set<TruthGraphLane>([
      "process-call",
      "segment-call",
      "ai-router",
    ]);
    if (blockingDefectLanes.has(lane)) return "PIPELINE_DEFECT";
  }

  if (isNeedsSplit(item)) return "NEEDS_SPLIT";

  const confidence = typeof item.confidence === "number" ? item.confidence : null;
  const hasGuess = Boolean(String(item.ai_guess_project_id || "").trim());

  if (hasGuess && confidence !== null && confidence >= fastConfirmThreshold && !hasWeakAnchor(item)) {
    return "FAST_CONFIRM";
  }

  return "PICK_REQUIRED";
}

function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.floor(p * (sorted.length - 1))));
  return sorted[idx];
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const nowUtc = new Date().toISOString();

const queueUrl = `${SUPABASE_URL}/functions/v1/bootstrap-review?action=queue&limit=${limit}&max_age_days=${maxAgeDays}`;
const queue = await fetchJson<QueueResponse>(queueUrl);

if (!queue.ok) {
  throw new Error(`bootstrap-review queue returned ok=false (url=${queueUrl})`);
}

const items = (queue.items || []).filter((it) => it && it.id && it.interaction_id);
const interactionIds = [...new Set(items.map((it) => it.interaction_id))];

const truthByInteraction = new Map<string, TruthGraphResponse>();
if (!skipTruthGraph) {
  const concurrency = 6;
  let i = 0;
  const workers = Array.from({ length: Math.min(concurrency, interactionIds.length) }, async () => {
    while (true) {
      const idx = i++;
      if (idx >= interactionIds.length) return;
      const interactionId = interactionIds[idx];
      const tgUrl =
        `${SUPABASE_URL}/functions/v1/redline-thread?action=truth_graph&interaction_id=${encodeURIComponent(interactionId)}&refresh=1&_ts=${
          Date.now()
        }`;
      try {
        const tg = await fetchJson<TruthGraphResponse>(tgUrl);
        truthByInteraction.set(interactionId, tg);
      } catch (err) {
        truthByInteraction.set(interactionId, { ok: false, interaction_id: interactionId, lane: "unknown" });
        // Keep going; the script is meant to be decision-support, not fragile.
        if (!flags.json) {
          console.warn(`[warn] truth_graph fetch failed for ${interactionId}: ${(err as Error).message}`);
        }
      }
    }
  });
  await Promise.all(workers);
}

const bucketCounts: Record<Bucket, number> = {
  PICK_REQUIRED: 0,
  FAST_CONFIRM: 0,
  NEEDS_SPLIT: 0,
  PIPELINE_DEFECT: 0,
};

const reasonCounts = new Map<string, number>();
const truthLaneCounts = new Map<string, number>(); // per interaction id
let truthFetchFailedInteractions = 0;
let truthJournalMissingInteractions = 0;
const confs: number[] = [];

if (!skipTruthGraph) {
  for (const interactionId of interactionIds) {
    const tg = truthByInteraction.get(interactionId);
    if (!tg || !tg.ok) {
      truthFetchFailedInteractions += 1;
      continue;
    }
    const lane = String(tg.lane || "unknown").trim();
    truthLaneCounts.set(lane, (truthLaneCounts.get(lane) || 0) + 1);
    if (lane === "journal") truthJournalMissingInteractions += 1;
  }
}

for (const item of items) {
  const perItemCodes = new Set(
    [...(item.reason_codes || []), ...(item.reasons || [])]
      .map((raw) => String(raw || "").trim().toLowerCase())
      .filter(Boolean),
  );
  for (const code of perItemCodes) {
    reasonCounts.set(code, (reasonCounts.get(code) || 0) + 1);
  }
  if (typeof item.confidence === "number") confs.push(item.confidence);

  const tg = truthByInteraction.get(item.interaction_id) || null;
  const bucket = decideBucket(item, tg);
  bucketCounts[bucket] += 1;
}

const total = items.length;
const pickRequiredRate = total > 0 ? bucketCounts.PICK_REQUIRED / total : 0;
const defectRate = total > 0 ? bucketCounts.PIPELINE_DEFECT / total : 0;
const needsSplitRate = total > 0 ? bucketCounts.NEEDS_SPLIT / total : 0;
const truthGraphInteractionCount = skipTruthGraph ? 0 : interactionIds.length;
const truthGraphFetchFailedRate = truthGraphInteractionCount > 0
  ? truthFetchFailedInteractions / truthGraphInteractionCount
  : 0;

let decision = "No items returned; treat as empty queue or freshness-filtered.";
if (total > 0) {
  if (!skipTruthGraph && truthGraphInteractionCount > 0 && truthGraphFetchFailedRate > 0.05) {
    decision =
      "Truth-graph fetch failures are elevated; rerun before acting on defect-rate guidance (picker-first anti-anchoring is still safe to pursue).";
  } else
  if (defectRate > 0.02) {
    decision = "Prioritize pipeline repair + truth-graph defect UX before attribution UX polish.";
  } else if (needsSplitRate > 0.05) {
    decision = "Prioritize NEEDS_SPLIT forcing path (v1 hard-block, v2 interactive split).";
  } else if (pickRequiredRate > 0.5) {
    decision = "Prioritize picker-first anti-anchoring UX (no preselect, no confirm swipe under weak anchors).";
  } else if (bucketCounts.FAST_CONFIRM > 0) {
    decision = "Ship FAST_CONFIRM 1-gesture flow + QA sampling; keep receipts-only, no reasoning.";
  } else {
    decision = "Mixed queue; prioritize the largest bucket and keep truth-graph gating in place.";
  }
}

const summary = {
  ok: true,
  captured_at_utc: nowUtc,
  params: {
    limit,
    max_age_days: maxAgeDays,
    fast_confirm_threshold: fastConfirmThreshold,
    truth_graph: skipTruthGraph ? "skipped" : "enabled",
  },
  queue: {
    items: total,
    bucket_counts: bucketCounts,
    bucket_rates: total > 0
      ? {
        PICK_REQUIRED: bucketCounts.PICK_REQUIRED / total,
        FAST_CONFIRM: bucketCounts.FAST_CONFIRM / total,
        NEEDS_SPLIT: bucketCounts.NEEDS_SPLIT / total,
        PIPELINE_DEFECT: bucketCounts.PIPELINE_DEFECT / total,
      }
      : null,
    reason_code_counts: Object.fromEntries([...reasonCounts.entries()].sort((a, b) => b[1] - a[1])),
    truth_graph: skipTruthGraph
      ? null
      : {
        lane_counts: Object.fromEntries([...truthLaneCounts.entries()].sort((a, b) => b[1] - a[1])),
        interaction_count: truthGraphInteractionCount,
        journal_missing_interactions: truthJournalMissingInteractions,
        fetch_failed_interactions: truthFetchFailedInteractions,
        fetch_failed_rate: truthGraphInteractionCount > 0 ? truthGraphFetchFailedRate : null,
      },
    confidence: {
      count: confs.length,
      max: confs.length ? Math.max(...confs) : null,
      p50: percentile(confs, 0.50),
      p90: percentile(confs, 0.90),
    },
  },
  decision,
};

if (flags.json) {
  console.log(JSON.stringify(summary, null, 2));
} else {
  console.log(`Captured: ${summary.captured_at_utc}`);
  console.log(`Queue items: ${summary.queue.items}`);
  console.log("Bucket counts:");
  console.log(`  PICK_REQUIRED: ${bucketCounts.PICK_REQUIRED}`);
  console.log(`  FAST_CONFIRM: ${bucketCounts.FAST_CONFIRM}`);
  console.log(`  NEEDS_SPLIT: ${bucketCounts.NEEDS_SPLIT}`);
  console.log(`  PIPELINE_DEFECT: ${bucketCounts.PIPELINE_DEFECT}`);
  if (summary.queue.confidence.count > 0) {
    console.log(
      `Confidence: count=${summary.queue.confidence.count}, max=${summary.queue.confidence.max}, p50=${summary.queue.confidence.p50}, p90=${summary.queue.confidence.p90}`,
    );
  }
  if (summary.queue.truth_graph) {
    console.log("Truth graph lanes (non-blocking + blocking mix):");
    for (const [lane, count] of Object.entries(summary.queue.truth_graph.lane_counts)) {
      console.log(`  ${lane}: ${count}`);
    }
    if (summary.queue.truth_graph.fetch_failed_interactions > 0) {
      console.log(
        `  truth_graph_fetch_failed_interactions: ${summary.queue.truth_graph.fetch_failed_interactions} (${Math.round(((summary.queue.truth_graph.fetch_failed_rate || 0) * 100) * 10) / 10}%)`,
      );
    }
  }
  console.log("Reason code counts:");
  for (const [code, count] of Object.entries(summary.queue.reason_code_counts)) {
    console.log(`  ${code}: ${count}`);
  }
  console.log("");
  console.log(`DECISION: ${decision}`);
}
