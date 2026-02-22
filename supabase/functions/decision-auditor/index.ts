/**
 * decision-auditor Edge Function v0.1.0
 * Post-layer: validates ai-router assign decisions against the evidence brief.
 * Can confirm or downgrade — never promotes.
 *
 * Read-only, fail-open, gated by segment-call.
 * Single-shot LLM call with optional deterministic pre-checks.
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
const MAX_TOKENS = 1024;

// Budget caps
const MAX_ITERATIONS = 2;
const MAX_TOOL_CALLS = 4;
const WALL_CLOCK_MS = 15_000;
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

interface AuditReport {
  span_id: string;
  auditor_version: string;
  auditor_model: string;
  verdict: "confirm" | "downgrade" | "escalate";
  reason_code?: string;
  reason_detail?: string;
  checks_performed: string[];
  alternative_candidate_id?: string;
  iterations_used: number;
  tool_calls_used: number;
  wall_clock_ms: number;
}

// ============================================================
// DETERMINISTIC PRE-CHECKS
// ============================================================

function normalizeForQuoteMatch(text: string): string {
  return (text || "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[""„‟''`"]/g, "")
    .replace(/[\-–—]/g, " ")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function verifyAnchorQuote(
  anchors: Array<{ quote: string; text: string; match_type: string }>,
  transcript: string,
): { verified: boolean; failed_count: number; checked_count: number } {
  if (!transcript || !anchors || anchors.length === 0) {
    return { verified: false, failed_count: 0, checked_count: 0 };
  }

  const transcriptNorm = normalizeForQuoteMatch(transcript);
  let checked = 0;
  let failed = 0;

  for (const anchor of anchors) {
    if (!anchor.quote || anchor.quote.length < 3) continue;
    checked++;
    const quoteNorm = normalizeForQuoteMatch(anchor.quote);
    if (!transcriptNorm.includes(quoteNorm)) {
      failed++;
    }
  }

  return {
    verified: checked > 0 && failed === 0,
    failed_count: failed,
    checked_count: checked,
  };
}

async function fetchAlternativeCandidates(
  db: any,
  transcript: string,
): Promise<{ rows: any[]; count: number }> {
  const { data, error } = await db.rpc("scan_transcript_for_projects", {
    p_transcript: (transcript || "").slice(0, 5000),
  });
  if (error) throw new Error(`scan_transcript_failed: ${error.message}`);
  return { rows: (data || []).slice(0, 15), count: Math.min((data || []).length, 15) };
}

// ============================================================
// AUDITOR PROMPT
// ============================================================

const AUDITOR_SYSTEM_PROMPT = `You are a decision-auditor for the Camber call pipeline.
You receive an ai-router decision (assign with project_id, confidence, anchors)
and an evidence brief, and you validate whether the assignment is justified.

YOUR POWERS:
- You can CONFIRM the assignment (evidence supports it)
- You can DOWNGRADE to review (evidence is insufficient or contradicted)
- You can ESCALATE to review with special flag (critical evidence missing)
- You can NEVER promote a review/none to assign
- You can NEVER change the assigned project_id — only confirm or downgrade

AUDIT CHECKS:
1. Contradiction check: Does the evidence brief show any "contradicts" dimensions
   for the assigned project that ai-router didn't address?
2. Alternative scan: Is there a candidate with higher corroboration_count and lower
   contradiction_count than the assigned project?
3. Anchor verification: Were the anchor quotes verified against the transcript?
4. Missing evidence: Does the assigned project have missing_count >= 4 (half the dimensions)?

OUTPUT FORMAT (JSON only):
{
  "verdict": "confirm | downgrade | escalate",
  "reason_code": "contradiction_ignored | stronger_alternative | anchor_fabrication | critical_missing_evidence | confirmed_clean",
  "reason_detail": "max 200 chars explaining the verdict",
  "checks_performed": ["contradiction_check", "alternative_scan", "anchor_verify", "missing_evidence_check"],
  "alternative_candidate_id": "uuid or null"
}

RULES:
- Default to "confirm" unless you find a specific problem
- "escalate" means downgrade to review + flag for investigation
- reason_detail must be factual, not speculative
- If anchor verification was provided, weight it heavily`;

function buildAuditorUserPrompt(
  enrichedContextPackage: any,
  aiRouterDecision: any,
  evidenceBrief: any,
  preCheckResults: {
    anchorVerification: { verified: boolean; failed_count: number; checked_count: number };
    alternativeCandidates: any[] | null;
  },
): string {
  const transcript = (enrichedContextPackage.span?.transcript_text || "").slice(0, 2000);

  let prompt = `AI-ROUTER DECISION:
- Decision: ${aiRouterDecision.decision}
- Project ID: ${aiRouterDecision.project_id}
- Confidence: ${aiRouterDecision.confidence}
- Anchors: ${JSON.stringify(aiRouterDecision.anchors || [])}
- Reason codes: ${JSON.stringify(aiRouterDecision.reason_codes || [])}

TRANSCRIPT (first 2000 chars):
"""${transcript}"""
`;

  if (evidenceBrief) {
    prompt += `\nEVIDENCE BRIEF:\n${JSON.stringify(evidenceBrief, null, 2).slice(0, 3000)}\n`;
  } else {
    prompt += `\nEVIDENCE BRIEF: Not available (assembler did not run)\n`;
  }

  prompt += `\nPRE-CHECK RESULTS:`;
  prompt += `\n- Anchor verification: ${JSON.stringify(preCheckResults.anchorVerification)}`;

  if (preCheckResults.alternativeCandidates) {
    prompt += `\n- Alternative candidates from transcript scan: ${
      JSON.stringify(preCheckResults.alternativeCandidates.slice(0, 5))
    }`;
  }

  prompt +=
    `\n\nAudit this assignment. Check for contradictions, stronger alternatives, anchor validity, and missing evidence.`;
  return prompt;
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

  const {
    enriched_context_package,
    ai_router_decision,
    evidence_brief,
    interaction_id,
    span_id,
    dry_run,
  } = body;

  if (!enriched_context_package || !ai_router_decision || !span_id) {
    return new Response(
      JSON.stringify({ error: "missing_required_fields" }),
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
  let toolCallsUsed = 0;

  try {
    // ── DETERMINISTIC PRE-CHECKS ────────────────────────────
    const transcript = enriched_context_package.span?.transcript_text || "";

    // Check 1: Verify anchor quotes exist in transcript
    const anchorVerification = verifyAnchorQuote(
      ai_router_decision.anchors || [],
      transcript,
    );

    // Check 2: Scan for alternative candidates (if budget allows)
    let alternativeCandidates: any[] | null = null;
    if (Date.now() - t0 < WALL_CLOCK_MS && toolCallsUsed < MAX_TOOL_CALLS) {
      const toolT0 = Date.now();
      toolCallsUsed++;
      try {
        const altResult = await Promise.race([
          fetchAlternativeCandidates(db, transcript),
          new Promise<never>((_, reject) => setTimeout(() => reject(new Error("tool_timeout")), TOOL_TIMEOUT_MS)),
        ]);
        alternativeCandidates = altResult.rows;
        toolCallLog.push({
          tool_name: "fetchAlternativeCandidates",
          input_params: { transcript_length: transcript.length },
          rows_returned: altResult.count,
          latency_ms: Date.now() - toolT0,
          timestamp_utc: new Date().toISOString(),
        });
      } catch (e: any) {
        toolCallLog.push({
          tool_name: "fetchAlternativeCandidates",
          input_params: { transcript_length: transcript.length },
          rows_returned: 0,
          latency_ms: Date.now() - toolT0,
          timestamp_utc: new Date().toISOString(),
        });
        console.warn(`[decision-auditor] Alternative candidates fetch failed: ${e.message}`);
      }
    }

    // ── LLM AUDIT PASS ──────────────────────────────────────
    const userPrompt = buildAuditorUserPrompt(
      enriched_context_package,
      ai_router_decision,
      evidence_brief,
      { anchorVerification, alternativeCandidates },
    );

    const llmResponse = await Promise.race([
      anthropic.messages.create({
        model: MODEL_ID,
        max_tokens: MAX_TOKENS,
        system: AUDITOR_SYSTEM_PROMPT,
        messages: [{ role: "user", content: userPrompt }],
      }),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("llm_timeout")), LLM_TIMEOUT_MS)),
    ]);

    const textBlock = (llmResponse as any).content?.find((b: any) => b.type === "text");
    const responseText = textBlock?.text || "";
    const parsed = parseLlmJson<any>(responseText).value;

    const verdict = ["confirm", "downgrade", "escalate"].includes(parsed.verdict) ? parsed.verdict : "confirm";

    const auditReport: AuditReport = {
      span_id,
      auditor_version: FUNCTION_VERSION,
      auditor_model: MODEL_ID,
      verdict,
      reason_code: parsed.reason_code || undefined,
      reason_detail: (parsed.reason_detail || "").slice(0, 200) || undefined,
      checks_performed: Array.isArray(parsed.checks_performed) ? parsed.checks_performed : [],
      alternative_candidate_id: parsed.alternative_candidate_id || undefined,
      iterations_used: 1,
      tool_calls_used: toolCallsUsed,
      wall_clock_ms: Date.now() - t0,
    };

    return new Response(
      JSON.stringify({
        ok: true,
        verdict: auditReport.verdict,
        audit_report: auditReport,
        iterations_used: 1,
        tool_calls_used: toolCallsUsed,
        wall_clock_ms: Date.now() - t0,
        tool_call_log: toolCallLog,
        version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e: any) {
    // Fail-open: return confirm verdict — don't block the pipeline
    console.error(`[decision-auditor] Fatal error (fail-open): ${e.message}`);
    return new Response(
      JSON.stringify({
        ok: false,
        error: e.message,
        verdict: "confirm",
        audit_report: null,
        iterations_used: 0,
        tool_calls_used: toolCallsUsed,
        wall_clock_ms: Date.now() - t0,
        tool_call_log: toolCallLog,
        version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
});
