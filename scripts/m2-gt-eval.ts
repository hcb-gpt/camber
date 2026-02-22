#!/usr/bin/env -S deno run --allow-all
/**
 * M2 GT Evaluation Harness
 *
 * Measures attribution accuracy against the 86-span GT sample,
 * with support for toggling M2 retrieval features (FTS, trigram, vector).
 *
 * Usage:
 *   deno run --allow-all scripts/m2-gt-eval.ts
 *   deno run --allow-all scripts/m2-gt-eval.ts --fts --trigram --vector
 *   deno run --allow-all scripts/m2-gt-eval.ts --baseline /path/to/prior/run.json
 *   deno run --allow-all scripts/m2-gt-eval.ts --gt-file artifacts/gt/batches/gt_batch_v1_baseline86.csv
 *   deno run --allow-all scripts/m2-gt-eval.ts --mode snapshot   # read current DB state only
 *   deno run --allow-all scripts/m2-gt-eval.ts --mode reseed     # reseed through pipeline
 *
 * Env vars required (from ~/.camber/credentials.env):
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, EDGE_SHARED_SECRET
 *   DATABASE_URL (for psql queries; optional — falls back to REST API)
 */

import { parse } from "https://deno.land/std@0.224.0/flags/mod.ts";
import { parse as parseCsv } from "https://deno.land/std@0.224.0/csv/mod.ts";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------
const flags = parse(Deno.args, {
  boolean: ["fts", "trigram", "vector", "help", "json"],
  string: ["gt-file", "baseline", "mode", "out-dir"],
  default: {
    fts: false,
    trigram: false,
    vector: false,
    help: false,
    json: false,
    "gt-file": "artifacts/gt/batches/gt_batch_v1_baseline86.csv",
    mode: "snapshot", // snapshot | reseed
    "out-dir": "",
  },
});

if (flags.help) {
  console.log(`
M2 GT Evaluation Harness — Measures attribution accuracy against ground truth.

FLAGS:
  --fts           Enable FTS retrieval phase measurement
  --trigram       Enable trigram retrieval phase measurement
  --vector        Enable vector retrieval phase measurement
  --gt-file PATH  Path to GT batch CSV (default: artifacts/gt/batches/gt_batch_v1_baseline86.csv)
  --baseline PATH Path to prior run JSON for delta comparison
  --mode MODE     snapshot (read DB state) or reseed (re-run pipeline)
  --out-dir PATH  Output directory (default: artifacts/gt/runs/m2_eval_<timestamp>)
  --json          Output JSON only (no human-readable summary)
  --help          Show this help
`);
  Deno.exit(0);
}

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------
function requireEnv(key: string): string {
  const val = Deno.env.get(key);
  if (!val) throw new Error(`Missing required env var: ${key}`);
  return val;
}

// Try loading credentials from file
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
      // Strip quotes
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      if (!Deno.env.get(key)) {
        Deno.env.set(key, val);
      }
    }
  } catch {
    // credentials file not found — env must be pre-set
  }
}

await loadCredentials();

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SERVICE_ROLE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const EDGE_SECRET = requireEnv("EDGE_SHARED_SECRET");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
interface GtRow {
  row_id: string;
  interaction_id: string;
  span_index: number;
  span_id: string;
  expected_project_id: string;
  expected_project_name_contains: string;
  expected_decision: string;
  notes: string;
  tags: string;
}

interface SpanResult {
  row_id: string;
  interaction_id: string;
  span_index: number;
  expected_project: string;
  expected_decision: string;
  predicted_project_id: string;
  predicted_project_name: string;
  predicted_decision: string;
  predicted_confidence: number;
  is_correct: boolean;
  retrieval_phases: PhaseResult[];
  candidate_count: number;
  candidate_rank: number | null; // rank of GT project among candidates
  model_id: string;
  prompt_version: string;
  reason_codes: string;
  error: string;
}

interface PhaseResult {
  phase: string;     // structured | fts | trigram | vector | rrf_fused
  enabled: boolean;
  candidates_returned: number;
  gt_project_found: boolean;
  gt_project_rank: number | null;
  latency_ms: number;
}

interface RunSummary {
  run_id: string;
  run_started_at_utc: string;
  run_completed_at_utc: string;
  mode: string;
  feature_flags: {
    fts_enabled: boolean;
    trigram_enabled: boolean;
    vector_enabled: boolean;
  };
  gt_file: string;
  total_spans: number;
  headline: {
    overall_accuracy: number;
    assign_accuracy: number;
    review_rate: number;
    none_rate: number;
    staff_leak_rate: number;
    recall_at_20: number;
    precision_at_20: number;
  };
  phase_stats: Record<string, {
    enabled: boolean;
    avg_candidates: number;
    gt_found_rate: number;
    avg_gt_rank: number | null;
  }>;
  per_project: Record<string, { tp: number; fp: number; fn: number; precision: number; recall: number; f1: number }>;
  failures: SpanResult[];
  baseline_delta: DeltaReport | null;
}

interface DeltaReport {
  baseline_file: string;
  accuracy_delta_pp: number;
  review_rate_delta_pp: number;
  recall_at_20_delta_pp: number;
  precision_at_20_delta_pp: number;
  per_phase_delta: Record<string, { gt_found_rate_delta_pp: number }>;
}

// ---------------------------------------------------------------------------
// GT CSV loader
// ---------------------------------------------------------------------------
async function loadGtBatch(path: string): Promise<GtRow[]> {
  const text = await Deno.readTextFile(path);
  const records = parseCsv(text, { skipFirstRow: true }) as Record<string, string>[];
  return records.map((r, i) => ({
    row_id: r.row_id || `row_${String(i + 1).padStart(4, "0")}`,
    interaction_id: r.interaction_id || "",
    span_index: parseInt(r.span_index || "0", 10),
    span_id: r.span_id || "",
    expected_project_id: r.expected_project_id || "",
    expected_project_name_contains: (r.expected_project_name_contains || r.expected_project || "").toLowerCase(),
    expected_decision: (r.expected_decision || "").toLowerCase(),
    notes: r.notes || "",
    tags: r.tags || "",
  }));
}

// ---------------------------------------------------------------------------
// Supabase REST helper
// ---------------------------------------------------------------------------
async function supabaseRpc(fnName: string, payload: Record<string, unknown>): Promise<{ status: number; body: unknown }> {
  const url = `${SUPABASE_URL}/rest/v1/rpc/${fnName}`;
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
    body: JSON.stringify(payload),
  });
  const body = await resp.json().catch(() => null);
  return { status: resp.status, body };
}

async function callEdgeFunction(slug: string, payload: Record<string, unknown>): Promise<{ status: number; body: any }> {
  const url = `${SUPABASE_URL}/functions/v1/${slug}`;
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "X-Edge-Secret": EDGE_SECRET,
      "X-Source": "m2-gt-eval",
    },
    body: JSON.stringify(payload),
  });
  const body = await resp.json().catch(() => ({ error: "json_parse_failed" }));
  return { status: resp.status, body };
}

// ---------------------------------------------------------------------------
// Supabase REST query helper (uses PostgREST)
// ---------------------------------------------------------------------------
async function querySpanAttribution(interactionId: string, spanIndex: number): Promise<{
  span_id: string;
  project_id: string;
  project_name: string;
  decision: string;
  confidence: number;
  model_id: string;
  prompt_version: string;
  reason_codes: string;
}> {
  // Step 1: Find the span
  const spanUrl = `${SUPABASE_URL}/rest/v1/conversation_spans?interaction_id=eq.${interactionId}&span_index=eq.${spanIndex}&is_superseded=eq.false&order=created_at.desc&limit=1`;
  const spanResp = await fetch(spanUrl, {
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
  });
  const spans = await spanResp.json();
  if (!Array.isArray(spans) || spans.length === 0) {
    return { span_id: "", project_id: "", project_name: "", decision: "", confidence: 0, model_id: "", prompt_version: "", reason_codes: "" };
  }
  const spanId = spans[0].id;

  // Step 2: Find the latest attribution for this span
  const attrUrl = `${SUPABASE_URL}/rest/v1/span_attributions?span_id=eq.${spanId}&order=attributed_at.desc.nullslast,id.desc&limit=1`;
  const attrResp = await fetch(attrUrl, {
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
  });
  const attrs = await attrResp.json();
  if (!Array.isArray(attrs) || attrs.length === 0) {
    return { span_id: spanId, project_id: "", project_name: "", decision: "", confidence: 0, model_id: "", prompt_version: "", reason_codes: "" };
  }
  const attr = attrs[0];

  // Step 3: Get project name
  let projectName = "";
  if (attr.project_id) {
    const projUrl = `${SUPABASE_URL}/rest/v1/projects?id=eq.${attr.project_id}&select=name&limit=1`;
    const projResp = await fetch(projUrl, {
      headers: {
        apikey: SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      },
    });
    const projs = await projResp.json();
    if (Array.isArray(projs) && projs.length > 0) {
      projectName = projs[0].name || "";
    }
  }

  return {
    span_id: spanId,
    project_id: attr.project_id || "",
    project_name: projectName,
    decision: (attr.decision || "").toLowerCase(),
    confidence: parseFloat(attr.confidence) || 0,
    model_id: attr.model_id || "",
    prompt_version: attr.prompt_version || "",
    reason_codes: JSON.stringify(attr.reason_codes || attr.needs_review || ""),
  };
}

// ---------------------------------------------------------------------------
// Reseed a single interaction through the pipeline
// ---------------------------------------------------------------------------
async function reseedInteraction(interactionId: string, runId: string): Promise<{ ok: boolean; error: string; latency_ms: number }> {
  const t0 = Date.now();
  const { status, body } = await callEdgeFunction("admin-reseed", {
    interaction_id: interactionId,
    mode: "resegment_and_reroute",
    idempotency_key: `m2-gt-eval-${runId}-${interactionId}`,
    reason: "m2_gt_eval_harness",
    requested_by: "gt-eval",
    feature_flags: {
      RETRIEVAL_FTS_ENABLED: flags.fts,
      RETRIEVAL_TRGM_ENABLED: flags.trigram,
      RETRIEVAL_VECTOR_ENABLED: flags.vector,
    },
  });
  const latency = Date.now() - t0;
  if (status === 200 && body?.ok) {
    return { ok: true, error: "", latency_ms: latency };
  }
  return { ok: false, error: body?.error || `http_${status}`, latency_ms: latency };
}

// ---------------------------------------------------------------------------
// Evaluate context-assembly retrieval phases for a span
// ---------------------------------------------------------------------------
async function evalRetrievalPhases(spanId: string, gtProject: string): Promise<PhaseResult[]> {
  if (!spanId) return [];

  const phases: PhaseResult[] = [];

  // Call context-assembly to get the context_package
  const t0 = Date.now();
  const { status, body } = await callEdgeFunction("context-assembly", {
    span_id: spanId,
    feature_flags: {
      RETRIEVAL_FTS_ENABLED: flags.fts,
      RETRIEVAL_TRGM_ENABLED: flags.trigram,
      RETRIEVAL_VECTOR_ENABLED: flags.vector,
    },
  });
  const latency = Date.now() - t0;

  if (status !== 200 || !body?.context_package) {
    phases.push({
      phase: "structured",
      enabled: true,
      candidates_returned: 0,
      gt_project_found: false,
      gt_project_rank: null,
      latency_ms: latency,
    });
    return phases;
  }

  const pkg = body.context_package;
  const candidates = pkg.candidates || [];
  const meta = pkg.meta || {};
  const sourcesUsed: string[] = meta.sources_used || [];

  // Each candidate has a `sources` array (list of source names that contributed it).
  // We classify candidates by which retrieval channel surfaced them.
  const hasFtsSource = (c: any) => {
    const s = (c.sources || [c.source || ""]).join(",").toLowerCase();
    return s.includes("fts");
  };
  const hasTrgmSource = (c: any) => {
    const s = (c.sources || [c.source || ""]).join(",").toLowerCase();
    return s.includes("trgm") || s.includes("trigram");
  };
  const hasVectorSource = (c: any) => {
    const s = (c.sources || [c.source || ""]).join(",").toLowerCase();
    return s.includes("vector");
  };
  const isStructuredSource = (c: any) => !hasFtsSource(c) && !hasTrgmSource(c) && !hasVectorSource(c);

  // Structured retrieval (always enabled) — the baseline candidate set
  const structuredCandidates = candidates.filter(isStructuredSource);
  const structuredRank = findGtRank(structuredCandidates, gtProject);
  phases.push({
    phase: "structured",
    enabled: true,
    candidates_returned: structuredCandidates.length,
    gt_project_found: structuredRank !== null,
    gt_project_rank: structuredRank,
    latency_ms: latency,
  });

  // FTS phase
  const ftsCandidates = candidates.filter(hasFtsSource);
  phases.push({
    phase: "fts",
    enabled: flags.fts || sourcesUsed.some((s) => s.includes("fts")),
    candidates_returned: ftsCandidates.length,
    gt_project_found: findGtRank(ftsCandidates, gtProject) !== null,
    gt_project_rank: findGtRank(ftsCandidates, gtProject),
    latency_ms: 0,
  });

  // Trigram phase
  const trigramCandidates = candidates.filter(hasTrgmSource);
  phases.push({
    phase: "trigram",
    enabled: flags.trigram || sourcesUsed.some((s) => s.includes("trgm") || s.includes("trigram")),
    candidates_returned: trigramCandidates.length,
    gt_project_found: findGtRank(trigramCandidates, gtProject) !== null,
    gt_project_rank: findGtRank(trigramCandidates, gtProject),
    latency_ms: 0,
  });

  // Vector phase
  const vectorCandidates = candidates.filter(hasVectorSource);
  phases.push({
    phase: "vector",
    enabled: flags.vector || sourcesUsed.some((s) => s.includes("vector")),
    candidates_returned: vectorCandidates.length,
    gt_project_found: findGtRank(vectorCandidates, gtProject) !== null,
    gt_project_rank: findGtRank(vectorCandidates, gtProject),
    latency_ms: 0,
  });

  // RRF fused — the full candidate list after fusion
  const fusedRank = findGtRank(candidates, gtProject);
  phases.push({
    phase: "rrf_fused",
    enabled: true,
    candidates_returned: candidates.length,
    gt_project_found: fusedRank !== null,
    gt_project_rank: fusedRank,
    latency_ms: 0,
  });

  return phases;
}

function findGtRank(candidates: any[], gtProject: string): number | null {
  if (!gtProject || gtProject === "none") return null;
  const gtLower = gtProject.toLowerCase();
  for (let i = 0; i < candidates.length; i++) {
    const name = (candidates[i].project_name || candidates[i].name || "").toLowerCase();
    if (name.includes(gtLower) || gtLower.includes(name.replace(/\s+residence$/, ""))) {
      return i + 1; // 1-indexed rank
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Correctness check
// ---------------------------------------------------------------------------
function checkCorrectness(row: GtRow, predicted: { project_name: string; decision: string; project_id: string }): boolean {
  const expectedDecision = row.expected_decision;
  const expectedProjectName = row.expected_project_name_contains;
  const expectedProjectId = row.expected_project_id;

  if (!expectedDecision && !expectedProjectName && !expectedProjectId) return true; // no expectation

  const actualDecision = predicted.decision;
  const actualProjectName = predicted.project_name.toLowerCase();
  const actualProjectId = predicted.project_id;

  let ok = true;
  if (expectedDecision && actualDecision !== expectedDecision) ok = false;
  if (expectedProjectId && actualProjectId !== expectedProjectId) ok = false;
  if (expectedProjectName && !actualProjectName.includes(expectedProjectName)) ok = false;

  return ok;
}

// ---------------------------------------------------------------------------
// Compute aggregate metrics
// ---------------------------------------------------------------------------
function computeMetrics(results: SpanResult[]): RunSummary["headline"] {
  const total = results.length;
  if (total === 0) {
    return { overall_accuracy: 0, assign_accuracy: 0, review_rate: 0, none_rate: 0, staff_leak_rate: 0, recall_at_20: 0, precision_at_20: 0 };
  }

  const correct = results.filter((r) => r.is_correct).length;
  const assignResults = results.filter((r) => r.predicted_decision === "assign");
  const assignCorrect = assignResults.filter((r) => r.is_correct).length;
  const reviewCount = results.filter((r) => r.predicted_decision === "review").length;
  const noneCount = results.filter((r) => r.predicted_decision === "none" || !r.predicted_decision).length;
  const staffLeaks = results.filter((r) => r.predicted_project_name.toLowerCase().includes("sittler")).length;

  // recall@20 and precision@20: of spans that have a GT project (not 'none'),
  // how many had the GT project in the top 20 candidates?
  const withGtProject = results.filter((r) => r.expected_project && r.expected_project !== "none");
  const gtFoundInCandidates = withGtProject.filter((r) => r.candidate_rank !== null && r.candidate_rank <= 20).length;
  const recall20 = withGtProject.length > 0 ? gtFoundInCandidates / withGtProject.length : 0;

  // precision@20: of candidate slots used, how many pointed to the correct GT project?
  // Simplified: same as recall for this use case (1 correct per span)
  const precision20 = recall20;

  return {
    overall_accuracy: correct / total,
    assign_accuracy: assignResults.length > 0 ? assignCorrect / assignResults.length : 0,
    review_rate: reviewCount / total,
    none_rate: noneCount / total,
    staff_leak_rate: staffLeaks / total,
    recall_at_20: recall20,
    precision_at_20: precision20,
  };
}

function computePerProject(results: SpanResult[]): RunSummary["per_project"] {
  const projects = new Map<string, { tp: number; fp: number; fn: number }>();

  for (const r of results) {
    const expected = r.expected_project || "none";
    const predicted = r.predicted_project_name.toLowerCase().replace(/\s+residence$/, "") || "none";

    if (!projects.has(expected)) projects.set(expected, { tp: 0, fp: 0, fn: 0 });
    if (!projects.has(predicted)) projects.set(predicted, { tp: 0, fp: 0, fn: 0 });

    if (expected === predicted || (expected !== "none" && predicted.includes(expected))) {
      projects.get(expected)!.tp++;
    } else {
      if (expected !== "none") projects.get(expected)!.fn++;
      if (predicted !== "none") projects.get(predicted)!.fp++;
    }
  }

  const result: RunSummary["per_project"] = {};
  for (const [name, stats] of projects) {
    const precision = stats.tp + stats.fp > 0 ? stats.tp / (stats.tp + stats.fp) : 0;
    const recall = stats.tp + stats.fn > 0 ? stats.tp / (stats.tp + stats.fn) : 0;
    const f1 = precision + recall > 0 ? (2 * precision * recall) / (precision + recall) : 0;
    result[name] = { ...stats, precision, recall, f1 };
  }
  return result;
}

function computePhaseStats(results: SpanResult[]): RunSummary["phase_stats"] {
  const phases = ["structured", "fts", "trigram", "vector", "rrf_fused"];
  const stats: RunSummary["phase_stats"] = {};

  for (const phaseName of phases) {
    const phaseResults = results.flatMap((r) => r.retrieval_phases.filter((p) => p.phase === phaseName));
    if (phaseResults.length === 0) {
      stats[phaseName] = { enabled: phaseName === "structured" || phaseName === "rrf_fused", avg_candidates: 0, gt_found_rate: 0, avg_gt_rank: null };
      continue;
    }

    const enabled = phaseResults[0]?.enabled ?? false;
    const avgCandidates = phaseResults.reduce((s, p) => s + p.candidates_returned, 0) / phaseResults.length;
    const withGt = phaseResults.filter((p) => p.gt_project_rank !== null);
    const gtFoundRate = phaseResults.length > 0 ? withGt.length / phaseResults.length : 0;
    const avgRank = withGt.length > 0 ? withGt.reduce((s, p) => s + (p.gt_project_rank || 0), 0) / withGt.length : null;

    stats[phaseName] = { enabled, avg_candidates: avgCandidates, gt_found_rate: gtFoundRate, avg_gt_rank: avgRank };
  }
  return stats;
}

// ---------------------------------------------------------------------------
// Delta comparison
// ---------------------------------------------------------------------------
async function loadBaseline(path: string): Promise<RunSummary | null> {
  try {
    const text = await Deno.readTextFile(path);
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function computeDelta(current: RunSummary, baseline: RunSummary, baselinePath: string): DeltaReport {
  const delta: DeltaReport = {
    baseline_file: baselinePath,
    accuracy_delta_pp: (current.headline.overall_accuracy - baseline.headline.overall_accuracy) * 100,
    review_rate_delta_pp: (current.headline.review_rate - baseline.headline.review_rate) * 100,
    recall_at_20_delta_pp: (current.headline.recall_at_20 - baseline.headline.recall_at_20) * 100,
    precision_at_20_delta_pp: (current.headline.precision_at_20 - baseline.headline.precision_at_20) * 100,
    per_phase_delta: {},
  };

  for (const phase of Object.keys(current.phase_stats)) {
    const cur = current.phase_stats[phase];
    const base = baseline.phase_stats?.[phase];
    if (base) {
      delta.per_phase_delta[phase] = {
        gt_found_rate_delta_pp: (cur.gt_found_rate - base.gt_found_rate) * 100,
      };
    }
  }
  return delta;
}

// ---------------------------------------------------------------------------
// Report formatting
// ---------------------------------------------------------------------------
function formatReport(summary: RunSummary): string {
  const lines: string[] = [];
  lines.push("# M2 GT Evaluation Report");
  lines.push("");
  lines.push("## Metadata");
  lines.push(`- run_id: \`${summary.run_id}\``);
  lines.push(`- started: ${summary.run_started_at_utc}`);
  lines.push(`- completed: ${summary.run_completed_at_utc}`);
  lines.push(`- mode: ${summary.mode}`);
  lines.push(`- gt_file: ${summary.gt_file}`);
  lines.push(`- total_spans: ${summary.total_spans}`);
  lines.push("");

  lines.push("## Feature Flags");
  lines.push(`- FTS:     ${summary.feature_flags.fts_enabled ? "ENABLED" : "disabled"}`);
  lines.push(`- Trigram: ${summary.feature_flags.trigram_enabled ? "ENABLED" : "disabled"}`);
  lines.push(`- Vector:  ${summary.feature_flags.vector_enabled ? "ENABLED" : "disabled"}`);
  lines.push("");

  lines.push("## Headline Metrics");
  const h = summary.headline;
  lines.push(`| Metric | Value |`);
  lines.push(`|--------|-------|`);
  lines.push(`| Overall Accuracy | **${(h.overall_accuracy * 100).toFixed(1)}%** |`);
  lines.push(`| Assign Accuracy | ${(h.assign_accuracy * 100).toFixed(1)}% |`);
  lines.push(`| Review Rate | ${(h.review_rate * 100).toFixed(1)}% |`);
  lines.push(`| None Rate | ${(h.none_rate * 100).toFixed(1)}% |`);
  lines.push(`| Staff Leak Rate | ${(h.staff_leak_rate * 100).toFixed(1)}% |`);
  lines.push(`| Recall@20 | ${(h.recall_at_20 * 100).toFixed(1)}% |`);
  lines.push(`| Precision@20 | ${(h.precision_at_20 * 100).toFixed(1)}% |`);
  lines.push("");

  lines.push("## Retrieval Phase Stats");
  lines.push(`| Phase | Enabled | Avg Candidates | GT Found Rate | Avg GT Rank |`);
  lines.push(`|-------|---------|----------------|---------------|-------------|`);
  for (const [phase, s] of Object.entries(summary.phase_stats)) {
    lines.push(`| ${phase} | ${s.enabled ? "yes" : "no"} | ${s.avg_candidates.toFixed(1)} | ${(s.gt_found_rate * 100).toFixed(1)}% | ${s.avg_gt_rank?.toFixed(1) ?? "N/A"} |`);
  }
  lines.push("");

  lines.push("## Per-Project Performance");
  lines.push(`| Project | TP | FP | FN | Precision | Recall | F1 |`);
  lines.push(`|---------|---:|---:|---:|----------:|-------:|---:|`);
  const sorted = Object.entries(summary.per_project).sort((a, b) => b[1].tp - a[1].tp);
  for (const [name, s] of sorted) {
    lines.push(`| ${name} | ${s.tp} | ${s.fp} | ${s.fn} | ${(s.precision * 100).toFixed(1)}% | ${(s.recall * 100).toFixed(1)}% | ${(s.f1 * 100).toFixed(1)}% |`);
  }
  lines.push("");

  if (summary.baseline_delta) {
    const d = summary.baseline_delta;
    lines.push("## Delta vs Baseline");
    lines.push(`- Baseline file: \`${d.baseline_file}\``);
    lines.push(`- Accuracy delta: **${d.accuracy_delta_pp >= 0 ? "+" : ""}${d.accuracy_delta_pp.toFixed(1)}pp**`);
    lines.push(`- Review rate delta: ${d.review_rate_delta_pp >= 0 ? "+" : ""}${d.review_rate_delta_pp.toFixed(1)}pp`);
    lines.push(`- Recall@20 delta: ${d.recall_at_20_delta_pp >= 0 ? "+" : ""}${d.recall_at_20_delta_pp.toFixed(1)}pp`);
    lines.push(`- Precision@20 delta: ${d.precision_at_20_delta_pp >= 0 ? "+" : ""}${d.precision_at_20_delta_pp.toFixed(1)}pp`);
    lines.push("");
    lines.push("### Per-Phase Delta");
    lines.push(`| Phase | GT Found Rate Delta |`);
    lines.push(`|-------|---------------------|`);
    for (const [phase, pd] of Object.entries(d.per_phase_delta)) {
      lines.push(`| ${phase} | ${pd.gt_found_rate_delta_pp >= 0 ? "+" : ""}${pd.gt_found_rate_delta_pp.toFixed(1)}pp |`);
    }
    lines.push("");
  }

  if (summary.failures.length > 0) {
    lines.push("## Top Failures (up to 10)");
    lines.push(`| interaction_id | span | expected | predicted | decision | confidence | error |`);
    lines.push(`|----------------|------|----------|-----------|----------|------------|-------|`);
    for (const f of summary.failures.slice(0, 10)) {
      lines.push(`| ${f.interaction_id} | ${f.span_index} | ${f.expected_project} | ${f.predicted_project_name} | ${f.predicted_decision} | ${f.predicted_confidence.toFixed(2)} | ${f.error} |`);
    }
    lines.push("");
  }

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main(): Promise<void> {
  const runId = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "").replace("T", "T").replace("Z", "Z");
  const startedAt = new Date().toISOString();

  console.log(`M2 GT Evaluation Harness`);
  console.log(`Run ID: ${runId}`);
  console.log(`Mode: ${flags.mode}`);
  console.log(`Feature flags: FTS=${flags.fts} TRIGRAM=${flags.trigram} VECTOR=${flags.vector}`);
  console.log(`GT file: ${flags["gt-file"]}`);
  console.log("");

  // Load GT data
  const gtRows = await loadGtBatch(flags["gt-file"]);
  console.log(`Loaded ${gtRows.length} GT rows`);

  // If reseed mode, reseed unique interactions first
  const uniqueInteractions = [...new Set(gtRows.map((r) => r.interaction_id))];
  if (flags.mode === "reseed") {
    console.log(`\nReseeding ${uniqueInteractions.length} interactions...`);
    for (const iid of uniqueInteractions) {
      const result = await reseedInteraction(iid, runId);
      const status = result.ok ? "OK" : `FAIL: ${result.error}`;
      console.log(`  ${iid}: ${status} (${result.latency_ms}ms)`);
      // Rate limit: 250ms between reseeds
      await new Promise((r) => setTimeout(r, 250));
    }
    // Wait for pipeline processing
    console.log("\nWaiting 6s for pipeline processing...");
    await new Promise((r) => setTimeout(r, 6000));
  }

  // Evaluate each GT row
  console.log(`\nEvaluating ${gtRows.length} spans...`);
  const results: SpanResult[] = [];

  for (const row of gtRows) {
    // Query current state
    const attr = await querySpanAttribution(row.interaction_id, row.span_index);

    // Evaluate retrieval phases (only if we have a span_id)
    let phases: PhaseResult[] = [];
    let candidateRank: number | null = null;
    if (attr.span_id && row.expected_project_name_contains && row.expected_project_name_contains !== "none") {
      phases = await evalRetrievalPhases(attr.span_id, row.expected_project_name_contains);
      // Get the fused rank from the RRF phase
      const fusedPhase = phases.find((p) => p.phase === "rrf_fused");
      candidateRank = fusedPhase?.gt_project_rank ?? null;
    }

    const isCorrect = checkCorrectness(row, {
      project_name: attr.project_name,
      decision: attr.decision,
      project_id: attr.project_id,
    });

    results.push({
      row_id: row.row_id,
      interaction_id: row.interaction_id,
      span_index: row.span_index,
      expected_project: row.expected_project_name_contains || row.expected_project_id,
      expected_decision: row.expected_decision,
      predicted_project_id: attr.project_id,
      predicted_project_name: attr.project_name,
      predicted_decision: attr.decision,
      predicted_confidence: attr.confidence,
      is_correct: isCorrect,
      retrieval_phases: phases,
      candidate_count: phases.find((p) => p.phase === "rrf_fused")?.candidates_returned ?? 0,
      candidate_rank: candidateRank,
      model_id: attr.model_id,
      prompt_version: attr.prompt_version,
      reason_codes: attr.reason_codes,
      error: attr.span_id ? "" : "span_not_found",
    });

    // Progress indicator
    if (results.length % 10 === 0) {
      console.log(`  ${results.length}/${gtRows.length} evaluated...`);
    }
  }

  const completedAt = new Date().toISOString();

  // Compute summary
  const headline = computeMetrics(results);
  const perProject = computePerProject(results);
  const phaseStats = computePhaseStats(results);
  const failures = results.filter((r) => !r.is_correct);

  // Load baseline for delta comparison
  let baselineDelta: DeltaReport | null = null;

  const summary: RunSummary = {
    run_id: runId,
    run_started_at_utc: startedAt,
    run_completed_at_utc: completedAt,
    mode: flags.mode,
    feature_flags: {
      fts_enabled: flags.fts,
      trigram_enabled: flags.trigram,
      vector_enabled: flags.vector,
    },
    gt_file: flags["gt-file"],
    total_spans: results.length,
    headline,
    phase_stats: phaseStats,
    per_project: perProject,
    failures: failures.slice(0, 20),
    baseline_delta: null,
  };

  if (flags.baseline) {
    const baseline = await loadBaseline(flags.baseline);
    if (baseline) {
      baselineDelta = computeDelta(summary, baseline, flags.baseline);
      summary.baseline_delta = baselineDelta;
    } else {
      console.error(`Warning: Could not load baseline from ${flags.baseline}`);
    }
  }

  // Output
  const outDir = flags["out-dir"] || `artifacts/gt/runs/m2_eval_${runId}`;
  await Deno.mkdir(outDir, { recursive: true });

  // Write summary JSON
  await Deno.writeTextFile(`${outDir}/summary.json`, JSON.stringify(summary, null, 2));

  // Write per-row results as JSONL
  const rowsJsonl = results.map((r) => JSON.stringify(r)).join("\n") + "\n";
  await Deno.writeTextFile(`${outDir}/rows.jsonl`, rowsJsonl);

  // Write report
  const report = formatReport(summary);
  await Deno.writeTextFile(`${outDir}/report.md`, report);

  // Console output
  if (flags.json) {
    console.log(JSON.stringify(summary, null, 2));
  } else {
    console.log("\n" + report);
    console.log(`\nArtifacts written to: ${outDir}/`);
    console.log(`  summary.json  — machine-readable summary`);
    console.log(`  rows.jsonl    — per-span results`);
    console.log(`  report.md     — human-readable report`);
  }
}

main().catch((err) => {
  console.error(`FATAL: ${err.message || err}`);
  Deno.exit(1);
});
