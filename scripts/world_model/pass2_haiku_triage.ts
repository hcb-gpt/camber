/**
 * Pass 2 — Haiku Triage (~$0.50 total cost)
 *
 * For remaining unlabeled spans after Pass 0 + Pass 1, call Claude Haiku
 * with mini-context to triage project attribution.
 *
 * Steps:
 *   1. Assemble mini-context per span: caller_name, caller_phone, transcript
 *      first 500 chars, list of active projects with phase.
 *   2. Call Claude Haiku (claude-3-haiku-20240307): "Which project does this
 *      call belong to? Return project_id + confidence."
 *   3. Confidence >= 0.80: label as assign (label_source='pass2_haiku_triage')
 *   4. Confidence 0.50-0.79: mark for Pass 3 (no label written)
 *   5. Confidence < 0.50: label as none (label_source='pass2_haiku_triage')
 *
 * Writes to labeling_results (NOT span_attributions).
 * Expected yield: ~30-40% of remaining spans.
 *
 * Usage:
 *   source ~/.camber/credentials.env
 *   deno run --allow-net --allow-env pass2_haiku_triage.ts \
 *     --batch-run-id <id> [--unlabeled-only] [--dry-run] [--max-spans=50]
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

const batchRunIdArg = Deno.args.find((a) => a.startsWith("--batch-run-id="));
const BATCH_RUN_ID = batchRunIdArg?.split("=")[1] || `wm-label-${new Date().toISOString().slice(0,10).replace(/-/g,"")}-pass2`;

const maxSpansArg = Deno.args.find((a) => a.startsWith("--max-spans="));
const MAX_SPANS = maxSpansArg ? parseInt(maxSpansArg.split("=")[1], 10) : 500;

const MODEL_ID = "claude-3-haiku-20240307";
const MAX_TOKENS = 512;
const TRANSCRIPT_PREVIEW_CHARS = 500;

// Confidence thresholds (per architecture doc)
const CONF_ASSIGN = 0.80;
const CONF_NONE = 0.50;

// Rate limiting: ~50 calls/min for Haiku
const RATE_LIMIT_DELAY_MS = 1200;

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
if (!ANTHROPIC_API_KEY) {
  console.error("Missing ANTHROPIC_API_KEY");
  Deno.exit(1);
}

const db = getDb();
const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });

const stats: PassStats = {
  pass_name: "Haiku Triage",
  pass_number: 2,
  total_input: 0,
  labeled: 0,
  deferred: 0,
  errors: 0,
  detail: {
    assigned: 0,
    none_low_conf: 0,
    deferred_to_pass3: 0,
    no_transcript: 0,
    tokens: 0,
  },
};

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

async function getTranscriptPreview(span: UnlabeledSpan): Promise<string> {
  if (span.transcript_segment) {
    return span.transcript_segment.slice(0, TRANSCRIPT_PREVIEW_CHARS);
  }

  // Fallback: try calls_raw
  const { data: callsRaw } = await db
    .from("calls_raw")
    .select("transcript_text")
    .eq("interaction_id", span.interaction_id)
    .maybeSingle();

  if (callsRaw?.transcript_text) {
    return callsRaw.transcript_text.slice(0, TRANSCRIPT_PREVIEW_CHARS);
  }

  return "";
}

// ============================================================
// HAIKU PROMPT + CALL
// ============================================================

const SYSTEM_PROMPT = `You are a project attribution classifier for HCB (Heartwood Custom Builders), a Georgia construction company. Given a phone call snippet and a list of active projects, determine which project the call most likely belongs to.

Return JSON only (no markdown fences):
{
  "project_id": "<uuid or null>",
  "confidence": <0.00-1.00>,
  "reasoning": "<1 sentence>"
}

Rules:
- Look for project names, addresses, client names, trade-specific context, known aliases
- If no clear match, return project_id=null with low confidence
- Be conservative: only high confidence (>=0.80) if evidence is strong
- HCB staff (Zack Sittler, Chad Barlow, Randy Booth) appear on many calls and are NOT project indicators
- Speaker labels like "Zachary Sittler:" just identify who is speaking, not which project`;

function buildUserPrompt(
  span: UnlabeledSpan,
  transcriptPreview: string,
  projects: ActiveProject[],
): string {
  const projectList = projects
    .map((p) => {
      const parts = [p.name];
      if (p.address) parts.push(`addr: ${p.address}`);
      if (p.client_name) parts.push(`client: ${p.client_name}`);
      if (p.phase) parts.push(`phase: ${p.phase}`);
      if (p.aliases && p.aliases.length > 0) parts.push(`aliases: ${p.aliases.slice(0, 3).join(", ")}`);
      return `- ${p.id}: ${parts.join(" | ")}`;
    })
    .join("\n");

  return `CALLER: ${span.contact_name || "Unknown"} (${span.contact_phone || "no phone"})
CALL DATE: ${span.event_at_utc || "unknown"}

TRANSCRIPT (first ${TRANSCRIPT_PREVIEW_CHARS} chars):
"""
${transcriptPreview}
"""

ACTIVE PROJECTS (${projects.length} total):
${projectList}

Which project does this call belong to?`;
}

interface HaikuResult {
  project_id: string | null;
  confidence: number;
  reasoning: string;
  tokens_used: number;
  inference_ms: number;
}

async function callHaiku(userPrompt: string): Promise<HaikuResult> {
  const t0 = Date.now();
  const msg = await anthropic.messages.create({
    model: MODEL_ID,
    max_tokens: MAX_TOKENS,
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: userPrompt }],
  });

  const inference_ms = Date.now() - t0;
  const textBlock = msg.content.find((b: any) => b.type === "text");
  const responseText = textBlock?.type === "text" ? textBlock.text : "";
  const tokens_used = (msg.usage?.input_tokens || 0) + (msg.usage?.output_tokens || 0);

  // Parse JSON response
  const cleaned = responseText.replace(/```json\n?/gi, "").replace(/```\n?/g, "").trim();
  const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
  const jsonText = jsonMatch ? jsonMatch[0] : cleaned;

  try {
    const parsed = JSON.parse(jsonText);
    return {
      project_id: parsed.project_id || null,
      confidence: Math.max(0, Math.min(1, Number(parsed.confidence) || 0)),
      reasoning: parsed.reasoning || "No reasoning provided",
      tokens_used,
      inference_ms,
    };
  } catch {
    // Retry with trailing comma removal
    try {
      const sanitized = jsonText.replace(/,\s*([}\]])/g, "$1");
      const parsed = JSON.parse(sanitized);
      return {
        project_id: parsed.project_id || null,
        confidence: Math.max(0, Math.min(1, Number(parsed.confidence) || 0)),
        reasoning: parsed.reasoning || "No reasoning provided",
        tokens_used,
        inference_ms,
      };
    } catch {
      console.error(`Failed to parse Haiku response: ${responseText.slice(0, 200)}`);
      return {
        project_id: null,
        confidence: 0,
        reasoning: "parse_error",
        tokens_used,
        inference_ms,
      };
    }
  }
}

// ============================================================
// MAIN
// ============================================================

async function main() {
  console.log("=== Pass 2: Haiku Triage ===");
  console.log(`Batch run ID: ${BATCH_RUN_ID}`);
  console.log(`Mode: ${DRY_RUN ? "DRY RUN" : "LIVE"}`);
  console.log(`Model: ${MODEL_ID}`);
  console.log(`Max spans: ${MAX_SPANS}`);
  console.log(`Assign threshold: >= ${CONF_ASSIGN}`);
  console.log(`None threshold: < ${CONF_NONE}`);
  console.log("");

  // Load data
  const alreadyLabeled = UNLABELED_ONLY
    ? await getLabeledSpanIds(db, BATCH_RUN_ID)
    : new Set<string>();

  console.log("Loading unlabeled spans...");
  const allUnlabeled = await getUnlabeledSpans(alreadyLabeled);
  const unlabeled = allUnlabeled.slice(0, MAX_SPANS);

  stats.total_input = unlabeled.length;
  console.log(`Unlabeled spans: ${allUnlabeled.length} (processing: ${unlabeled.length})`);

  if (unlabeled.length === 0) {
    console.log("Nothing to do.");
    return;
  }

  console.log("Loading active projects...");
  const projects = await getActiveProjects();
  console.log(`Active projects: ${projects.length}`);

  if (projects.length === 0) {
    console.error("No active projects found.");
    Deno.exit(1);
  }

  // Build a set of valid project IDs for validation
  const validProjectIds = new Set(projects.map((p) => p.id));

  // Process
  console.log("\nProcessing...\n");

  for (let i = 0; i < unlabeled.length; i++) {
    const span = unlabeled[i];
    const progress = `[${i + 1}/${unlabeled.length}]`;

    try {
      const transcript = await getTranscriptPreview(span);

      if (!transcript) {
        console.log(`${progress} span=${span.span_id.slice(0, 8)}: No transcript, skipping`);
        stats.detail.no_transcript++;
        stats.deferred++;
        continue;
      }

      const userPrompt = buildUserPrompt(span, transcript, projects);

      // Skip actual API call in dry-run
      if (DRY_RUN) {
        console.log(`${progress} span=${span.span_id.slice(0, 8)}: [DRY-RUN] Would call Haiku`);
        stats.deferred++;
        continue;
      }

      const result = await callHaiku(userPrompt);
      stats.detail.tokens += result.tokens_used;

      if (result.project_id && result.confidence >= CONF_ASSIGN) {
        // Validate project_id
        if (!validProjectIds.has(result.project_id)) {
          console.log(
            `${progress} span=${span.span_id.slice(0, 8)}: Invalid project_id, deferring`,
          );
          stats.detail.deferred_to_pass3++;
          stats.deferred++;
          continue;
        }

        const projName = projects.find((p) => p.id === result.project_id)?.name || "?";
        const ok = await writeLabel(db, {
          span_id: span.span_id,
          interaction_id: span.interaction_id,
          project_id: result.project_id,
          label_decision: "assign",
          confidence: result.confidence,
          label_source: "pass2_haiku_triage",
          pass_number: 2,
          batch_run_id: BATCH_RUN_ID,
          attribution_lock: "pass2_haiku",
          model_id: MODEL_ID,
          tokens_used: result.tokens_used,
          inference_ms: result.inference_ms,
        }, false);

        if (ok) {
          stats.detail.assigned++;
          stats.labeled++;
          console.log(
            `${progress} ASSIGN span=${span.span_id.slice(0, 8)} -> ${projName} (conf=${result.confidence.toFixed(2)})`,
          );
        } else {
          stats.errors++;
        }
      } else if (!result.project_id || result.confidence < CONF_NONE) {
        // Low confidence: label as none
        const ok = await writeLabel(db, {
          span_id: span.span_id,
          interaction_id: span.interaction_id,
          project_id: null,
          label_decision: "none",
          confidence: result.confidence,
          label_source: "pass2_haiku_triage",
          pass_number: 2,
          batch_run_id: BATCH_RUN_ID,
          attribution_lock: "pass2_haiku",
          model_id: MODEL_ID,
          tokens_used: result.tokens_used,
          inference_ms: result.inference_ms,
        }, false);

        if (ok) {
          stats.detail.none_low_conf++;
          stats.labeled++;
          console.log(
            `${progress} NONE  span=${span.span_id.slice(0, 8)} (conf=${result.confidence.toFixed(2)})`,
          );
        } else {
          stats.errors++;
        }
      } else {
        // Mid confidence: defer to Pass 3
        stats.detail.deferred_to_pass3++;
        stats.deferred++;
        console.log(
          `${progress} DEFER span=${span.span_id.slice(0, 8)} (conf=${result.confidence.toFixed(2)}, needs Pass 3)`,
        );
      }

      // Rate limiting
      if (i < unlabeled.length - 1) {
        await new Promise((r) => setTimeout(r, RATE_LIMIT_DELAY_MS));
      }
    } catch (err: any) {
      console.error(`${progress} Error: ${err.message}`);
      stats.errors++;

      if (err.status === 429) {
        console.log("Rate limited, waiting 30s...");
        await new Promise((r) => setTimeout(r, 30000));
      }
    }
  }

  // Report
  const estimatedCost = (stats.detail.tokens / 1_000_000) * 0.25;

  console.log("\n=== Pass 2 Results ===");
  console.log(`Total input:         ${stats.total_input}`);
  console.log(`Assigned (>=${CONF_ASSIGN}):     ${stats.detail.assigned}`);
  console.log(`None (<${CONF_NONE}):          ${stats.detail.none_low_conf}`);
  console.log(`Deferred to Pass 3:  ${stats.detail.deferred_to_pass3}`);
  console.log(`No transcript:       ${stats.detail.no_transcript}`);
  console.log(`Total labeled:       ${stats.labeled}`);
  console.log(`Errors:              ${stats.errors}`);
  console.log(`Tokens used:         ${stats.detail.tokens}`);
  console.log(`Estimated cost:      $${estimatedCost.toFixed(4)}`);
  if (stats.total_input > 0) {
    console.log(`Yield:               ${((stats.labeled / stats.total_input) * 100).toFixed(1)}%`);
  }
  if (allUnlabeled.length > MAX_SPANS) {
    console.log(`\nNote: ${allUnlabeled.length - MAX_SPANS} spans remain unprocessed (increase --max-spans)`);
  }
  if (DRY_RUN) {
    console.log("\n[DRY-RUN] No writes or Haiku calls were made.");
  }
}

main().catch((err) => {
  console.error("Pass 2 failed:", err);
  Deno.exit(1);
});
