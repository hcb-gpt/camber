/**
 * loop-closure Edge Function v1.0.0
 * Matches new call transcripts against open loops for a project and closes resolved ones.
 *
 * @version 1.0.0
 * @date 2026-02-14
 * @purpose P2 deliverable — kill the open loops dead end (75 open, 0 closed)
 *
 * Architecture:
 *   Called as a post-extraction hook after journal-extract succeeds.
 *   Separate function (Option B) for testability and clean separation.
 *
 * Input: { interaction_id, project_id } or { interaction_id, project_id, dry_run: true }
 * Process:
 *   1. Fetch open loops for the project
 *   2. Fetch the call transcript
 *   3. Ask LLM to match open loops against transcript content
 *   4. Close matched loops with evidence citation
 * Output: { ok, loops_checked, loops_closed, closures: [...] }
 *
 * Constraints (from STRAT-2 directive):
 *   - No auto-close without evidence — LLM must cite what resolves the loop
 *   - Append-only audit: closure_evidence column records the proof
 *   - Confidence threshold: only close if LLM confidence >= 0.75
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v1.0.0";
const CLOSURE_CONFIDENCE_THRESHOLD = 0.75;
const MAX_OPEN_LOOPS_PER_PROJECT = 50;
const MAX_TOKENS = 2048;
const DEFAULT_MODEL = "claude-3-haiku-20240307";
const DEFAULT_TIMEOUT_MS = 30000;

interface LoopMatch {
  loop_id: string;
  resolved: boolean;
  confidence: number;
  evidence: string;
}

interface LlmResponse {
  matches: LoopMatch[];
}

function stripCodeFences(raw: string): string {
  return (raw || "").replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
}

function stripControlChars(s: string): string {
  // deno-lint-ignore no-control-regex -- intentional: scrub control chars from LLM output
  return s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, "");
}

function removeTrailingCommas(s: string): string {
  return s.replace(/,\s*([}\]])/g, "$1");
}

function parseLlmJson(raw: string): LlmResponse {
  const cleaned = stripCodeFences(raw);
  const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
  const jsonStr = jsonMatch ? jsonMatch[0] : cleaned;

  // Attempt 1: Direct parse
  try {
    return validateResponse(JSON.parse(jsonStr));
  } catch { /* continue */ }

  // Attempt 2: Sanitize
  try {
    const sanitized = removeTrailingCommas(stripControlChars(jsonStr));
    return validateResponse(JSON.parse(sanitized));
  } catch { /* continue */ }

  // Attempt 3: Extract matches array
  try {
    const matchesMatch = cleaned.match(/"matches"\s*:\s*\[[\s\S]*?\]/);
    if (matchesMatch) {
      const synthetic = `{${matchesMatch[0]}}`;
      const sanitized = removeTrailingCommas(stripControlChars(synthetic));
      return validateResponse(JSON.parse(sanitized));
    }
  } catch { /* continue */ }

  throw new Error(`json_parse_failed: could not parse loop-closure LLM output (${jsonStr.length} chars)`);
}

function validateResponse(parsed: any): LlmResponse {
  const matches: LoopMatch[] = [];
  for (const m of (Array.isArray(parsed.matches) ? parsed.matches : [])) {
    if (!m.loop_id) continue;
    matches.push({
      loop_id: String(m.loop_id),
      resolved: m.resolved === true,
      confidence: typeof m.confidence === "number" ? Math.min(1, Math.max(0, m.confidence)) : 0,
      evidence: String(m.evidence || "").slice(0, 1000),
    });
  }
  return { matches };
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  let timeoutHandle: number | undefined;
  const timeoutPromise = new Promise<T>((_, reject) => {
    timeoutHandle = setTimeout(() => reject(new Error(`${label}_timeout`)), timeoutMs);
  });
  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    if (timeoutHandle !== undefined) clearTimeout(timeoutHandle);
  }
}

function buildSystemPrompt(): string {
  return `You are a construction project loop-closure analyst for HCB (Heartwood Custom Builders).

Your job: given a list of OPEN LOOPS (unresolved items from previous calls) and a NEW TRANSCRIPT,
determine which open loops have been resolved by the new conversation.

RULES:
1. A loop is RESOLVED only if the transcript provides clear evidence of resolution.
2. You MUST cite the specific part of the transcript that resolves each loop.
3. Do NOT mark a loop as resolved if:
   - The topic is merely mentioned without resolution
   - Someone says they'll "look into it" (that's still open)
   - The resolution is ambiguous or unclear
4. Be conservative — false negatives (missing a closure) are better than false positives (wrongly closing).
5. For each resolved loop, provide a confidence score (0.0 to 1.0).

EVIDENCE FORMAT: Quote or closely paraphrase the specific transcript excerpt that proves resolution.
Keep evidence under 200 words.

OUTPUT FORMAT (JSON only, no markdown):
{
  "matches": [
    {
      "loop_id": "uuid-of-the-open-loop",
      "resolved": true,
      "confidence": 0.85,
      "evidence": "Speaker said 'the permits came through yesterday, we're good to go' which resolves the pending permit question."
    },
    {
      "loop_id": "uuid-of-unresolved-loop",
      "resolved": false,
      "confidence": 0.0,
      "evidence": ""
    }
  ]
}

Include ALL open loops in the output — mark unresolved ones with resolved=false.`;
}

function buildUserPrompt(
  openLoops: Array<{ id: string; loop_type: string; description: string; created_at: string }>,
  transcript: string,
  interactionId: string,
): string {
  const loopList = openLoops.map((l, i) =>
    `${i + 1}. [${l.id}] (${l.loop_type}, opened ${l.created_at.slice(0, 10)}): ${l.description}`
  ).join("\n");

  return `OPEN LOOPS FOR THIS PROJECT:
${loopList}

NEW CALL TRANSCRIPT (interaction: ${interactionId}):
"""
${transcript}
"""

Analyze which open loops (if any) are resolved by this transcript.`;
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Auth: X-Edge-Secret (machine-to-machine from journal-extract or ai-router)
  const edgeSecret = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  if (!expectedSecret || edgeSecret !== expectedSecret) {
    return new Response(
      JSON.stringify({ error: "unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { interaction_id, project_id, dry_run = false } = body;

  if (!interaction_id || !project_id) {
    return new Response(
      JSON.stringify({ error: "missing_required_fields", required: ["interaction_id", "project_id"] }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    return new Response(
      JSON.stringify({ ok: false, error: "missing_anthropic_key" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const model = Deno.env.get("LOOP_CLOSURE_MODEL") || DEFAULT_MODEL;
  const timeoutMs = Number(Deno.env.get("LOOP_CLOSURE_TIMEOUT_MS")) || DEFAULT_TIMEOUT_MS;

  try {
    // 1. Fetch open loops for this project
    const { data: openLoops, error: loopsErr } = await db
      .from("journal_open_loops")
      .select("id, loop_type, description, created_at")
      .eq("project_id", project_id)
      .eq("status", "open")
      .order("created_at", { ascending: true })
      .limit(MAX_OPEN_LOOPS_PER_PROJECT);

    if (loopsErr) throw new Error(`db_open_loops: ${loopsErr.message}`);

    if (!openLoops || openLoops.length === 0) {
      return new Response(
        JSON.stringify({
          ok: true,
          interaction_id,
          project_id,
          loops_checked: 0,
          loops_closed: 0,
          reason: "no_open_loops_for_project",
          function_version: FUNCTION_VERSION,
          ms: Date.now() - t0,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    // 2. Fetch the call transcript
    const { data: callRaw, error: callErr } = await db
      .from("calls_raw")
      .select("transcript")
      .eq("interaction_id", interaction_id)
      .single();

    if (callErr || !callRaw?.transcript) {
      return new Response(
        JSON.stringify({
          ok: true,
          interaction_id,
          project_id,
          loops_checked: openLoops.length,
          loops_closed: 0,
          reason: "no_transcript_found",
          function_version: FUNCTION_VERSION,
          ms: Date.now() - t0,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    // Truncate transcript if very long (keep first 8000 chars for LLM context)
    const transcript = callRaw.transcript.length > 8000
      ? callRaw.transcript.slice(0, 8000) + "\n[...transcript truncated...]"
      : callRaw.transcript;

    // 3. Call LLM to match open loops against transcript
    const systemPrompt = buildSystemPrompt();
    const userPrompt = buildUserPrompt(openLoops, transcript, interaction_id);

    const llmT0 = Date.now();
    const resp = await withTimeout(
      fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": anthropicKey,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model,
          max_tokens: MAX_TOKENS,
          temperature: 0,
          system: systemPrompt,
          messages: [{ role: "user", content: userPrompt }],
        }),
      }),
      timeoutMs,
      "anthropic_loop_closure",
    );
    const inference_ms = Date.now() - llmT0;

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`anthropic_${resp.status}: ${errText.slice(0, 200)}`);
    }

    const apiPayload = await resp.json();
    const textBlock = (apiPayload?.content || []).find((b: any) => b?.type === "text");
    const rawContent = textBlock?.text || "";
    const tokens_used = (apiPayload?.usage?.input_tokens || 0) + (apiPayload?.usage?.output_tokens || 0);

    // 4. Parse LLM response
    const llmResult = parseLlmJson(rawContent);

    // 5. Filter to resolved matches above confidence threshold
    const validLoopIds = new Set(openLoops.map((l) => l.id));
    const resolvedMatches = llmResult.matches.filter((m) =>
      m.resolved &&
      m.confidence >= CLOSURE_CONFIDENCE_THRESHOLD &&
      m.evidence.length > 0 &&
      validLoopIds.has(m.loop_id)
    );

    // 6. Close matched loops (unless dry_run)
    const closures: Array<{ loop_id: string; confidence: number; evidence_preview: string }> = [];

    if (!dry_run) {
      for (const match of resolvedMatches) {
        const { error: updateErr } = await db
          .from("journal_open_loops")
          .update({
            status: "closed",
            closed_at: new Date().toISOString(),
            closed_by_call_id: interaction_id,
            closure_evidence: match.evidence,
            closure_confidence: match.confidence,
            closed_by_function: `loop-closure ${FUNCTION_VERSION}`,
          })
          .eq("id", match.loop_id)
          .eq("status", "open"); // Guard: only close if still open

        if (updateErr) {
          console.error(`[loop-closure] Failed to close loop ${match.loop_id}: ${updateErr.message}`);
        } else {
          closures.push({
            loop_id: match.loop_id,
            confidence: match.confidence,
            evidence_preview: match.evidence.slice(0, 100),
          });
        }
      }
    } else {
      // Dry run: report what would be closed
      for (const match of resolvedMatches) {
        closures.push({
          loop_id: match.loop_id,
          confidence: match.confidence,
          evidence_preview: match.evidence.slice(0, 100),
        });
      }
    }

    // 7. Also report below-threshold matches for visibility
    const belowThreshold = llmResult.matches.filter((m) =>
      m.resolved &&
      m.confidence < CLOSURE_CONFIDENCE_THRESHOLD &&
      m.confidence > 0 &&
      validLoopIds.has(m.loop_id)
    ).map((m) => ({
      loop_id: m.loop_id,
      confidence: m.confidence,
      reason: "below_threshold",
    }));

    return new Response(
      JSON.stringify({
        ok: true,
        interaction_id,
        project_id,
        loops_checked: openLoops.length,
        loops_closed: closures.length,
        closures,
        below_threshold: belowThreshold,
        model,
        tokens_used,
        inference_ms,
        dry_run,
        confidence_threshold: CLOSURE_CONFIDENCE_THRESHOLD,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e: any) {
    console.error("[loop-closure] Error:", e.message);
    return new Response(
      JSON.stringify({
        ok: false,
        error: e.message,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
