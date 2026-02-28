/**
 * striking-detect Edge Function v1.0.0
 * Detects "striking" conversations — calls where something important is happening
 * beneath the surface: decisions, scope changes, financial signals, tension, etc.
 *
 * @version 1.0.0
 * @date 2026-02-09
 * @purpose Provide a separate perception channel alongside attribution
 *
 * DESIGN:
 * - Runs AFTER segmentation (called by segment-call as async fire-and-forget)
 * - Produces a striking score (0.0–1.0) and typed signals per span
 * - Does NOT affect attribution — this is a separate perception channel
 * - High-striking spans (>= 0.7) get surfaced for attention
 *
 * AUTH: X-Edge-Secret == EDGE_SHARED_SECRET (internal machine-to-machine)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getModelConfigCached } from "../_shared/model_config.ts";

const STRIKING_VERSION = "v1.0.0";
const PROMPT_VERSION = "v1.0.0";
const DEFAULT_MODEL_ID = Deno.env.get("STRIKING_DETECT_MODEL") || "gpt-4o-mini";
const DEFAULT_MAX_TOKENS = 1024;
const DEFAULT_TEMPERATURE = 0;

const jsonHeaders = { "Content-Type": "application/json" };

// ============================================================
// SIGNAL TAXONOMY
// ============================================================
const VALID_SIGNAL_TYPES = [
  "decision_point", // A choice is being made or deferred
  "scope_change", // Work is being added, removed, or redefined
  "financial_signal", // Money, cost, budget, change order, payment
  "relationship_tension", // Disagreement, frustration, concern, apology
  "commitment", // Someone is promising something specific
  "escalation", // Issue being raised to higher authority or urgency
  "surprise", // Information that catches someone off guard
  "threshold", // A before/after moment ("we need to decide by Friday")
] as const;

type SignalType = typeof VALID_SIGNAL_TYPES[number];

interface StrikingSignal {
  type: SignalType;
  text: string; // Short description of what was detected
  quote: string; // Exact quote from transcript
  confidence: number; // 0.0–1.0
}

interface StrikingResult {
  striking_score: number;
  signals: StrikingSignal[];
  primary_signal_type: SignalType | null;
  reasoning: string;
}

// ============================================================
// PROMPT
// ============================================================
const SYSTEM_PROMPT = `You are a conversation analyst for HCB (Heartwood Custom Builders), a construction company.
Your job is to detect "striking" moments in phone call transcripts — moments where something important is happening beneath the surface.

NOT every call is striking. Many calls are routine: scheduling, confirming details, brief check-ins.
Striking calls are ones where the PROJECT SITUATION is changing or under tension.

SIGNAL TAXONOMY (use ONLY these types):
- decision_point: A choice is being made or deferred ("we could go either way on the trim")
- scope_change: Work is being added, removed, or redefined ("they want to add a screened porch now")
- financial_signal: Money, cost, budget, change order, payment discussed ("that's going to add about fifteen thousand")
- relationship_tension: Disagreement, frustration, concern, apology ("I'm just not happy with how that turned out")
- commitment: Someone is promising something specific ("I'll have the crew there Monday morning")
- escalation: Issue raised to higher authority or urgency ("we need to get Chad involved on this")
- surprise: Information that catches someone off guard ("wait, they changed the plans?")
- threshold: A before/after moment, deadline, point of no return ("we need to decide by Friday or we lose the slot")

SCORING GUIDELINES:
- 0.0–0.2: Routine call. Scheduling, brief check-in, confirming existing plans.
- 0.3–0.5: Mildly interesting. Some information exchanged but no real tension or decision.
- 0.6–0.7: Notable. A commitment is made, a concern is raised, or money is discussed.
- 0.8–1.0: Highly striking. Multiple signals, clear tension, active decision-making, or significant scope/financial change.

IMPORTANT:
- Only detect signals that are ACTUALLY PRESENT in the transcript
- Every signal MUST include an exact quote from the transcript (max 60 chars)
- Do NOT infer signals that aren't clearly supported by the text
- Routine scheduling and brief logistics are NOT striking
- A single mild commitment ("I'll call you back") does not make a call striking

OUTPUT FORMAT (JSON only, no markdown):
{
  "striking_score": <0.00-1.00>,
  "signals": [
    {
      "type": "<signal_type>",
      "text": "<short description, max 80 chars>",
      "quote": "<EXACT quote from transcript, max 60 chars>",
      "confidence": <0.00-1.00>
    }
  ],
  "reasoning": "<1-2 sentences explaining the overall striking assessment>"
}`;

function buildUserPrompt(transcript: string): string {
  return `PHONE CALL TRANSCRIPT SEGMENT:
"""
${transcript}
"""

Analyze this transcript segment for striking signals. Rate the overall striking score and identify any specific signals present. Remember: routine calls should score low (0.0-0.2).`;
}

// ============================================================
// MAIN HANDLER
// ============================================================
Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  // ============================================================
  // AUTH GATE (internal machine-to-machine)
  // ============================================================
  const edgeSecretHeader = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ ok: false, error: "invalid_json", version: STRIKING_VERSION }),
      { status: 400, headers: jsonHeaders },
    );
  }

  const hasValidEdgeSecret = expectedSecret &&
    edgeSecretHeader === expectedSecret;

  if (!hasValidEdgeSecret) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "unauthorized",
        error_code: "auth_failed",
        hint: "Requires X-Edge-Secret matching EDGE_SHARED_SECRET",
        version: STRIKING_VERSION,
      }),
      { status: 401, headers: jsonHeaders },
    );
  }

  // ============================================================
  // INPUT VALIDATION
  // ============================================================
  const {
    span_id,
    interaction_id,
    call_id,
    transcript,
    dry_run = false,
  } = body;

  if (!span_id) {
    return new Response(
      JSON.stringify({ ok: false, error: "missing_span_id", version: STRIKING_VERSION }),
      { status: 400, headers: jsonHeaders },
    );
  }

  if (!interaction_id) {
    return new Response(
      JSON.stringify({ ok: false, error: "missing_interaction_id", version: STRIKING_VERSION }),
      { status: 400, headers: jsonHeaders },
    );
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const modelConfig = await getModelConfigCached(db, {
    functionName: "striking-detect",
    modelId: DEFAULT_MODEL_ID,
    maxTokens: DEFAULT_MAX_TOKENS,
    temperature: DEFAULT_TEMPERATURE,
  });

  // ============================================================
  // FETCH TRANSCRIPT (from param or span)
  // ============================================================
  let spanTranscript: string | null = typeof transcript === "string" ? transcript : null;

  if (!spanTranscript) {
    const { data: spanRow, error: spanErr } = await db
      .from("conversation_spans")
      .select("transcript_segment")
      .eq("id", span_id)
      .single();

    if (spanErr || !spanRow?.transcript_segment) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: "transcript_not_found",
          error_code: "no_transcript",
          span_id,
          version: STRIKING_VERSION,
        }),
        { status: 400, headers: jsonHeaders },
      );
    }

    spanTranscript = spanRow.transcript_segment;
  }
  const transcriptText = spanTranscript ?? "";

  // Skip very short transcripts (< 50 chars likely noise)
  if (transcriptText.length < 50) {
    return new Response(
      JSON.stringify({
        ok: true,
        span_id,
        striking_score: 0,
        signals: [],
        primary_signal_type: null,
        reasoning: "Transcript too short for meaningful analysis",
        skipped: true,
        version: STRIKING_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: jsonHeaders },
    );
  }

  // ============================================================
  // LLM INFERENCE
  // ============================================================
  let result: StrikingResult;
  let tokens_used = 0;
  let inference_ms = 0;
  let model_error = false;

  try {
    const openaiKey = Deno.env.get("OPENAI_API_KEY");
    if (!openaiKey) throw new Error("config_missing: OPENAI_API_KEY not set");

    const inferenceStart = Date.now();

    // Truncate transcript for prompt (max 6000 chars to keep costs down)
    const promptTranscript = transcriptText.length > 6000
      ? transcriptText.slice(0, 6000) + "...[truncated]"
      : transcriptText;

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
          { role: "user", content: buildUserPrompt(promptTranscript) },
        ],
      }),
    });
    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`openai_${resp.status}: ${errText.slice(0, 240)}`);
    }
    const payload = await resp.json();

    inference_ms = Date.now() - inferenceStart;
    tokens_used = (payload?.usage?.prompt_tokens || 0) + (payload?.usage?.completion_tokens || 0);

    // Parse response
    const responseText = payload?.choices?.[0]?.message?.content || "";

    let jsonStr = responseText;
    const jsonMatch = responseText.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      jsonStr = jsonMatch[0];
    }

    const parsed = JSON.parse(jsonStr);

    // Validate and sanitize
    const striking_score = Math.max(0, Math.min(1, Number(parsed.striking_score) || 0));

    const signals: StrikingSignal[] = [];
    if (Array.isArray(parsed.signals)) {
      for (const sig of parsed.signals) {
        if (!sig.type || !VALID_SIGNAL_TYPES.includes(sig.type)) continue;

        // Validate quote appears in transcript
        const quoteNorm = (sig.quote || "").toLowerCase().replace(/\s+/g, " ").trim();
        const transcriptNorm = transcriptText.toLowerCase().replace(/\s+/g, " ").trim();
        const quoteInTranscript = quoteNorm.length >= 3 && transcriptNorm.includes(quoteNorm);

        if (!quoteInTranscript) {
          console.log(`[striking-detect] Rejected signal: quote not in transcript: "${sig.quote}"`);
          continue;
        }

        signals.push({
          type: sig.type as SignalType,
          text: (sig.text || "").slice(0, 120),
          quote: (sig.quote || "").slice(0, 80),
          confidence: Math.max(0, Math.min(1, Number(sig.confidence) || 0)),
        });
      }
    }

    // Determine primary signal type (highest confidence)
    const primary_signal_type = signals.length > 0
      ? signals.reduce((best, s) => s.confidence > best.confidence ? s : best).type
      : null;

    result = {
      striking_score,
      signals,
      primary_signal_type,
      reasoning: parsed.reasoning || "No reasoning provided",
    };
  } catch (e: any) {
    console.error("[striking-detect] Inference error:", e.message);
    model_error = true;

    result = {
      striking_score: 0,
      signals: [],
      primary_signal_type: null,
      reasoning: `model_error: ${e.message}`,
    };
  }

  // ============================================================
  // PERSIST TO striking_signals
  // ============================================================
  let persisted = false;

  if (!dry_run && !model_error) {
    const { error: upsertErr } = await db.from("striking_signals").upsert({
      span_id,
      interaction_id,
      call_id: call_id || null,
      striking_score: result.striking_score,
      signals: result.signals,
      primary_signal_type: result.primary_signal_type,
      model_id: modelConfig.modelId,
      prompt_version: PROMPT_VERSION,
      tokens_used,
      inference_ms,
    }, {
      onConflict: "span_id,model_id,prompt_version",
    });

    if (upsertErr) {
      console.error("[striking-detect] Upsert failed:", upsertErr.message);
      // Non-fatal: striking detection is supplementary
    } else {
      persisted = true;
    }
  }

  // ============================================================
  // RESPONSE
  // ============================================================
  return new Response(
    JSON.stringify({
      ok: true,
      span_id,
      interaction_id,
      striking_score: result.striking_score,
      signals: result.signals,
      primary_signal_type: result.primary_signal_type,
      reasoning: result.reasoning,
      signal_count: result.signals.length,
      persisted,
      model_error,
      dry_run,
      model_id: modelConfig.modelId,
      model_source: modelConfig.source,
      prompt_version: PROMPT_VERSION,
      tokens_used,
      inference_ms,
      version: STRIKING_VERSION,
      ms: Date.now() - t0,
    }),
    { status: 200, headers: jsonHeaders },
  );
});
