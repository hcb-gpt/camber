#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read

/**
 * Pass 3 — Opus/Sonnet Deep Label + Fact Extraction (~$15-20 total)
 *
 * For remaining unlabeled spans after Pass 0-2, call a frontier model
 * with full context to produce high-quality attributions and extract
 * project facts.
 *
 * Default model: claude-sonnet-4-5-20250929 (STRAT decision for cost)
 * Override: --model claude-opus-4-6
 *
 * Steps:
 *   1. Build full context per span: transcript, contact metadata,
 *      candidate projects, project_facts, affinity data.
 *   2. Dual prompt: attribution + fact extraction.
 *   3. Thresholds: conf >= 0.60 assign, < 0.60 -> Pass 4 review.
 *   4. Fact extraction (conf >= 0.80 only): writes to project_facts
 *      with full provenance chain.
 *
 * Writes to labeling_results (NOT span_attributions).
 * Expected yield: ~60-70% of remaining spans.
 *
 * Usage:
 *   source ~/.camber/credentials.env
 *   deno run --allow-net --allow-env --allow-read pass3_opus_deep_label.ts \
 *     --batch-run-id <id> [--unlabeled-only] [--dry-run] \
 *     [--max-spans=100] [--extract-facts] [--model claude-opus-4-6]
 */

import Anthropic from "npm:@anthropic-ai/sdk@0.39.0";
import { getDb } from "./shared/db.ts";
import { writeLabel, getLabeledSpanIds } from "./shared/label_writer.ts";
import type { UnlabeledSpan, ActiveProject, PassStats } from "./shared/types.ts";

// ============================================================
// CONFIG
// ============================================================

const DRY_RUN = Deno.args.includes("--dry-run");
const UNLABELED_ONLY = Deno.args.includes("--unlabeled-only");
const EXTRACT_FACTS = Deno.args.includes("--extract-facts");

const batchRunIdArg = Deno.args.find((a) => a.startsWith("--batch-run-id="));
const BATCH_RUN_ID = batchRunIdArg?.split("=")[1] ||
  `wm-label-${new Date().toISOString().slice(0, 10).replace(/-/g, "")}-pass3`;

const maxSpansArg = Deno.args.find((a) => a.startsWith("--max-spans="));
const MAX_SPANS = maxSpansArg ? parseInt(maxSpansArg.split("=")[1], 10) : 100;

const modelArg = Deno.args.find((a) => a.startsWith("--model="));
const MODEL_ID = modelArg?.split("=")[1] || "claude-sonnet-4-5-20250929";

const MAX_TOKENS = 2048;

// Thresholds
const CONF_ASSIGN = 0.60;
const CONF_FACT_EXTRACT = 0.80;

// Rate limiting: model-dependent
const isOpus = MODEL_ID.includes("opus");
const RATE_LIMIT_DELAY_MS = isOpus ? 12000 : 3000; // 5/min opus, 20/min sonnet

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
if (!ANTHROPIC_API_KEY) {
  console.error("Missing ANTHROPIC_API_KEY");
  Deno.exit(1);
}

const db = getDb();
const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });

const stats: PassStats = {
  pass_name: "Opus Deep Label",
  pass_number: 3,
  total_input: 0,
  labeled: 0,
  deferred: 0,
  errors: 0,
  detail: {
    assigned: 0,
    review_low_conf: 0,
    no_transcript: 0,
    tokens: 0,
    facts_extracted: 0,
    facts_written: 0,
  },
};

// ============================================================
// TYPES
// ============================================================

interface ExtractedFact {
  fact_kind: string;
  fact_payload: Record<string, unknown>;
  source_char_start: number;
  source_char_end: number;
  confidence: number;
}

interface DeepLabelResult {
  project_id: string | null;
  confidence: number;
  decision: string;
  reasoning: string;
  extracted_facts: ExtractedFact[];
  tokens_used: number;
  inference_ms: number;
}

interface ProjectFact {
  project_id: string;
  fact_kind: string;
  fact_payload: Record<string, unknown>;
}

// ============================================================
// DATA LOADING
// ============================================================

async function getUnlabeledSpans(alreadyLabeled: Set<string>): Promise<UnlabeledSpan[]> {
  const { data: spans, error } = await db
    .from("conversation_spans")
    .select("id, interaction_id, transcript_segment");

  if (error) {
    console.error("Failed to query conversation_spans:", error.message);
    return [];
  }

  // Get all labeled spans from labeling_results
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

async function getActiveProjects(): Promise<ActiveProject[]> {
  const { data, error } = await db
    .from("projects")
    .select("id, name, status, phase, address, client_name, aliases")
    .in("status", ["active", "warranty", "estimating"]);

  if (error) {
    console.error("Failed to query projects:", error.message);
    return [];
  }

  return (data || []) as ActiveProject[];
}

async function getFullTranscript(span: UnlabeledSpan): Promise<string> {
  if (span.transcript_segment) {
    return span.transcript_segment;
  }

  const { data: callsRaw } = await db
    .from("calls_raw")
    .select("transcript_text")
    .eq("interaction_id", span.interaction_id)
    .maybeSingle();

  return callsRaw?.transcript_text || "";
}

async function getProjectFactsForProjects(
  projectIds: string[],
): Promise<Map<string, ProjectFact[]>> {
  const map = new Map<string, ProjectFact[]>();
  if (projectIds.length === 0) return map;

  for (let i = 0; i < projectIds.length; i += 50) {
    const chunk = projectIds.slice(i, i + 50);
    const { data } = await db
      .from("project_facts")
      .select("project_id, fact_kind, fact_payload")
      .in("project_id", chunk)
      .order("as_of_at", { ascending: false })
      .limit(200);

    for (const row of data || []) {
      const existing = map.get(row.project_id) || [];
      existing.push({
        project_id: row.project_id,
        fact_kind: row.fact_kind,
        fact_payload: row.fact_payload,
      });
      map.set(row.project_id, existing);
    }
  }

  return map;
}

async function getContactAffinities(
  contactId: string,
): Promise<Array<{ project_id: string; weight: number }>> {
  if (!contactId) return [];

  const { data } = await db
    .from("correspondent_project_affinity")
    .select("project_id, weight")
    .eq("contact_id", contactId)
    .gt("weight", 0)
    .order("weight", { ascending: false })
    .limit(10);

  return (data || []) as Array<{ project_id: string; weight: number }>;
}

async function resolveEvidenceEventId(interactionId: string): Promise<string | null> {
  const { data } = await db
    .from("evidence_events")
    .select("evidence_event_id")
    .eq("source_type", "call")
    .eq("source_id", interactionId)
    .maybeSingle();

  return data?.evidence_event_id || null;
}

// ============================================================
// PROMPT
// ============================================================

function buildSystemPrompt(): string {
  const factExtractionSection = EXTRACT_FACTS
    ? `

FACT EXTRACTION:
When you identify the project, also extract factual claims from the transcript.
For each fact, include:
- fact_kind: one of scope.feature, scope.dimension, scope.material, scope.contact, scope.site, schedule.milestone, permit.status, scope.document
- fact_payload: {feature: "...", value: "...", tags: [], confidence: 0.0-1.0}
- source_char_start: approximate character offset in the transcript
- source_char_end: approximate character offset
- confidence: how confident you are in this fact (0.0-1.0)

Only extract facts that are clearly stated in the transcript. Do not infer or speculate.`
    : "";

  return `You are a deep project attribution specialist for HCB (Heartwood Custom Builders), a Georgia custom home builder. Given a full phone call transcript, caller metadata, and candidate projects with their world model facts, determine which project this call belongs to.

CRITICAL RULES:
- HCB staff (Zack Sittler, Chad Barlow, Randy Booth) appear on MANY calls. Their names are NOT project evidence.
- Look for project names, addresses, client names, trade-specific work discussion, material specs, schedule references.
- Use project_facts to corroborate: if a project's known facts match the transcript discussion, that strengthens the match.
- If evidence is ambiguous, be honest about confidence.
- If no project match is possible, return project_id=null.
${factExtractionSection}

CONFIDENCE THRESHOLDS:
- 0.80-1.00: Strong evidence (exact project/address/client mentions + corroborating facts)
- 0.60-0.79: Moderate evidence (indirect references, trade-context match)
- 0.00-0.59: Weak/no evidence (no assignment)

Return JSON only (no markdown fences):
{
  "project_id": "<uuid or null>",
  "confidence": <0.00-1.00>,
  "decision": "assign|review|none",
  "reasoning": "<2-3 sentences>",
  "extracted_facts": [
    {
      "fact_kind": "<kind>",
      "fact_payload": {"feature": "...", "value": "...", "tags": [], "confidence": 0.9},
      "source_char_start": 0,
      "source_char_end": 100,
      "confidence": 0.9
    }
  ]
}

If not extracting facts, omit the extracted_facts field or return an empty array.`;
}

function buildUserPrompt(
  span: UnlabeledSpan,
  transcript: string,
  projects: ActiveProject[],
  projectFacts: Map<string, ProjectFact[]>,
  affinities: Array<{ project_id: string; weight: number }>,
): string {
  const affinityStr = affinities.length > 0
    ? affinities
        .map((a) => {
          const proj = projects.find((p) => p.id === a.project_id);
          return `  ${proj?.name || a.project_id.slice(0, 8)}: weight=${a.weight.toFixed(1)}`;
        })
        .join("\n")
    : "  None";

  const projectList = projects
    .map((p) => {
      const parts: string[] = [`${p.name} (${p.id})`];
      if (p.address) parts.push(`  Address: ${p.address}`);
      if (p.client_name) parts.push(`  Client: ${p.client_name}`);
      if (p.phase) parts.push(`  Phase: ${p.phase}`);
      if (p.aliases && p.aliases.length > 0) {
        parts.push(`  Aliases: ${p.aliases.slice(0, 5).join(", ")}`);
      }

      const facts = projectFacts.get(p.id);
      if (facts && facts.length > 0) {
        const factSummary = facts
          .slice(0, 5)
          .map((f) => {
            const payload = f.fact_payload as Record<string, unknown>;
            return `    [${f.fact_kind}] ${payload.feature || ""}: ${payload.value || ""}`;
          })
          .join("\n");
        parts.push(`  Known facts:\n${factSummary}`);
      }

      return parts.join("\n");
    })
    .join("\n\n");

  return `CALLER: ${span.contact_name || "Unknown"} (${span.contact_phone || "no phone"})
CALL DATE: ${span.event_at_utc || "unknown"}
CALLER AFFINITY SCORES:
${affinityStr}

FULL TRANSCRIPT:
"""
${transcript}
"""

CANDIDATE PROJECTS (${projects.length}):

${projectList}

Analyze the full transcript and determine which project this call is about. ${
    EXTRACT_FACTS ? "Also extract any factual claims about the project." : ""
  }`;
}

// ============================================================
// MODEL CALL
// ============================================================

async function callModel(
  systemPrompt: string,
  userPrompt: string,
): Promise<DeepLabelResult> {
  const t0 = Date.now();

  const msg = await anthropic.messages.create({
    model: MODEL_ID,
    max_tokens: MAX_TOKENS,
    system: systemPrompt,
    messages: [{ role: "user", content: userPrompt }],
  });

  const inference_ms = Date.now() - t0;
  const textBlock = msg.content.find((b: any) => b.type === "text");
  const responseText = textBlock?.type === "text" ? textBlock.text : "";
  const tokens_used =
    (msg.usage?.input_tokens || 0) + (msg.usage?.output_tokens || 0);

  // Parse JSON
  const cleaned = responseText
    .replace(/```json\n?/gi, "")
    .replace(/```\n?/g, "")
    .trim();
  const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
  const jsonText = jsonMatch ? jsonMatch[0] : cleaned;

  let parsed: any;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    try {
      const sanitized = jsonText.replace(/,\s*([}\]])/g, "$1");
      parsed = JSON.parse(sanitized);
    } catch {
      console.error(
        `Failed to parse model response: ${responseText.slice(0, 300)}`,
      );
      return {
        project_id: null,
        confidence: 0,
        decision: "none",
        reasoning: "parse_error",
        extracted_facts: [],
        tokens_used,
        inference_ms,
      };
    }
  }

  const extractedFacts: ExtractedFact[] = [];
  if (Array.isArray(parsed.extracted_facts)) {
    for (const f of parsed.extracted_facts) {
      if (f.fact_kind && f.fact_payload) {
        extractedFacts.push({
          fact_kind: String(f.fact_kind),
          fact_payload:
            typeof f.fact_payload === "object" ? f.fact_payload : {},
          source_char_start: Number(f.source_char_start) || 0,
          source_char_end: Number(f.source_char_end) || 0,
          confidence: Math.max(
            0,
            Math.min(1, Number(f.confidence) || 0),
          ),
        });
      }
    }
  }

  return {
    project_id: parsed.project_id || null,
    confidence: Math.max(0, Math.min(1, Number(parsed.confidence) || 0)),
    decision: parsed.decision || "none",
    reasoning: parsed.reasoning || "No reasoning provided",
    extracted_facts: extractedFacts,
    tokens_used,
    inference_ms,
  };
}

// ============================================================
// FACT WRITER
// ============================================================

async function writeFacts(
  span: UnlabeledSpan,
  projectId: string,
  facts: ExtractedFact[],
  evidenceEventId: string | null,
): Promise<number> {
  if (facts.length === 0) return 0;
  if (DRY_RUN) {
    console.log(
      `  [DRY-RUN] Would write ${facts.length} facts to project_facts`,
    );
    return facts.length;
  }

  let written = 0;
  const eventAtUtc = span.event_at_utc
    ? new Date(span.event_at_utc).toISOString()
    : new Date().toISOString();
  const now = new Date().toISOString();

  for (const fact of facts) {
    const row: Record<string, unknown> = {
      project_id: projectId,
      as_of_at: eventAtUtc,
      observed_at: now,
      fact_kind: fact.fact_kind,
      fact_payload: fact.fact_payload,
      interaction_id: span.interaction_id,
      source_span_id: span.span_id,
      tags: ["PIPELINE_EXTRACTED"],
    };

    if (evidenceEventId) {
      row.evidence_event_id = evidenceEventId;
    }

    if (
      fact.source_char_start > 0 &&
      fact.source_char_end > fact.source_char_start
    ) {
      row.source_char_start = fact.source_char_start;
      row.source_char_end = fact.source_char_end;
    }

    const { error } = await db.from("project_facts").insert(row);

    if (error) {
      // Skip duplicates gracefully
      if (error.message?.includes("duplicate") || error.code === "23505") {
        continue;
      }
      console.error(
        `  Failed to write fact (${fact.fact_kind}):`,
        error.message,
      );
      continue;
    }

    written++;
  }

  return written;
}

// ============================================================
// MAIN
// ============================================================

async function main() {
  console.log("=== Pass 3: Deep Label + Fact Extraction ===");
  console.log(`Batch run ID: ${BATCH_RUN_ID}`);
  console.log(`Model: ${MODEL_ID}`);
  console.log(`Mode: ${DRY_RUN ? "DRY RUN" : "LIVE"}`);
  console.log(`Extract facts: ${EXTRACT_FACTS}`);
  console.log(`Fact extraction threshold: conf >= ${CONF_FACT_EXTRACT}`);
  console.log(`Assign threshold: conf >= ${CONF_ASSIGN}`);
  console.log(`Max spans: ${MAX_SPANS}`);
  console.log(`Rate limit: ${RATE_LIMIT_DELAY_MS}ms between calls`);
  console.log("");

  // Load data
  const alreadyLabeled = UNLABELED_ONLY
    ? await getLabeledSpanIds(db, BATCH_RUN_ID)
    : new Set<string>();

  console.log("Loading unlabeled spans...");
  const allUnlabeled = await getUnlabeledSpans(alreadyLabeled);
  const unlabeled = allUnlabeled.slice(0, MAX_SPANS);
  stats.total_input = unlabeled.length;
  console.log(
    `Unlabeled spans: ${allUnlabeled.length} (processing: ${unlabeled.length})`,
  );

  if (unlabeled.length === 0) {
    console.log("Nothing to do.");
    return;
  }

  console.log("Loading active projects...");
  const projects = await getActiveProjects();
  console.log(`Active projects: ${projects.length}`);

  console.log("Loading project facts...");
  const projectFacts = await getProjectFactsForProjects(
    projects.map((p) => p.id),
  );
  const factsCount = [...projectFacts.values()].reduce(
    (sum, arr) => sum + arr.length,
    0,
  );
  console.log(`Project facts loaded: ${factsCount} across ${projectFacts.size} projects`);

  const validProjectIds = new Set(projects.map((p) => p.id));
  const systemPrompt = buildSystemPrompt();

  // Process
  console.log("\nProcessing...\n");

  for (let i = 0; i < unlabeled.length; i++) {
    const span = unlabeled[i];
    const progress = `[${i + 1}/${unlabeled.length}]`;

    try {
      const transcript = await getFullTranscript(span);

      if (!transcript) {
        console.log(
          `${progress} span=${span.span_id.slice(0, 8)}: No transcript, skipping`,
        );
        stats.detail.no_transcript++;
        stats.deferred++;
        continue;
      }

      // Load contact affinities
      const affinities = span.contact_id
        ? await getContactAffinities(span.contact_id)
        : [];

      const userPrompt = buildUserPrompt(
        span,
        transcript,
        projects,
        projectFacts,
        affinities,
      );

      if (DRY_RUN) {
        console.log(
          `${progress} span=${span.span_id.slice(0, 8)}: [DRY-RUN] Would call ${MODEL_ID} (prompt ~${userPrompt.length} chars)`,
        );
        stats.deferred++;
        continue;
      }

      // Call model
      const result = await callModel(systemPrompt, userPrompt);
      stats.detail.tokens += result.tokens_used;

      if (result.project_id && result.confidence >= CONF_ASSIGN) {
        // Validate project_id
        if (!validProjectIds.has(result.project_id)) {
          console.log(
            `${progress} span=${span.span_id.slice(0, 8)}: Invalid project_id, marking review`,
          );
          stats.detail.review_low_conf++;
          stats.deferred++;
          continue;
        }

        const projName =
          projects.find((p) => p.id === result.project_id)?.name || "?";

        // Write label
        const ok = await writeLabel(
          db,
          {
            span_id: span.span_id,
            interaction_id: span.interaction_id,
            project_id: result.project_id,
            label_decision: "assign",
            confidence: result.confidence,
            label_source: "pass3_opus_deep_label",
            pass_number: 3,
            batch_run_id: BATCH_RUN_ID,
            attribution_lock: "pass3_deep_label",
            model_id: MODEL_ID,
            tokens_used: result.tokens_used,
            inference_ms: result.inference_ms,
            extracted_facts: result.extracted_facts.length > 0
              ? result.extracted_facts as unknown as Record<string, unknown>[]
              : undefined,
          },
          false,
        );

        if (ok) {
          stats.detail.assigned++;
          stats.labeled++;
          console.log(
            `${progress} ASSIGN span=${span.span_id.slice(0, 8)} -> ${projName} (conf=${result.confidence.toFixed(2)})`,
          );

          // Fact extraction (only for high confidence)
          if (
            EXTRACT_FACTS &&
            result.confidence >= CONF_FACT_EXTRACT &&
            result.extracted_facts.length > 0
          ) {
            const evidenceEventId = await resolveEvidenceEventId(
              span.interaction_id,
            );
            const written = await writeFacts(
              span,
              result.project_id,
              result.extracted_facts,
              evidenceEventId,
            );
            stats.detail.facts_extracted += result.extracted_facts.length;
            stats.detail.facts_written += written;
            console.log(
              `  Facts: ${result.extracted_facts.length} extracted, ${written} written`,
            );
          }
        } else {
          stats.errors++;
        }
      } else {
        // Low confidence: route to review (Pass 4)
        const ok = await writeLabel(
          db,
          {
            span_id: span.span_id,
            interaction_id: span.interaction_id,
            project_id: result.project_id,
            label_decision:
              result.confidence >= 0.40 ? "review" : "none",
            confidence: result.confidence,
            label_source: "pass3_opus_deep_label",
            pass_number: 3,
            batch_run_id: BATCH_RUN_ID,
            attribution_lock: "pass3_deep_label",
            model_id: MODEL_ID,
            tokens_used: result.tokens_used,
            inference_ms: result.inference_ms,
          },
          false,
        );

        if (ok) {
          stats.detail.review_low_conf++;
          stats.labeled++;
          const projName = result.project_id
            ? projects.find((p) => p.id === result.project_id)?.name || "?"
            : "none";
          console.log(
            `${progress} REVIEW span=${span.span_id.slice(0, 8)} -> ${projName} (conf=${result.confidence.toFixed(2)})`,
          );
        } else {
          stats.errors++;
        }
      }

      // Rate limiting
      if (i < unlabeled.length - 1) {
        await new Promise((r) => setTimeout(r, RATE_LIMIT_DELAY_MS));
      }
    } catch (err: any) {
      console.error(`${progress} Error: ${err.message}`);
      stats.errors++;

      if (err.status === 429) {
        const wait = isOpus ? 60000 : 15000;
        console.log(`Rate limited, waiting ${wait / 1000}s...`);
        await new Promise((r) => setTimeout(r, wait));
      }
    }
  }

  // Report
  const costPerMToken = MODEL_ID.includes("opus") ? 15.0 : 3.0;
  const estimatedCost =
    (stats.detail.tokens / 1_000_000) * costPerMToken;

  console.log("\n=== Pass 3 Results ===");
  console.log(`Total input:         ${stats.total_input}`);
  console.log(`Assigned (>=${CONF_ASSIGN}):     ${stats.detail.assigned}`);
  console.log(`Review/None:         ${stats.detail.review_low_conf}`);
  console.log(`No transcript:       ${stats.detail.no_transcript}`);
  console.log(`Total labeled:       ${stats.labeled}`);
  console.log(`Errors:              ${stats.errors}`);
  console.log(`Tokens used:         ${stats.detail.tokens}`);
  console.log(`Estimated cost:      $${estimatedCost.toFixed(2)}`);
  if (EXTRACT_FACTS) {
    console.log(`Facts extracted:     ${stats.detail.facts_extracted}`);
    console.log(`Facts written:       ${stats.detail.facts_written}`);
  }
  if (stats.total_input > 0) {
    console.log(
      `Yield:               ${((stats.labeled / stats.total_input) * 100).toFixed(1)}%`,
    );
  }
  if (allUnlabeled.length > MAX_SPANS) {
    console.log(
      `\nNote: ${allUnlabeled.length - MAX_SPANS} spans remain (increase --max-spans)`,
    );
  }
  if (DRY_RUN) {
    console.log("\n[DRY-RUN] No writes or API calls were made.");
  }
}

main().catch((err) => {
  console.error("Pass 3 failed:", err);
  Deno.exit(1);
});
