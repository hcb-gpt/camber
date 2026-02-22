/**
 * evidence-assembler Edge Function v0.1.0
 * Pre-layer: gathers supplemental evidence via tool wrappers, produces
 * a structured evidence brief per candidate project.
 *
 * Read-only, fail-open, gated by segment-call.
 * Uses JSON-in-prompt + parseLlmJson pattern (no Claude tool-use API).
 *
 * @version 0.1.0
 * @date 2026-02-19
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk@0.39.0";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { parseLlmJson } from "../_shared/llm_json.ts";

const FUNCTION_VERSION = "v0.1.0";
const MODEL_ID = "claude-sonnet-4-5-20250514";
const MAX_TOKENS = 2048;

// Budget caps
const MAX_ITERATIONS = 4;
const MAX_TOOL_CALLS = 8;
const WALL_CLOCK_MS = 25_000;
const LLM_TIMEOUT_MS = 12_000;
const TOOL_TIMEOUT_MS = 8_000;

// ============================================================
// TYPES
// ============================================================

interface ToolCallLog {
  tool_name: string;
  input_params: Record<string, unknown>;
  rows_returned: number;
  latency_ms: number;
  timestamp_utc: string;
}

interface EvidenceReceipt {
  source_type: string;
  source_id: string;
  snippet?: string;
  score?: number;
}

interface DimensionAssessment {
  verdict: "supports" | "contradicts" | "neutral" | "missing";
  receipts: EvidenceReceipt[];
  reason_code: string;
}

interface CandidateBrief {
  project_id: string;
  project_name: string;
  dimensions: {
    transcript_anchor: DimensionAssessment;
    contact_identity: DimensionAssessment;
    journal_claims: DimensionAssessment;
    chain_continuity: DimensionAssessment;
    email_context: DimensionAssessment;
    geo_signal: DimensionAssessment;
    alias_uniqueness: DimensionAssessment;
    world_model_facts: DimensionAssessment;
  };
  corroboration_count: number;
  contradiction_count: number;
  missing_count: number;
}

interface EvidenceBrief {
  span_id: string;
  assembled_at_utc: string;
  assembler_version: string;
  assembler_model: string;
  iterations_used: number;
  tool_calls_used: number;
  wall_clock_ms: number;
  gating_reasons: string[];
  transcript_source: "deepgram";
  candidates: CandidateBrief[];
  missing_evidence: Array<{
    dimension: string;
    reason: string;
    could_resolve: boolean;
    attempted_tools: string[];
  }>;
}

// ============================================================
// TOOL WHITELIST
// ============================================================

const SAFE_TOOL_WHITELIST = new Set([
  "checkAliasUniqueness",
  "fetchContactProjects",
  "fetchJournalClaims",
  "fetchOpenLoops",
  "fetchChainHistory",
  "fetchPriorAttributions",
  "fetchProjectFacts",
  "scanTranscriptProjects",
  "fetchEmailContext",
  "checkContactFanout",
]);

// ============================================================
// TOOL WRAPPERS
// ============================================================

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`tool_timeout_${ms}ms`)), ms)),
  ]);
}

async function checkAliasUniqueness(
  db: any,
  params: { alias: string },
): Promise<{ rows: any[]; count: number }> {
  const { data, error } = await db
    .from("v_project_alias_lookup")
    .select("project_id, project_name, alias_term, match_type")
    .ilike("alias_term", params.alias)
    .limit(10);
  if (error) throw new Error(`alias_lookup_failed: ${error.message}`);
  return { rows: data || [], count: (data || []).length };
}

async function fetchContactProjects(
  db: any,
  params: { contact_id: string },
): Promise<{ rows: any[]; count: number }> {
  const { data: contacts, error: contactErr } = await db
    .from("project_contacts")
    .select("project_id, role")
    .eq("contact_id", params.contact_id)
    .limit(12);
  if (contactErr) throw new Error(`contact_projects_failed: ${contactErr.message}`);

  const { data: affinity, error: affinityErr } = await db
    .from("correspondent_project_affinity")
    .select("project_id, affinity_weight")
    .eq("contact_id", params.contact_id)
    .order("affinity_weight", { ascending: false })
    .limit(12);
  if (affinityErr) throw new Error(`affinity_failed: ${affinityErr.message}`);

  const combined = [
    ...(contacts || []).map((c: any) => ({ ...c, source: "project_contacts" })),
    ...(affinity || []).map((a: any) => ({ ...a, source: "affinity" })),
  ];
  return { rows: combined, count: combined.length };
}

async function fetchJournalClaims(
  db: any,
  params: { project_id: string },
): Promise<{ rows: any[]; count: number }> {
  const { data, error } = await db
    .from("journal_claims")
    .select("id, project_id, claim_type, claim_text, epistemic_status, created_at")
    .eq("project_id", params.project_id)
    .eq("epistemic_status", "confirmed")
    .order("created_at", { ascending: false })
    .limit(10);
  if (error) throw new Error(`journal_claims_failed: ${error.message}`);
  return { rows: data || [], count: (data || []).length };
}

async function fetchOpenLoops(
  db: any,
  params: { project_id: string },
): Promise<{ rows: any[]; count: number }> {
  const { data, error } = await db
    .from("journal_open_loops")
    .select("id, project_id, loop_type, description, status")
    .eq("project_id", params.project_id)
    .eq("status", "open")
    .limit(5);
  if (error) throw new Error(`open_loops_failed: ${error.message}`);
  return { rows: data || [], count: (data || []).length };
}

async function fetchChainHistory(
  db: any,
  params: { contact_id: string },
): Promise<{ rows: any[]; count: number }> {
  const cutoff = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
  const { data, error } = await db
    .from("call_chains")
    .select("id, contact_id, interaction_id, chain_type, created_at")
    .eq("contact_id", params.contact_id)
    .gte("created_at", cutoff)
    .order("created_at", { ascending: false })
    .limit(5);
  if (error) throw new Error(`chain_history_failed: ${error.message}`);
  return { rows: data || [], count: (data || []).length };
}

async function fetchPriorAttributions(
  db: any,
  params: { contact_id: string },
): Promise<{ rows: any[]; count: number }> {
  const cutoff = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
  // Join through conversation_spans → interactions to get contact's prior attributions
  const { data, error } = await db
    .rpc("get_contact_prior_attributions", {
      p_contact_id: params.contact_id,
      p_since: cutoff,
      p_limit: 5,
    });
  if (error) {
    // Fallback: direct query if RPC doesn't exist
    const { data: fallback, error: fallbackErr } = await db
      .from("span_attributions")
      .select("span_id, project_id, decision, confidence, applied_project_id, attributed_at")
      .order("attributed_at", { ascending: false })
      .limit(5);
    if (fallbackErr) throw new Error(`prior_attributions_failed: ${fallbackErr.message}`);
    return { rows: fallback || [], count: (fallback || []).length };
  }
  return { rows: data || [], count: (data || []).length };
}

async function fetchProjectFacts(
  db: any,
  params: { project_id: string; as_of: string },
): Promise<{ rows: any[]; count: number }> {
  const { data, error } = await db
    .from("project_facts")
    .select("id, project_id, fact_kind, fact_text, fact_as_of_at, source_type")
    .eq("project_id", params.project_id)
    .lte("fact_as_of_at", params.as_of)
    .order("fact_as_of_at", { ascending: false })
    .limit(20);
  if (error) throw new Error(`project_facts_failed: ${error.message}`);
  return { rows: data || [], count: (data || []).length };
}

async function scanTranscriptProjects(
  db: any,
  params: { transcript: string },
): Promise<{ rows: any[]; count: number }> {
  const { data, error } = await db.rpc("scan_transcript_for_projects", {
    p_transcript: params.transcript.slice(0, 5000),
  });
  if (error) throw new Error(`scan_transcript_failed: ${error.message}`);
  return { rows: (data || []).slice(0, 15), count: Math.min((data || []).length, 15) };
}

async function fetchEmailContext(
  params: { contact_id: string },
): Promise<{ rows: any[]; count: number }> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET")!;
  const url = `${supabaseUrl}/functions/v1/gmail-context-lookup`;

  const resp = await withTimeout(
    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Edge-Secret": edgeSecret,
        "X-Source": "evidence-assembler",
      },
      body: JSON.stringify({
        contact_id: params.contact_id,
        max_results: 5,
        lookback_days: 30,
      }),
    }),
    TOOL_TIMEOUT_MS,
  );

  if (!resp.ok) {
    throw new Error(`email_context_http_${resp.status}`);
  }
  const data = await resp.json();
  const emails = Array.isArray(data.emails) ? data.emails.slice(0, 5) : [];
  return { rows: emails, count: emails.length };
}

async function checkContactFanout(
  db: any,
  params: { contact_id: string },
): Promise<{ rows: any[]; count: number }> {
  const { data, error } = await db
    .from("contact_fanout")
    .select("contact_id, fanout_class, effective_fanout, project_count")
    .eq("contact_id", params.contact_id)
    .limit(1);
  if (error) throw new Error(`contact_fanout_failed: ${error.message}`);
  return { rows: data || [], count: (data || []).length };
}

// ============================================================
// TOOL DISPATCH
// ============================================================

function dispatchTool(
  name: string,
  params: any,
  db: any,
): Promise<{ rows: any[]; count: number }> {
  if (!SAFE_TOOL_WHITELIST.has(name)) {
    throw new Error(`BLOCKED: tool "${name}" not in assembler whitelist`);
  }

  switch (name) {
    case "checkAliasUniqueness":
      return withTimeout(checkAliasUniqueness(db, params), TOOL_TIMEOUT_MS);
    case "fetchContactProjects":
      return withTimeout(fetchContactProjects(db, params), TOOL_TIMEOUT_MS);
    case "fetchJournalClaims":
      return withTimeout(fetchJournalClaims(db, params), TOOL_TIMEOUT_MS);
    case "fetchOpenLoops":
      return withTimeout(fetchOpenLoops(db, params), TOOL_TIMEOUT_MS);
    case "fetchChainHistory":
      return withTimeout(fetchChainHistory(db, params), TOOL_TIMEOUT_MS);
    case "fetchPriorAttributions":
      return withTimeout(fetchPriorAttributions(db, params), TOOL_TIMEOUT_MS);
    case "fetchProjectFacts":
      return withTimeout(fetchProjectFacts(db, params), TOOL_TIMEOUT_MS);
    case "scanTranscriptProjects":
      return withTimeout(scanTranscriptProjects(db, params), TOOL_TIMEOUT_MS);
    case "fetchEmailContext":
      return withTimeout(fetchEmailContext(params), TOOL_TIMEOUT_MS);
    case "checkContactFanout":
      return withTimeout(checkContactFanout(db, params), TOOL_TIMEOUT_MS);
    default:
      throw new Error(`UNIMPLEMENTED: tool "${name}"`);
  }
}

// ============================================================
// ASSEMBLER LOOP PROMPT
// ============================================================

const ASSEMBLER_SYSTEM_PROMPT = `You are an evidence-assembler for the Camber call pipeline.
Your job is to gather supplemental evidence for project attribution candidates.

You receive a context_package containing candidates, contact info, and transcript.
For each iteration, decide which tools to call to fill in missing evidence dimensions.

AVAILABLE TOOLS:
- checkAliasUniqueness({ alias: string }) - Check if an alias matches one or many projects
- fetchContactProjects({ contact_id: string }) - Get all projects for a contact
- fetchJournalClaims({ project_id: string }) - Get recent journal claims for a project
- fetchOpenLoops({ project_id: string }) - Get open loops for a project
- fetchChainHistory({ contact_id: string }) - Get recent call chains for a contact (48h)
- fetchPriorAttributions({ contact_id: string }) - Get recent span attributions for a contact (48h)
- fetchProjectFacts({ project_id: string, as_of: string }) - Get project facts as of a date
- scanTranscriptProjects({ transcript: string }) - Scan transcript for project mentions
- fetchEmailContext({ contact_id: string }) - Get recent email context for a contact
- checkContactFanout({ contact_id: string }) - Get fanout classification for a contact

EVIDENCE DIMENSIONS (per candidate):
1. transcript_anchor - Project mentioned in transcript?
2. contact_identity - Contact's relationship to this project?
3. journal_claims - Journal claims matching transcript topic?
4. chain_continuity - Prior calls from this contact attributed here?
5. email_context - Email evidence linking contact to project?
6. geo_signal - Geographic proximity?
7. alias_uniqueness - Is the alias unique to this project?
8. world_model_facts - Project facts corroborating?

OUTPUT FORMAT (JSON):
When you need more tools:
{
  "status": "need_tools",
  "tool_requests": [
    { "tool": "checkAliasUniqueness", "params": { "alias": "..." } },
    { "tool": "fetchChainHistory", "params": { "contact_id": "..." } }
  ],
  "reasoning": "why these tools"
}

When done gathering:
{
  "status": "done",
  "candidates": [
    {
      "project_id": "uuid",
      "project_name": "name",
      "dimensions": {
        "transcript_anchor": { "verdict": "supports|contradicts|neutral|missing", "reason_code": "exact_name_in_transcript", "receipts": [{ "source_type": "interaction", "source_id": "...", "snippet": "max 120 chars" }] },
        "contact_identity": { "verdict": "...", "reason_code": "...", "receipts": [...] },
        "journal_claims": { "verdict": "...", "reason_code": "...", "receipts": [...] },
        "chain_continuity": { "verdict": "...", "reason_code": "...", "receipts": [...] },
        "email_context": { "verdict": "...", "reason_code": "...", "receipts": [...] },
        "geo_signal": { "verdict": "...", "reason_code": "...", "receipts": [...] },
        "alias_uniqueness": { "verdict": "...", "reason_code": "...", "receipts": [...] },
        "world_model_facts": { "verdict": "...", "reason_code": "...", "receipts": [...] }
      },
      "corroboration_count": 3,
      "contradiction_count": 0,
      "missing_count": 2
    }
  ],
  "missing_evidence": [
    { "dimension": "email_context", "reason": "contact_id_null", "could_resolve": false, "attempted_tools": [] }
  ]
}

RULES:
- Request only tools that will fill missing/weak dimensions
- Never request the same tool with the same params twice
- Minimize tool calls — only call what adds new information
- Use "done" when all knowable dimensions are assessed
- Verdicts must be evidence-backed — "missing" is better than guessing`;

function buildAssemblerUserPrompt(
  contextPackage: any,
  iteration: number,
  priorToolResults: Array<{ tool: string; params: any; result: any }>,
): string {
  const candidates = (contextPackage.candidates || [])
    .map((c: any) => ({
      project_id: c.project_id,
      project_name: c.project_name,
      address: c.address,
      client_name: c.client_name,
      aliases: c.aliases,
      status: c.status,
      evidence: {
        sources: c.evidence?.sources,
        source_strength: c.evidence?.source_strength,
        assigned: c.evidence?.assigned,
        alias_matches: c.evidence?.alias_matches,
        geo_signal: c.evidence?.geo_signal,
        geo_distance_km: c.evidence?.geo_distance_km,
      },
    }));

  const contact = {
    contact_id: contextPackage.contact?.contact_id,
    contact_name: contextPackage.contact?.contact_name,
    fanout_class: contextPackage.contact?.fanout_class,
    effective_fanout: contextPackage.contact?.effective_fanout,
    floater_flag: contextPackage.contact?.floater_flag,
  };

  const transcript = (contextPackage.span?.transcript_text || "").slice(0, 3000);

  let prompt = `ITERATION: ${iteration} of ${MAX_ITERATIONS}

CONTEXT PACKAGE SUMMARY:
- Contact: ${JSON.stringify(contact)}
- Candidates (${candidates.length}): ${JSON.stringify(candidates)}
- Transcript (first 3000 chars): """${transcript}"""
- Journal context available: ${
    Array.isArray(contextPackage.project_journal) && contextPackage.project_journal.length > 0 ? "yes" : "no"
  }
- Email context available: ${
    Array.isArray(contextPackage.email_context) && contextPackage.email_context.length > 0 ? "yes" : "no"
  }
- Place mentions: ${Array.isArray(contextPackage.place_mentions) ? contextPackage.place_mentions.length : 0}`;

  if (priorToolResults.length > 0) {
    prompt += `\n\nPRIOR TOOL RESULTS (${priorToolResults.length} calls so far):`;
    for (const tr of priorToolResults) {
      const resultSummary = JSON.stringify(tr.result).slice(0, 500);
      prompt += `\n- ${tr.tool}(${JSON.stringify(tr.params)}): ${resultSummary}`;
    }
  }

  prompt += `\n\nAnalyze the available evidence and either request more tools or produce the final evidence brief.`;
  return prompt;
}

// ============================================================
// BRIEF ENRICHMENT (inject brief into context_package candidates)
// ============================================================

function enrichContextPackage(
  contextPackage: any,
  brief: EvidenceBrief,
): any {
  const enriched = JSON.parse(JSON.stringify(contextPackage));
  enriched.evidence_brief = brief;

  const briefByProject = new Map<string, CandidateBrief>();
  for (const cb of brief.candidates) {
    briefByProject.set(cb.project_id, cb);
  }

  if (Array.isArray(enriched.candidates)) {
    for (const candidate of enriched.candidates) {
      const cb = briefByProject.get(candidate.project_id);
      if (cb) {
        candidate.evidence_brief_dimensions = cb.dimensions;
        candidate.corroboration_count = cb.corroboration_count;
        candidate.contradiction_count = cb.contradiction_count;
      }
    }
  }

  return enriched;
}

// ============================================================
// MAIN HANDLER
// ============================================================

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Auth
  const auth = requireEdgeSecret(req, ["segment-call"]);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code!);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { context_package, span_id } = body;
  if (!context_package || !span_id) {
    return new Response(
      JSON.stringify({ error: "missing_context_package_or_span_id" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const anthropic = new Anthropic({
    apiKey: Deno.env.get("ANTHROPIC_API_KEY")!,
  });

  const toolCallLog: ToolCallLog[] = [];
  const priorToolResults: Array<{ tool: string; params: any; result: any }> = [];
  let iterationsUsed = 0;
  let totalToolCalls = 0;

  try {
    // Assembler loop
    for (let iter = 1; iter <= MAX_ITERATIONS; iter++) {
      // Budget check: wall clock
      if (Date.now() - t0 > WALL_CLOCK_MS) {
        console.warn(`[evidence-assembler] Wall clock budget exhausted at iteration ${iter}`);
        break;
      }

      iterationsUsed = iter;

      // Ask Sonnet what to do
      const userPrompt = buildAssemblerUserPrompt(context_package, iter, priorToolResults);

      const llmResponse = await Promise.race([
        anthropic.messages.create({
          model: MODEL_ID,
          max_tokens: MAX_TOKENS,
          system: ASSEMBLER_SYSTEM_PROMPT,
          messages: [{ role: "user", content: userPrompt }],
        }),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error("llm_timeout")), LLM_TIMEOUT_MS)),
      ]);

      const textBlock = (llmResponse as any).content?.find((b: any) => b.type === "text");
      const responseText = textBlock?.text || "";
      const parsed = parseLlmJson<any>(responseText).value;

      if (parsed.status === "done") {
        // Build the evidence brief from Sonnet's final output
        const brief: EvidenceBrief = {
          span_id,
          assembled_at_utc: new Date().toISOString(),
          assembler_version: FUNCTION_VERSION,
          assembler_model: MODEL_ID,
          iterations_used: iterationsUsed,
          tool_calls_used: totalToolCalls,
          wall_clock_ms: Date.now() - t0,
          gating_reasons: body.gating_reasons || [],
          transcript_source: "deepgram",
          candidates: (parsed.candidates || []).map((c: any) => ({
            project_id: c.project_id,
            project_name: c.project_name,
            dimensions: c.dimensions || {},
            corroboration_count: c.corroboration_count ?? 0,
            contradiction_count: c.contradiction_count ?? 0,
            missing_count: c.missing_count ?? 0,
          })),
          missing_evidence: parsed.missing_evidence || [],
        };

        const enriched = enrichContextPackage(context_package, brief);

        return new Response(
          JSON.stringify({
            ok: true,
            evidence_brief: brief,
            enriched_context_package: enriched,
            iterations_used: iterationsUsed,
            tool_calls_used: totalToolCalls,
            wall_clock_ms: Date.now() - t0,
            tool_call_log: toolCallLog,
            version: FUNCTION_VERSION,
            ms: Date.now() - t0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }

      // Dispatch tool calls
      if (parsed.status === "need_tools" && Array.isArray(parsed.tool_requests)) {
        for (const toolReq of parsed.tool_requests) {
          if (totalToolCalls >= MAX_TOOL_CALLS) {
            console.warn("[evidence-assembler] Tool call budget exhausted");
            break;
          }
          if (Date.now() - t0 > WALL_CLOCK_MS) break;

          const toolT0 = Date.now();
          totalToolCalls++;

          try {
            const result = await dispatchTool(toolReq.tool, toolReq.params || {}, db);

            const logEntry: ToolCallLog = {
              tool_name: toolReq.tool,
              input_params: toolReq.params || {},
              rows_returned: result.count,
              latency_ms: Date.now() - toolT0,
              timestamp_utc: new Date().toISOString(),
            };
            toolCallLog.push(logEntry);

            priorToolResults.push({
              tool: toolReq.tool,
              params: toolReq.params || {},
              result: result.rows,
            });
          } catch (toolErr: any) {
            const logEntry: ToolCallLog = {
              tool_name: toolReq.tool,
              input_params: toolReq.params || {},
              rows_returned: 0,
              latency_ms: Date.now() - toolT0,
              timestamp_utc: new Date().toISOString(),
            };
            toolCallLog.push(logEntry);

            priorToolResults.push({
              tool: toolReq.tool,
              params: toolReq.params || {},
              result: { error: toolErr.message },
            });

            console.warn(`[evidence-assembler] Tool ${toolReq.tool} failed: ${toolErr.message}`);
          }
        }
      }
    }

    // If we exhausted iterations without "done", produce a partial brief
    // by asking Sonnet one final time to synthesize what we have
    const finalPrompt = buildAssemblerUserPrompt(context_package, MAX_ITERATIONS + 1, priorToolResults) +
      "\n\nBUDGET EXHAUSTED. You MUST output status='done' with your best assessment now.";

    const finalResponse = await Promise.race([
      anthropic.messages.create({
        model: MODEL_ID,
        max_tokens: MAX_TOKENS,
        system: ASSEMBLER_SYSTEM_PROMPT,
        messages: [{ role: "user", content: finalPrompt }],
      }),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("llm_timeout_final")), LLM_TIMEOUT_MS)),
    ]);

    const finalText = (finalResponse as any).content?.find((b: any) => b.type === "text")?.text || "";
    const finalParsed = parseLlmJson<any>(finalText).value;

    const brief: EvidenceBrief = {
      span_id,
      assembled_at_utc: new Date().toISOString(),
      assembler_version: FUNCTION_VERSION,
      assembler_model: MODEL_ID,
      iterations_used: iterationsUsed,
      tool_calls_used: totalToolCalls,
      wall_clock_ms: Date.now() - t0,
      gating_reasons: body.gating_reasons || [],
      transcript_source: "deepgram",
      candidates: (finalParsed.candidates || []).map((c: any) => ({
        project_id: c.project_id,
        project_name: c.project_name,
        dimensions: c.dimensions || {},
        corroboration_count: c.corroboration_count ?? 0,
        contradiction_count: c.contradiction_count ?? 0,
        missing_count: c.missing_count ?? 0,
      })),
      missing_evidence: finalParsed.missing_evidence || [],
    };

    const enriched = enrichContextPackage(context_package, brief);

    return new Response(
      JSON.stringify({
        ok: true,
        evidence_brief: brief,
        enriched_context_package: enriched,
        iterations_used: iterationsUsed,
        tool_calls_used: totalToolCalls,
        wall_clock_ms: Date.now() - t0,
        tool_call_log: toolCallLog,
        version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e: any) {
    // Fail-open: return original context_package unchanged
    console.error(`[evidence-assembler] Fatal error (fail-open): ${e.message}`);
    return new Response(
      JSON.stringify({
        ok: false,
        error: e.message,
        enriched_context_package: context_package,
        evidence_brief: null,
        iterations_used: iterationsUsed,
        tool_calls_used: totalToolCalls,
        wall_clock_ms: Date.now() - t0,
        tool_call_log: toolCallLog,
        version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
});
