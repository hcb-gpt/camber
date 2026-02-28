/**
 * generate-summary Edge Function v1.0.2
 * Produces call-level `human_summary` + `ai_scheduler_json` from span-level pipeline outputs.
 *
 * Auth (internal gate; verify_jwt=false):
 * - X-Edge-Secret == EDGE_SHARED_SECRET.
 *
 * v1.0.2 Changes (Parser hardening):
 * - Added JSON repair for unquoted string values (model sometimes omits quotes)
 * - Fallback parser now attempts to extract follow_ups via regex
 * - Better logging of raw model output on parse failure
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getModelConfigCached } from "../_shared/model_config.ts";

const GENERATE_SUMMARY_VERSION = "v1.0.2";
const PROMPT_VERSION = "generate-summary-v1";
const DEFAULT_MODEL_ID = Deno.env.get("GENERATE_SUMMARY_MODEL") || "gpt-4o-mini";
const DEFAULT_MAX_TOKENS = 1400;
const DEFAULT_TEMPERATURE = 0;
const MAX_TRANSCRIPT_CHARS = 12000;
const MAX_SPAN_CHARS = 700;
const MAX_PROMPT_SPANS = 20;
const MAX_FOLLOW_UPS = 12;

const jsonHeaders = { "Content-Type": "application/json" };

interface ConversationSpanRow {
  id: string;
  span_index: number;
  transcript_segment: string | null;
  word_count: number | null;
}

interface SpanAttributionRow {
  span_id: string;
  project_id: string | null;
  applied_project_id: string | null;
  decision: "assign" | "review" | "none" | null;
  confidence: number | null;
  reasoning: string | null;
  anchors: unknown;
  attributed_at: string | null;
}

interface FollowUpItem {
  title: string;
  action: string;
  owner: string | null;
  due_hint: string | null;
  priority: "low" | "medium" | "high";
  evidence_quote: string | null;
  span_index_hint: number | null;
}

interface ModelOutput {
  human_summary: string;
  follow_ups: FollowUpItem[];
}

interface ParsedModelOutput {
  output: ModelOutput;
  parseMode: "strict_json" | "fallback_summary";
  parseError: string | null;
}

async function logDiagnostic(
  message: string,
  metadata: Record<string, unknown>,
  logLevel = "error",
): Promise<void> {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) return;

    const sb = createClient(supabaseUrl, serviceRoleKey);
    await sb.from("diagnostic_logs").insert({
      function_name: "generate-summary",
      function_version: GENERATE_SUMMARY_VERSION,
      log_level: logLevel,
      message,
      metadata,
    });
  } catch (e) {
    console.warn(`[generate-summary] diagnostic_logs insert failed: ${(e as Error)?.message || e}`);
  }
}

function truncate(value: string | null | undefined, max: number): string {
  if (!value) return "";
  if (value.length <= max) return value;
  return `${value.slice(0, max)}...`;
}

function stripCodeFences(raw: string): string {
  return (raw || "").replace(/```json\n?/gi, "").replace(/```\n?/g, "").trim();
}

/**
 * v1.0.2: Attempt to repair common JSON issues from LLM output:
 * 1. Unquoted string values: "key": value text here
 * 2. Trailing commas before closing brackets
 * 3. Single quotes used instead of double quotes
 */
function repairJson(text: string): string {
  let repaired = text;

  // Replace single quotes with double quotes if no double quotes present
  if (!repaired.includes('"') && repaired.includes("'")) {
    repaired = repaired.replace(/'/g, '"');
  }

  // Fix unquoted string values after "key":
  // Matches: "some_key" : unquoted text, (terminated by comma, newline, or closing brace)
  repaired = repaired.replace(
    /("[\w]+")\s*:\s*(?![\[{"0-9tfn-])([^\n\r,}\]]+?)(\s*[,}\]])/g,
    (match, key, value, terminator) => {
      const trimmedValue = value.trim();
      if (
        /^".*"$/.test(trimmedValue) ||
        /^-?\d+(\.\d+)?$/.test(trimmedValue) ||
        /^(true|false|null)$/i.test(trimmedValue)
      ) {
        return match;
      }
      const escaped = trimmedValue.replace(/"/g, '\\"');
      return `${key}: "${escaped}"${terminator}`;
    },
  );

  // Remove trailing commas before ] or }
  repaired = repaired.replace(/,\s*([}\]])/g, "$1");

  return repaired;
}

function extractFallbackSummary(cleaned: string): string {
  // Try quoted value first
  const humanSummaryMatch = cleaned.match(/"human_summary"\s*:\s*"([\s\S]*?)"/i);
  if (humanSummaryMatch?.[1]) {
    return truncate(
      humanSummaryMatch[1]
        .replace(/\\n/g, " ")
        .replace(/\\"/g, '"')
        .replace(/\\\\/g, "\\")
        .trim(),
      2500,
    );
  }

  // v1.0.2: Try unquoted value (the actual failure mode)
  // Match: "human_summary" : <text until next JSON key or end>
  const unquotedMatch = cleaned.match(
    /["']?human_summary["']?\s*:\s*([^"'\[{][\s\S]*?)(?=\s*,?\s*["']?follow_ups["']?\s*:|$)/i,
  );
  if (unquotedMatch?.[1]) {
    return truncate(
      unquotedMatch[1]
        .replace(/[,}\]]+\s*$/, "")
        .replace(/\s+/g, " ")
        .trim(),
      2500,
    );
  }

  // Last resort: strip all JSON syntax and return raw text
  return truncate(
    cleaned
      .replace(/[{}[\]"]/g, " ")
      .replace(/\s+/g, " ")
      .trim(),
    1200,
  );
}

/**
 * v1.0.2: Extract follow_ups from broken JSON via regex.
 * Finds repeated title/action/priority patterns.
 */
function extractFallbackFollowUps(cleaned: string): FollowUpItem[] {
  const items: FollowUpItem[] = [];

  const titlePattern = /["']?title["']?\s*:\s*["']?([^"'\n,}{]+?)["']?\s*[,\n]/gi;
  const actionPattern = /["']?action["']?\s*:\s*["']?([^"'\n,}{]+?)["']?\s*[,\n]/gi;
  const ownerPattern = /["']?owner["']?\s*:\s*["']?([^"'\n,}{]+?)["']?\s*[,\n]/gi;
  const priorityPattern = /["']?priority["']?\s*:\s*["']?(low|medium|high)["']?\s*[,\n]/gi;
  const quotePattern = /["']?evidence_quote["']?\s*:\s*["']?([^"'\n}{]+?)["']?\s*[,\n]/gi;
  const spanPattern = /["']?span_index_hint["']?\s*:\s*(\d+)/gi;

  const titles: string[] = [];
  const actions: string[] = [];
  const owners: string[] = [];
  const priorities: string[] = [];
  const quotes: string[] = [];
  const spanHints: (number | null)[] = [];

  let m;
  while ((m = titlePattern.exec(cleaned)) !== null) titles.push(m[1].trim());
  while ((m = actionPattern.exec(cleaned)) !== null) actions.push(m[1].trim());
  while ((m = ownerPattern.exec(cleaned)) !== null) owners.push(m[1].trim());
  while ((m = priorityPattern.exec(cleaned)) !== null) priorities.push(m[1].trim().toLowerCase());
  while ((m = quotePattern.exec(cleaned)) !== null) quotes.push(m[1].trim());
  while ((m = spanPattern.exec(cleaned)) !== null) spanHints.push(parseInt(m[1]));

  for (let i = 0; i < Math.min(titles.length, MAX_FOLLOW_UPS); i++) {
    const rawPriority = priorities[i] || "medium";
    const priority = (["low", "medium", "high"].includes(rawPriority) ? rawPriority : "medium") as
      | "low"
      | "medium"
      | "high";
    items.push({
      title: truncate(titles[i] || "", 200),
      action: truncate(actions[i] || "", 1200),
      owner: owners[i] ? truncate(owners[i], 120) : null,
      due_hint: null,
      priority,
      evidence_quote: quotes[i] ? truncate(quotes[i], 240) : null,
      span_index_hint: spanHints[i] ?? null,
    });
  }

  return items.filter((item) => item.title.length > 0 || item.action.length > 0);
}

function normalizeFollowUps(followUps: any[]): FollowUpItem[] {
  const normalized: FollowUpItem[] = [];
  for (const item of followUps.slice(0, MAX_FOLLOW_UPS)) {
    const rawPriority = String(item?.priority || "medium").toLowerCase();
    const priority = (["low", "medium", "high"].includes(rawPriority) ? rawPriority : "medium") as
      | "low"
      | "medium"
      | "high";
    const spanHintNumber = Number(item?.span_index_hint);
    normalized.push({
      title: truncate(String(item?.title || "").trim(), 200),
      action: truncate(String(item?.action || "").trim(), 1200),
      owner: item?.owner ? truncate(String(item.owner).trim(), 120) : null,
      due_hint: item?.due_hint ? truncate(String(item.due_hint).trim(), 120) : null,
      priority,
      evidence_quote: item?.evidence_quote ? truncate(String(item.evidence_quote).trim(), 240) : null,
      span_index_hint: Number.isFinite(spanHintNumber) ? spanHintNumber : null,
    });
  }
  return normalized.filter((item) => item.title.length > 0 || item.action.length > 0);
}

function parseModelOutput(raw: string): ParsedModelOutput {
  const cleaned = stripCodeFences(raw);
  const objectMatch = cleaned.match(/\{[\s\S]*\}/);
  const jsonText = objectMatch ? objectMatch[0] : cleaned;

  // Attempt 1: strict JSON parse
  let parsed: any = null;
  try {
    parsed = JSON.parse(jsonText);
  } catch (_strictErr) {
    // Attempt 2: repair common LLM JSON issues then re-parse
    try {
      const repaired = repairJson(jsonText);
      parsed = JSON.parse(repaired);
      console.log("[generate-summary] JSON parsed after repair");
    } catch (_repairErr) {
      // Attempt 3: regex-based fallback extraction
      console.warn(
        `[generate-summary] JSON parse failed even after repair. Raw (first 500): ${cleaned.slice(0, 500)}`,
      );
      const fallbackSummary = extractFallbackSummary(cleaned);
      const fallbackFollowUps = extractFallbackFollowUps(cleaned);
      return {
        output: {
          human_summary: fallbackSummary,
          follow_ups: fallbackFollowUps,
        },
        parseMode: "fallback_summary",
        parseError: (_repairErr as Error)?.message || "json_parse_failed",
      };
    }
  }

  const humanSummary = truncate(String(parsed?.human_summary || "").trim(), 2500);
  const followUps = Array.isArray(parsed?.follow_ups) ? parsed.follow_ups : [];

  return {
    output: {
      human_summary: humanSummary,
      follow_ups: normalizeFollowUps(followUps),
    },
    parseMode: "strict_json",
    parseError: null,
  };
}

function buildPrompt(input: {
  interactionId: string;
  contactName: string | null;
  ownerName: string | null;
  projectName: string | null;
  transcript: string;
  spans: ConversationSpanRow[];
  attributionsBySpan: Map<string, SpanAttributionRow>;
}): string {
  const spanLines = input.spans.slice(0, MAX_PROMPT_SPANS).map((span) => {
    const attribution = input.attributionsBySpan.get(span.id);
    const attributionSummary = attribution
      ? `decision=${attribution.decision || "unknown"}, confidence=${
        attribution.confidence ?? "n/a"
      }, applied_project_id=${attribution.applied_project_id || "null"}`
      : "no_attribution_row";
    return `- span_index=${span.span_index} span_id=${span.id}\n  attribution: ${attributionSummary}\n  text: "${
      truncate(span.transcript_segment || "", MAX_SPAN_CHARS)
    }"`;
  }).join("\n");

  return [
    `INTERACTION_ID: ${input.interactionId}`,
    `CONTACT_NAME: ${input.contactName || "unknown"}`,
    `OWNER_NAME: ${input.ownerName || "unknown"}`,
    `PROJECT_NAME: ${input.projectName || "unknown"}`,
    "",
    "SPAN SNAPSHOT:",
    spanLines || "- no spans found",
    "",
    "FULL TRANSCRIPT (truncated):",
    truncate(input.transcript, MAX_TRANSCRIPT_CHARS),
  ].join("\n");
}

const SYSTEM_PROMPT = `You are a call summarization assistant for a construction workflow.\n` +
  `Return strict JSON only (no markdown).\n` +
  `Generate:\n` +
  `1) human_summary: plain-English summary in 2-4 sentences.\n` +
  `2) follow_ups: array of actionable follow-up items extracted from the call.\n` +
  `Each follow_up item must include:\n` +
  `- title (short)\n` +
  `- action (clear next step)\n` +
  `- owner (person/role or null)\n` +
  `- due_hint (date/time phrase or null)\n` +
  `- priority (low|medium|high)\n` +
  `- evidence_quote (short exact quote if available, else null)\n` +
  `- span_index_hint (integer if clear, else null)\n` +
  `Do not invent facts that are absent from transcript evidence.`;

async function callLlm(
  userPrompt: string,
  modelConfig: { modelId: string; maxTokens: number; temperature: number },
): Promise<
  { output: ModelOutput; tokensUsed: number; parseMode: "strict_json" | "fallback_summary"; parseError: string | null }
> {
  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) {
    throw new Error("config_missing: OPENAI_API_KEY not set");
  }

  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${openaiKey}`,
    },
    body: JSON.stringify({
      model: modelConfig.modelId,
      max_tokens: modelConfig.maxTokens,
      temperature: modelConfig.temperature,
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userPrompt },
      ],
    }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`openai_${resp.status}: ${truncate(errText, 240)}`);
  }

  const payload = await resp.json();
  const rawContent = payload?.choices?.[0]?.message?.content || "";
  if (!rawContent) {
    throw new Error("openai_empty_response");
  }
  const parsed = parseModelOutput(rawContent);
  const output = parsed.output;
  if (!output.human_summary) {
    throw new Error("openai_invalid_output: missing_human_summary");
  }

  const tokensUsed = (payload?.usage?.prompt_tokens || 0) + (payload?.usage?.completion_tokens || 0);
  return { output, tokensUsed, parseMode: parsed.parseMode, parseError: parsed.parseError };
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const edgeSecretHeader = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");

  let body: any;
  try {
    body = await req.json();
  } catch {
    await logDiagnostic("INPUT_INVALID", { reason: "invalid_json_body" }, "warning");
    return new Response(
      JSON.stringify({ ok: false, error: "invalid_json", version: GENERATE_SUMMARY_VERSION }),
      { status: 400, headers: jsonHeaders },
    );
  }

  const hasValidEdgeSecret = expectedSecret &&
    edgeSecretHeader === expectedSecret;

  if (!hasValidEdgeSecret) {
    await logDiagnostic("AUTH_FAILED", {
      reason: "edge_secret_mismatch",
      has_expected_secret: Boolean(expectedSecret),
      edge_secret_present: Boolean(edgeSecretHeader),
      edge_secret_len: edgeSecretHeader?.length || 0,
    });
    return new Response(
      JSON.stringify({
        ok: false,
        error: "unauthorized",
        error_code: "auth_failed",
        hint: "Requires X-Edge-Secret matching EDGE_SHARED_SECRET",
        version: GENERATE_SUMMARY_VERSION,
      }),
      { status: 401, headers: jsonHeaders },
    );
  }

  const interactionId = body.interaction_id;
  const dryRun = body.dry_run === true;

  if (!interactionId) {
    await logDiagnostic("INPUT_INVALID", { reason: "missing_interaction_id" }, "warning");
    return new Response(
      JSON.stringify({ ok: false, error: "missing_interaction_id", version: GENERATE_SUMMARY_VERSION }),
      { status: 400, headers: jsonHeaders },
    );
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  let modelConfig: {
    modelId: string;
    maxTokens: number;
    temperature: number;
    source: "pipeline_model_config" | "default";
  } = {
    modelId: DEFAULT_MODEL_ID,
    maxTokens: DEFAULT_MAX_TOKENS,
    temperature: DEFAULT_TEMPERATURE,
    source: "default",
  };

  let auditId: number | null = null;
  try {
    const { data: auditRow } = await db
      .from("event_audit")
      .insert({
        interaction_id: interactionId,
        gate_status: "STARTED",
        gate_reasons: [],
        source_system: `edge_${GENERATE_SUMMARY_VERSION}`,
        source_run_id: `generate-summary-${Date.now()}`,
        pipeline_version: GENERATE_SUMMARY_VERSION,
        processed_by: "generate-summary",
        persisted_to_calls_raw: false,
      })
      .select("id")
      .maybeSingle();
    auditId = auditRow?.id ?? null;
  } catch (e: any) {
    console.warn(`[generate-summary] event_audit STARTED insert failed: ${e?.message}`);
  }

  try {
    modelConfig = await getModelConfigCached(db, {
      functionName: "generate-summary",
      modelId: DEFAULT_MODEL_ID,
      maxTokens: DEFAULT_MAX_TOKENS,
      temperature: DEFAULT_TEMPERATURE,
    });

    const { data: interaction, error: interactionErr } = await db
      .from("interactions")
      .select(
        "interaction_id,contact_name,owner_name,project_id,event_at_utc,human_summary,ai_scheduler_json",
      )
      .eq("interaction_id", interactionId)
      .maybeSingle();

    if (interactionErr || !interaction) {
      await logDiagnostic("INPUT_INVALID", {
        reason: "interaction_not_found",
        interaction_id: interactionId,
        detail: interactionErr?.message || null,
      }, "warning");
      return new Response(
        JSON.stringify({
          ok: false,
          error: "interaction_not_found",
          interaction_id: interactionId,
          detail: interactionErr?.message || null,
          version: GENERATE_SUMMARY_VERSION,
        }),
        { status: 404, headers: jsonHeaders },
      );
    }

    // Intentionally ignore any upstream summary fields (e.g. Beside/Zapier summary).
    // Summary must be synthesized fresh from transcript + spans + attributions.
    const { data: callsRaw, error: callsRawErr } = await db
      .from("calls_raw")
      .select("transcript")
      .eq("interaction_id", interactionId)
      .maybeSingle();
    if (callsRawErr) {
      console.warn(`[generate-summary] calls_raw lookup warning: ${callsRawErr.message}`);
    }

    let projectName: string | null = null;
    if (interaction.project_id) {
      const { data: project } = await db
        .from("projects")
        .select("name")
        .eq("id", interaction.project_id)
        .maybeSingle();
      projectName = project?.name || null;
    }

    const { data: spans, error: spansErr } = await db
      .from("conversation_spans")
      .select("id,span_index,transcript_segment,word_count")
      .eq("interaction_id", interactionId)
      .eq("is_superseded", false)
      .order("span_index", { ascending: true });

    if (spansErr) {
      throw new Error(`spans_query_failed: ${spansErr.message}`);
    }

    const spanRows = (spans || []) as ConversationSpanRow[];
    const transcriptFromSpans = spanRows
      .map((span) => span.transcript_segment || "")
      .filter(Boolean)
      .join("\n\n");

    const transcript = callsRaw?.transcript || transcriptFromSpans;
    if (!transcript || transcript.trim().length < 20) {
      await logDiagnostic("INPUT_INVALID", {
        reason: "transcript_not_found",
        interaction_id: interactionId,
      }, "warning");
      return new Response(
        JSON.stringify({
          ok: false,
          error: "transcript_not_found",
          interaction_id: interactionId,
          version: GENERATE_SUMMARY_VERSION,
        }),
        { status: 400, headers: jsonHeaders },
      );
    }

    const spanIds = spanRows.map((span) => span.id);
    const attributionsBySpan = new Map<string, SpanAttributionRow>();
    if (spanIds.length > 0) {
      const { data: attributionRows, error: attrErr } = await db
        .from("span_attributions")
        .select(
          "span_id,project_id,applied_project_id,decision,confidence,reasoning,anchors,attributed_at",
        )
        .in("span_id", spanIds)
        .order("attributed_at", { ascending: false });
      if (attrErr) {
        console.warn(`[generate-summary] span_attributions query warning: ${attrErr.message}`);
      } else {
        for (const row of (attributionRows || []) as SpanAttributionRow[]) {
          if (!attributionsBySpan.has(row.span_id)) {
            attributionsBySpan.set(row.span_id, row);
          }
        }
      }
    }

    const prompt = buildPrompt({
      interactionId,
      contactName: interaction.contact_name,
      ownerName: interaction.owner_name,
      projectName,
      transcript,
      spans: spanRows,
      attributionsBySpan,
    });

    const { output, tokensUsed, parseMode, parseError } = await callLlm(prompt, modelConfig);
    if (parseMode === "fallback_summary") {
      await logDiagnostic("MODEL_PARSE_ERROR", {
        interaction_id: interactionId,
        parse_mode: parseMode,
        parse_error: parseError,
        model_id: modelConfig.modelId,
        model_source: modelConfig.source,
        prompt_version: PROMPT_VERSION,
        summary_chars: output.human_summary.length,
      }, "warning");
    }

    const schedulerPayload = output.follow_ups.map((item, idx) => ({
      idx,
      title: item.title,
      action: item.action,
      owner: item.owner,
      due_hint: item.due_hint,
      priority: item.priority,
      evidence_quote: item.evidence_quote,
      span_index_hint: item.span_index_hint,
      source: "generate-summary",
      prompt_version: PROMPT_VERSION,
      generated_at_utc: new Date().toISOString(),
    }));

    if (!dryRun) {
      const { error: updateErr } = await db
        .from("interactions")
        .update({
          human_summary: output.human_summary,
          ai_scheduler_json: schedulerPayload,
          has_scheduler_items: schedulerPayload.length > 0,
          scheduler_item_count: schedulerPayload.length,
        })
        .eq("interaction_id", interactionId);
      if (updateErr) {
        throw new Error(`interactions_update_failed: ${updateErr.message}`);
      }
    }

    if (auditId) {
      try {
        await db.from("event_audit").update({
          gate_status: "PASS",
          gate_reasons: [],
        }).eq("id", auditId);
      } catch (e: any) {
        console.warn(`[generate-summary] event_audit PASS update failed: ${e?.message}`);
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        version: GENERATE_SUMMARY_VERSION,
        prompt_version: PROMPT_VERSION,
        model_id: modelConfig.modelId,
        model_source: modelConfig.source,
        interaction_id: interactionId,
        dry_run: dryRun,
        summary_chars: output.human_summary.length,
        scheduler_item_count: schedulerPayload.length,
        tokens_used: tokensUsed,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: jsonHeaders },
    );
  } catch (e: any) {
    await logDiagnostic("PIPELINE_ERROR", {
      interaction_id: interactionId,
      error: truncate(e?.message || "unknown_error", 600),
      model_id: modelConfig.modelId,
      model_source: modelConfig.source,
      prompt_version: PROMPT_VERSION,
      ms: Date.now() - t0,
    });

    if (auditId) {
      try {
        await db.from("event_audit").update({
          gate_status: "ERROR",
          gate_reasons: [truncate(e?.message || "unknown", 300)],
        }).eq("id", auditId);
      } catch (updateErr: any) {
        console.warn(`[generate-summary] event_audit ERROR update failed: ${updateErr?.message}`);
      }
    }

    return new Response(
      JSON.stringify({
        ok: false,
        version: GENERATE_SUMMARY_VERSION,
        interaction_id: interactionId,
        error: e?.message || "unknown_error",
        ms: Date.now() - t0,
      }),
      { status: 500, headers: jsonHeaders },
    );
  }
});
