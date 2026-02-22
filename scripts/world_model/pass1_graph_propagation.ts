/**
 * Pass 1 — Graph Propagation ($0 cost)
 *
 * Labels unlabeled spans using graph-based heuristics:
 *   1. Temporal Cluster: for contacts with semi_anchored/drifter fanout,
 *      if a call is within 2 hours of a labeled call from the same contact,
 *      propagate that label (reduced confidence).
 *   2. Sub-Transitivity: if contact B calls within 30 min of contact A's
 *      labeled call and keyword overlap > 60%, propagate A's label.
 *   3. Affinity-Weighted: if correspondent_project_affinity weight > 5.0
 *      for one project and next-highest < 1.0, label as that project.
 *
 * All labels written to labeling_results with pass_number=1.
 * Expected yield: ~10-15% of remaining spans.
 *
 * Usage:
 *   source ~/.camber/credentials.env
 *   deno run --allow-net --allow-env pass1_graph_propagation.ts \
 *     --batch-run-id <id> [--unlabeled-only] [--dry-run]
 */

import { getDb } from "./shared/db.ts";
import { writeLabel, getLabeledSpanIds } from "./shared/label_writer.ts";
import type { UnlabeledSpan, LabelSource, AffinityRow, PassStats } from "./shared/types.ts";

// ============================================================
// CONFIG
// ============================================================

const DRY_RUN = Deno.args.includes("--dry-run");
const UNLABELED_ONLY = Deno.args.includes("--unlabeled-only");

const batchRunIdArg = Deno.args.find((a) => a.startsWith("--batch-run-id="));
const BATCH_RUN_ID = batchRunIdArg?.split("=")[1] || `wm-label-${new Date().toISOString().slice(0,10).replace(/-/g,"")}-pass1`;

// Temporal cluster: 2 hours
const TEMPORAL_CLUSTER_MS = 2 * 60 * 60 * 1000;
// Sub-transitivity: 30 minutes
const SUB_TRANSITIVITY_MS = 30 * 60 * 1000;
// Keyword overlap threshold for sub-transitivity
const KEYWORD_OVERLAP_THRESHOLD = 0.60;
// Affinity dominance thresholds
const AFFINITY_DOMINANT_WEIGHT = 5.0;
const AFFINITY_RUNNER_UP_MAX = 1.0;

const db = getDb();

const stats: PassStats = {
  pass_name: "Graph Propagation",
  pass_number: 1,
  total_input: 0,
  labeled: 0,
  deferred: 0,
  errors: 0,
  detail: {
    temporal_cluster: 0,
    sub_transitivity: 0,
    affinity_weighted: 0,
  },
};

// ============================================================
// DATA LOADING
// ============================================================

interface LabeledSpanRecord {
  span_id: string;
  interaction_id: string;
  project_id: string;
  contact_id: string | null;
  contact_phone: string | null;
  event_at_utc: string | null;
  transcript_segment: string | null;
}

async function getUnlabeledSpans(alreadyLabeled: Set<string>): Promise<UnlabeledSpan[]> {
  // Get all conversation_spans + interaction metadata
  const { data: spans, error } = await db
    .from("conversation_spans")
    .select("id, interaction_id, transcript_segment");

  if (error) {
    console.error("Failed to query conversation_spans:", error.message);
    return [];
  }

  // Get all labeled spans from labeling_results (any batch)
  const { data: allLabeled } = await db
    .from("labeling_results")
    .select("span_id")
    .neq("label_decision", "unlabeled");

  const allLabeledIds = new Set([
    ...(allLabeled || []).map((r: any) => r.span_id),
    ...alreadyLabeled,
  ]);

  const unlabeled = (spans || []).filter((s: any) => !allLabeledIds.has(s.id));

  // Fetch interaction details
  const interactionIds = [...new Set(unlabeled.map((s: any) => s.interaction_id))];
  const interactionMap = new Map<string, any>();

  for (let i = 0; i < interactionIds.length; i += 200) {
    const chunk = interactionIds.slice(i, i + 200);
    const { data: interactions } = await db
      .from("interactions")
      .select("interaction_id, contact_id, contact_phone, contact_name, event_at_utc")
      .in("interaction_id", chunk);
    for (const int of interactions || []) {
      interactionMap.set(int.interaction_id, int);
    }
  }

  return unlabeled.map((s: any) => {
    const int = interactionMap.get(s.interaction_id);
    return {
      span_id: s.id,
      interaction_id: s.interaction_id,
      contact_id: int?.contact_id || null,
      contact_phone: int?.contact_phone || null,
      contact_name: int?.contact_name || null,
      event_at_utc: int?.event_at_utc || null,
      transcript_segment: s.transcript_segment || null,
    };
  });
}

async function getLabeledSpans(): Promise<LabeledSpanRecord[]> {
  // Get all labeled spans from labeling_results
  const { data: labels } = await db
    .from("labeling_results")
    .select("span_id, interaction_id, project_id")
    .eq("label_decision", "assign")
    .not("project_id", "is", null);

  if (!labels || labels.length === 0) return [];

  // Get span transcript_segment
  const spanIds = labels.map((l: any) => l.span_id);
  const spanMap = new Map<string, string | null>();

  for (let i = 0; i < spanIds.length; i += 200) {
    const chunk = spanIds.slice(i, i + 200);
    const { data: spans } = await db
      .from("conversation_spans")
      .select("id, transcript_segment")
      .in("id", chunk);
    for (const s of spans || []) {
      spanMap.set(s.id, s.transcript_segment);
    }
  }

  // Get interaction details
  const interactionIds = [...new Set(labels.map((l: any) => l.interaction_id))];
  const interactionMap = new Map<string, any>();

  for (let i = 0; i < interactionIds.length; i += 200) {
    const chunk = interactionIds.slice(i, i + 200);
    const { data: interactions } = await db
      .from("interactions")
      .select("interaction_id, contact_id, contact_phone, event_at_utc")
      .in("interaction_id", chunk);
    for (const int of interactions || []) {
      interactionMap.set(int.interaction_id, int);
    }
  }

  return labels.map((l: any) => {
    const int = interactionMap.get(l.interaction_id);
    return {
      span_id: l.span_id,
      interaction_id: l.interaction_id,
      project_id: l.project_id,
      contact_id: int?.contact_id || null,
      contact_phone: int?.contact_phone || null,
      event_at_utc: int?.event_at_utc || null,
      transcript_segment: spanMap.get(l.span_id) || null,
    };
  });
}

async function getContactFanoutMap(): Promise<Map<string, { fanout_class: string; effective_fanout: number }>> {
  const { data, error } = await db
    .from("contact_fanout")
    .select("contact_id, fanout_class, effective_fanout");

  if (error) {
    console.warn("Failed to query contact_fanout:", error.message);
    return new Map();
  }

  const map = new Map<string, { fanout_class: string; effective_fanout: number }>();
  for (const row of data || []) {
    map.set(row.contact_id, {
      fanout_class: row.fanout_class,
      effective_fanout: row.effective_fanout,
    });
  }
  return map;
}

async function getAffinityRows(): Promise<AffinityRow[]> {
  const { data, error } = await db
    .from("correspondent_project_affinity")
    .select("contact_id, project_id, weight")
    .gt("weight", 0);

  if (error) {
    console.warn("Failed to query affinity:", error.message);
    return [];
  }

  return (data || []) as AffinityRow[];
}

// ============================================================
// KEYWORD EXTRACTION (for sub-transitivity)
// ============================================================

const STOP_WORDS = new Set([
  "the","a","an","is","are","was","were","be","been","being","have","has",
  "had","do","does","did","will","would","could","should","may","might",
  "shall","can","to","of","in","for","on","with","at","by","from","as",
  "into","about","like","through","after","over","between","out","up",
  "down","just","also","very","so","and","but","or","if","then","that",
  "this","it","its","i","you","we","they","he","she","me","my","your",
  "our","their","him","her","them","what","which","who","where","when",
  "how","all","each","every","both","few","more","most","other","some",
  "such","no","not","only","same","than","too","yeah","yes","no","okay",
  "ok","right","well","um","uh","know","think","got","get","go","going",
  "one","two","three","gonna","gotta","want","need","said","say","tell",
]);

function extractKeywords(text: string | null): Set<string> {
  if (!text) return new Set();
  const words = text.toLowerCase().replace(/[^a-z0-9\s]/g, " ").split(/\s+/);
  const keywords = new Set<string>();
  for (const w of words) {
    if (w.length >= 3 && !STOP_WORDS.has(w)) {
      keywords.add(w);
    }
  }
  return keywords;
}

function keywordOverlap(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let common = 0;
  for (const word of a) {
    if (b.has(word)) common++;
  }
  const minSize = Math.min(a.size, b.size);
  return common / minSize;
}

// ============================================================
// RULES
// ============================================================

/**
 * Rule 1: Temporal Cluster
 * For contacts with semi_anchored/drifter fanout, if a call is within 2 hours
 * of a labeled call from the same contact, propagate that label.
 */
function applyTemporalCluster(
  span: UnlabeledSpan,
  labeledByContact: Map<string, LabeledSpanRecord[]>,
  fanoutMap: Map<string, { fanout_class: string }>,
): { projectId: string; confidence: number; reasoning: string } | null {
  const contactId = span.contact_id;
  if (!contactId || !span.event_at_utc) return null;

  const fanout = fanoutMap.get(contactId);
  if (!fanout) return null;
  if (fanout.fanout_class !== "semi_anchored" && fanout.fanout_class !== "drifter") return null;

  const contactLabeled = labeledByContact.get(contactId);
  if (!contactLabeled || contactLabeled.length === 0) return null;

  const callTime = new Date(span.event_at_utc).getTime();
  if (isNaN(callTime)) return null;

  // Find labeled calls within 2 hours
  let closestDist = Infinity;
  let closestProject = "";
  for (const labeled of contactLabeled) {
    if (!labeled.event_at_utc) continue;
    const labeledTime = new Date(labeled.event_at_utc).getTime();
    const dist = Math.abs(callTime - labeledTime);
    if (dist <= TEMPORAL_CLUSTER_MS && dist < closestDist) {
      closestDist = dist;
      closestProject = labeled.project_id;
    }
  }

  if (!closestProject) return null;

  const minutesAway = Math.round(closestDist / 60000);
  // Confidence: 0.80 base, reduced by 0.10 from pass0 equivalent
  const confidence = Math.max(0.65, 0.80 - (closestDist / TEMPORAL_CLUSTER_MS) * 0.15);

  return {
    projectId: closestProject,
    confidence,
    reasoning: `Temporal cluster: ${fanout.fanout_class} contact had labeled call ${minutesAway}min away`,
  };
}

/**
 * Rule 2: Sub-Transitivity
 * If contact B calls within 30 min of contact A's labeled call and keyword
 * overlap > 60%, propagate A's label.
 */
function applySubTransitivity(
  span: UnlabeledSpan,
  allLabeledSpans: LabeledSpanRecord[],
): { projectId: string; confidence: number; reasoning: string } | null {
  if (!span.event_at_utc || !span.transcript_segment) return null;

  const callTime = new Date(span.event_at_utc).getTime();
  if (isNaN(callTime)) return null;

  const spanKeywords = extractKeywords(span.transcript_segment);
  if (spanKeywords.size < 5) return null; // need enough keywords

  let bestProject = "";
  let bestOverlap = 0;
  let bestMinutes = 0;

  for (const labeled of allLabeledSpans) {
    if (!labeled.event_at_utc || !labeled.transcript_segment) continue;
    // Must be a different contact
    if (labeled.contact_id === span.contact_id) continue;

    const labeledTime = new Date(labeled.event_at_utc).getTime();
    const dist = Math.abs(callTime - labeledTime);
    if (dist > SUB_TRANSITIVITY_MS) continue;

    const labeledKeywords = extractKeywords(labeled.transcript_segment);
    const overlap = keywordOverlap(spanKeywords, labeledKeywords);

    if (overlap >= KEYWORD_OVERLAP_THRESHOLD && overlap > bestOverlap) {
      bestOverlap = overlap;
      bestProject = labeled.project_id;
      bestMinutes = Math.round(dist / 60000);
    }
  }

  if (!bestProject) return null;

  return {
    projectId: bestProject,
    confidence: 0.70,
    reasoning: `Sub-transitivity: ${(bestOverlap * 100).toFixed(0)}% keyword overlap with labeled call ${bestMinutes}min away`,
  };
}

/**
 * Rule 3: Affinity-Weighted Assignment
 * If correspondent_project_affinity weight > 5.0 for one project and
 * next-highest < 1.0, label as that project.
 */
function applyAffinityWeighted(
  span: UnlabeledSpan,
  affinityByContact: Map<string, AffinityRow[]>,
): { projectId: string; confidence: number; reasoning: string } | null {
  const contactId = span.contact_id;
  if (!contactId) return null;

  const affinities = affinityByContact.get(contactId);
  if (!affinities || affinities.length === 0) return null;

  // Sort by weight descending
  const sorted = [...affinities].sort((a, b) => b.weight - a.weight);
  const top = sorted[0];
  const runnerUp = sorted.length > 1 ? sorted[1] : null;

  if (top.weight < AFFINITY_DOMINANT_WEIGHT) return null;
  if (runnerUp && runnerUp.weight >= AFFINITY_RUNNER_UP_MAX) return null;

  return {
    projectId: top.project_id,
    confidence: 0.75,
    reasoning: `Affinity dominance: weight=${top.weight.toFixed(1)}, runner_up=${runnerUp?.weight.toFixed(1) || "none"}`,
  };
}

// ============================================================
// MAIN
// ============================================================

async function main() {
  console.log("=== Pass 1: Graph Propagation ===");
  console.log(`Batch run ID: ${BATCH_RUN_ID}`);
  console.log(`Mode: ${DRY_RUN ? "DRY RUN" : "LIVE"}`);
  console.log(`Unlabeled only: ${UNLABELED_ONLY}`);
  console.log("");

  // Load already-labeled spans in this batch
  const alreadyLabeled = UNLABELED_ONLY
    ? await getLabeledSpanIds(db, BATCH_RUN_ID)
    : new Set<string>();

  // Load data
  console.log("Loading data...");
  const [unlabeled, labeledSpans, fanoutMap, affinityRows] = await Promise.all([
    getUnlabeledSpans(alreadyLabeled),
    getLabeledSpans(),
    getContactFanoutMap(),
    getAffinityRows(),
  ]);

  stats.total_input = unlabeled.length;
  console.log(`Unlabeled spans: ${unlabeled.length}`);
  console.log(`Reference labeled spans: ${labeledSpans.length}`);
  console.log(`Contact fanout entries: ${fanoutMap.size}`);
  console.log(`Affinity rows: ${affinityRows.length}`);

  if (unlabeled.length === 0) {
    console.log("Nothing to do.");
    return;
  }

  // Build indexes
  const labeledByContact = new Map<string, LabeledSpanRecord[]>();
  for (const ls of labeledSpans) {
    if (!ls.contact_id) continue;
    const existing = labeledByContact.get(ls.contact_id) || [];
    existing.push(ls);
    labeledByContact.set(ls.contact_id, existing);
  }

  const affinityByContact = new Map<string, AffinityRow[]>();
  for (const ar of affinityRows) {
    const existing = affinityByContact.get(ar.contact_id) || [];
    existing.push(ar);
    affinityByContact.set(ar.contact_id, existing);
  }

  // Process spans
  console.log("\nProcessing...\n");
  const labeled = new Set<string>();

  for (const span of unlabeled) {
    if (labeled.has(span.span_id)) continue;

    // Rule 1: Temporal Cluster
    const rule1 = applyTemporalCluster(span, labeledByContact, fanoutMap);
    if (rule1) {
      const ok = await writeLabel(db, {
        span_id: span.span_id,
        interaction_id: span.interaction_id,
        project_id: rule1.projectId,
        label_decision: "assign",
        confidence: rule1.confidence,
        label_source: "pass1_temporal_cluster",
        pass_number: 1,
        batch_run_id: BATCH_RUN_ID,
        attribution_lock: "pass1_graph",
      }, DRY_RUN);
      if (ok) {
        stats.detail.temporal_cluster++;
        stats.labeled++;
        labeled.add(span.span_id);
      } else {
        stats.errors++;
      }
      continue;
    }

    // Rule 2: Sub-Transitivity
    const rule2 = applySubTransitivity(span, labeledSpans);
    if (rule2) {
      const ok = await writeLabel(db, {
        span_id: span.span_id,
        interaction_id: span.interaction_id,
        project_id: rule2.projectId,
        label_decision: "assign",
        confidence: rule2.confidence,
        label_source: "pass1_sub_transitivity",
        pass_number: 1,
        batch_run_id: BATCH_RUN_ID,
        attribution_lock: "pass1_graph",
      }, DRY_RUN);
      if (ok) {
        stats.detail.sub_transitivity++;
        stats.labeled++;
        labeled.add(span.span_id);
      } else {
        stats.errors++;
      }
      continue;
    }

    // Rule 3: Affinity-Weighted
    const rule3 = applyAffinityWeighted(span, affinityByContact);
    if (rule3) {
      const ok = await writeLabel(db, {
        span_id: span.span_id,
        interaction_id: span.interaction_id,
        project_id: rule3.projectId,
        label_decision: "assign",
        confidence: rule3.confidence,
        label_source: "pass1_graph_propagation",
        pass_number: 1,
        batch_run_id: BATCH_RUN_ID,
        attribution_lock: "pass1_graph",
      }, DRY_RUN);
      if (ok) {
        stats.detail.affinity_weighted++;
        stats.labeled++;
        labeled.add(span.span_id);
      } else {
        stats.errors++;
      }
      continue;
    }

    stats.deferred++;
  }

  // Report
  console.log("\n=== Pass 1 Results ===");
  console.log(`Total input:         ${stats.total_input}`);
  console.log(`Temporal cluster:    ${stats.detail.temporal_cluster}`);
  console.log(`Sub-transitivity:    ${stats.detail.sub_transitivity}`);
  console.log(`Affinity-weighted:   ${stats.detail.affinity_weighted}`);
  console.log(`Total labeled:       ${stats.labeled}`);
  console.log(`Deferred to Pass 2:  ${stats.deferred}`);
  console.log(`Errors:              ${stats.errors}`);
  if (stats.total_input > 0) {
    console.log(`Yield:               ${((stats.labeled / stats.total_input) * 100).toFixed(1)}%`);
  }
  if (DRY_RUN) {
    console.log("\n[DRY-RUN] No writes were made.");
  }
}

main().catch((err) => {
  console.error("Pass 1 failed:", err);
  Deno.exit(1);
});
