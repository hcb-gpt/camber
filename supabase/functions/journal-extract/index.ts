/**
 * journal-extract Edge Function v1.3.2
 * Extracts structured epistemic claims from attributed conversation spans
 *
 * @version 1.3.2
 * @date 2026-02-14
 * @purpose D1 deliverable - journal claim extraction from spans
 *
 * v1.3.2 changes (DEV-3):
 *   - Dedup open-loop inserts by (call_id, project_id, loop_type, description, status=open)
 *     to prevent duplicate loop rows on extract retries/replays.
 *   - Fire loop-closure trigger when either claims or open-loops are written.
 *
 * v1.3.1 changes (DEV-3):
 *   - Fire-and-forget chain to loop-closure after successful claim writes.
 *   - Adds bounded timeout for loop-closure trigger and response telemetry.
 *
 * v1.3.0 changes (DEV-4):
 *   - Add optional write gate to block claim writes when attribution decision
 *     is review/none (env: JOURNAL_EXTRACT_SKIP_NON_ASSIGN_WRITES=true).
 *   - Emits contamination metric log and response counters for blocked writes.
 *
 * v1.2.2 changes (DEV-1):
 *   - Fire-and-forget chain to journal-consolidate for successful writes with
 *     written claims so new extractions flow directly into relationship updates.
 *
 * v1.2.1 changes (DEV-2):
 *   - INCIDENT MITIGATION: Add transcript truncation (max 8000 chars) to prevent
 *     Haiku inference timeouts on long spans (38K+ chars → auto-timeout cascade).
 *     Aligns with striking-detect pattern (6000 char cap).
 *   - Skip LLM retry when first attempt times out (retry would also timeout,
 *     doubling the wall-clock time for no benefit).
 *   - Add transcript_chars and truncated flags to response for observability.
 *
 * v1.2.0 changes (DEV-1):
 *   - HOTFIX: Fix status enum mismatch — 'completed' → 'success' in journal_runs writes.
 *     CHECK constraint only allows 'running'|'success'|'failed'. Writing 'completed' caused
 *     silent update failures → rows stuck in 'running' → cron auto-timeout cascade (238+ false failures).
 *   - Add error checking on all journal_runs .update() calls.
 *   - Fix catch-path failure update: use run_id instead of call_id (was matching wrong rows).
 *   - Add AbortController to Anthropic fetch so timeout actually cancels the HTTP request.
 *
 * v1.1.5 changes (DEV-2):
 *   - Upgrade epistemic_status extraction vocabulary to:
 *     observed, reported, inferred, promised, decided, disputed, superseded.
 *   - Prompt guidance now maps commitments/decisions/facts/testimony to the
 *     upgraded vocabulary.
 *
 * v1.1.4 changes (DEV-1):
 *   - Restore pointer field propagation into dedup RPC payload
 *     (char_start/char_end/span_text/span_hash/pointer_type + claim_project_id/confidence).
 *   - Ensures pointer trigger path can run again and recover transcript span pointers.
 *
 * v1.1.3 changes (DEV-2):
 *   - Deployment config aligned to internal auth pattern (`verify_jwt=false`)
 *     so segment-call X-Edge-Secret invocations are accepted at gateway.
 *
 * v1.1.2 changes (DEV-10):
 *   - Use insert_journal_claims_dedup RPC for ON CONFLICT DO NOTHING dedup
 *     (belt-and-suspenders with application-level idempotency guard)
 *
 * v1.1.1 changes (DEV-10):
 *   - Fix: skip DB insert when project_id is null (FK constraint on projects(id))
 *     Claims still extracted; written after attribution lands via re-trigger
 *
 * v1.1.0 changes (DEV-10):
 *   - Robust JSON parsing: strip control chars, trailing commas, comment removal
 *   - LLM retry on parse failure with explicit JSON-only instruction
 *   - Idempotency guard: skip insert if claims already exist for span_id+run combination
 *   - Model default updated to claude-3-haiku-20240307
 *
 * Input: { span_id } or { interaction_id, span_index }
 * Process: LLM extracts structured claims from span transcript_segment
 * Output: rows in journal_claims + journal_open_loops, journal_runs audit
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v1.3.2";
const PROMPT_VERSION = "journal-extract-v2";
const MAX_TOKENS = 4096;
const DEFAULT_MODEL = "claude-3-haiku-20240307";
const DEFAULT_TIMEOUT_MS = 30000;
const MAX_TRANSCRIPT_CHARS = 8000; // Cap transcript to prevent inference timeouts
const JOURNAL_CONSOLIDATE_TIMEOUT_MS = 120000;
const LOOP_CLOSURE_TRIGGER_TIMEOUT_MS = 45000;
const SKIP_NON_ASSIGN_WRITES = (() => {
  const raw = (Deno.env.get("JOURNAL_EXTRACT_SKIP_NON_ASSIGN_WRITES") || "").trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
})();

// Defense-in-depth: closed-project hard filter (mirrors context-assembly VALID_PROJECT_STATUSES)
const ATTRIBUTION_ELIGIBLE_STATUSES = new Set(["active", "warranty", "estimating"]);

const VALID_CLAIM_TYPES = [
  "commitment",
  "deadline",
  "decision",
  "blocker",
  "requirement",
  "preference",
  "concern",
  "fact",
  "question",
  "update",
] as const;
const VALID_EPISTEMIC_STATUSES = [
  "observed",
  "reported",
  "inferred",
  "promised",
  "decided",
  "disputed",
  "superseded",
  // Back-compat accepted during rollout
  "stated",
  "uncertain",
] as const;
const VALID_WARRANT_LEVELS = ["high", "medium", "low"] as const;
const VALID_TESTIMONY_TYPES = ["direct", "reported", "inferred"] as const;
const VALID_LOOP_TYPES = ["question", "blocker", "follow_up", "action_item"] as const;

type ClaimType = typeof VALID_CLAIM_TYPES[number];
type EpistemicStatus = typeof VALID_EPISTEMIC_STATUSES[number];
type WarrantLevel = typeof VALID_WARRANT_LEVELS[number];
type TestimonyType = typeof VALID_TESTIMONY_TYPES[number];

interface ExtractedClaim {
  claim_type: ClaimType;
  claim_text: string;
  epistemic_status: EpistemicStatus;
  warrant_level: WarrantLevel;
  testimony_type: TestimonyType | null;
  speaker_label: string | null;
  start_sec: number | null;
  end_sec: number | null;
  is_open_loop: boolean;
  open_loop_type: string | null;
}

function normalizeLoopType(openLoopType: string | null, claimType: ClaimType): string {
  const raw = (openLoopType || claimType || "").trim().toLowerCase().replaceAll("-", "_");

  if (raw && VALID_LOOP_TYPES.includes(raw as typeof VALID_LOOP_TYPES[number])) {
    return raw;
  }

  if (raw.includes("question")) return "question";
  if (raw.includes("block") || raw.includes("concern") || raw.includes("risk")) return "blocker";
  if (raw.includes("action") || raw.includes("todo") || raw.includes("task")) return "action_item";
  if (raw.includes("follow") || raw.includes("deadline") || raw.includes("commitment")) return "follow_up";

  switch (claimType) {
    case "question":
      return "question";
    case "blocker":
    case "concern":
      return "blocker";
    default:
      return "follow_up";
  }
}

interface ExtractionResponse {
  claims: ExtractedClaim[];
  summary: string;
}

function stripCodeFences(raw: string): string {
  return (raw || "").replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
}

/**
 * Strip control characters (0x00-0x1F) except newline, carriage return, tab.
 * These can appear in LLM output and break JSON.parse().
 */
function stripControlChars(s: string): string {
  // deno-lint-ignore no-control-regex -- intentional: scrub control chars from LLM output
  return s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, "");
}

/**
 * Remove trailing commas before } or ] which are invalid JSON but
 * commonly produced by LLMs.
 */
function removeTrailingCommas(s: string): string {
  return s.replace(/,\s*([}\]])/g, "$1");
}

/**
 * Remove single-line (//) and multi-line comments from JSON-like text.
 * LLMs sometimes annotate JSON with comments.
 */
function removeJsonComments(s: string): string {
  // Remove single-line comments (but not inside strings — best-effort)
  let result = s.replace(/\/\/[^\n]*/g, "");
  // Remove multi-line comments
  result = result.replace(/\/\*[\s\S]*?\*\//g, "");
  return result;
}

/**
 * Attempt to fix unescaped quotes inside JSON string values.
 * This is a best-effort heuristic: finds " inside values that aren't
 * preceded by a backslash and escapes them.
 */
function fixUnescapedQuotes(s: string): string {
  // Strategy: find patterns like "key": "value with "unescaped" quotes"
  // This is inherently fragile, so we only apply it as a fallback.
  // Replace sequences of ": " followed by a string that has internal unescaped quotes
  // Simple best-effort: currently a no-op; the retry mechanism handles truly broken JSON.
  return s;
}

/**
 * Robust JSON parsing with multiple fallback strategies.
 * Tries increasingly aggressive sanitization until parse succeeds.
 */
function parseExtractionJson(raw: string): ExtractionResponse {
  const cleaned = stripCodeFences(raw);

  // Strategy 1: Direct parse after extracting JSON object
  const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
  const jsonStr = jsonMatch ? jsonMatch[0] : cleaned;

  // Attempt 1: Parse as-is
  try {
    const parsed = JSON.parse(jsonStr);
    return validateExtraction(parsed);
  } catch { /* continue to next strategy */ }

  // Attempt 2: Strip control chars + trailing commas
  try {
    const sanitized = removeTrailingCommas(stripControlChars(jsonStr));
    const parsed = JSON.parse(sanitized);
    return validateExtraction(parsed);
  } catch { /* continue */ }

  // Attempt 3: Also remove comments
  try {
    const sanitized = removeTrailingCommas(stripControlChars(removeJsonComments(jsonStr)));
    const parsed = JSON.parse(sanitized);
    return validateExtraction(parsed);
  } catch { /* continue */ }

  // Attempt 4: Try to extract just the {"claims":...} structure
  try {
    const claimsMatch = cleaned.match(/"claims"\s*:\s*\[[\s\S]*?\]/);
    if (claimsMatch) {
      const synthetic = `{${claimsMatch[0]}, "summary": ""}`;
      const sanitized = removeTrailingCommas(stripControlChars(synthetic));
      const parsed = JSON.parse(sanitized);
      return validateExtraction(parsed);
    }
  } catch { /* continue */ }

  // Attempt 5: Fix unescaped quotes
  try {
    const sanitized = removeTrailingCommas(stripControlChars(removeJsonComments(fixUnescapedQuotes(jsonStr))));
    const parsed = JSON.parse(sanitized);
    return validateExtraction(parsed);
  } catch { /* all local strategies exhausted */ }

  // If all attempts fail, throw with context for the retry mechanism
  throw new Error(`json_parse_failed: could not parse LLM output (${jsonStr.length} chars)`);
}

/**
 * Validate and normalize the parsed extraction object.
 */
function validateExtraction(parsed: any): ExtractionResponse {
  const claims: ExtractedClaim[] = [];
  for (const c of (Array.isArray(parsed.claims) ? parsed.claims : [])) {
    const claim_type = VALID_CLAIM_TYPES.includes(c.claim_type) ? c.claim_type : null;
    if (!claim_type || !c.claim_text) continue;

    claims.push({
      claim_type,
      claim_text: String(c.claim_text).slice(0, 2000),
      epistemic_status: VALID_EPISTEMIC_STATUSES.includes(c.epistemic_status) ? c.epistemic_status : "reported",
      warrant_level: VALID_WARRANT_LEVELS.includes(c.warrant_level) ? c.warrant_level : "medium",
      testimony_type: c.testimony_type && VALID_TESTIMONY_TYPES.includes(c.testimony_type) ? c.testimony_type : null,
      speaker_label: c.speaker_label || null,
      start_sec: typeof c.start_sec === "number" ? c.start_sec : null,
      end_sec: typeof c.end_sec === "number" ? c.end_sec : null,
      is_open_loop: c.is_open_loop === true,
      open_loop_type: c.open_loop_type || null,
    });
  }

  return { claims, summary: parsed.summary || "" };
}

async function triggerJournalConsolidate(
  baseUrl: string,
  edgeSecret: string,
  runId: string,
): Promise<void> {
  try {
    const timeoutMs = Number(Deno.env.get("JOURNAL_CONSOLIDATE_TRIGGER_TIMEOUT_MS")) || JOURNAL_CONSOLIDATE_TIMEOUT_MS;
    const controller = new AbortController();
    const timeoutHandle = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const resp = await fetch(`${baseUrl}/functions/v1/journal-consolidate`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": edgeSecret,
        },
        body: JSON.stringify({ run_id: runId }),
        signal: controller.signal,
      });

      if (!resp.ok) {
        const errBody = await resp.text().catch(() => "unknown");
        console.warn(
          `[journal-extract] journal-consolidate trigger ${resp.status}: ${errBody.slice(0, 200)}`,
        );
        return;
      }

      const payload = await resp.json().catch(() => null);
      console.log(
        `[journal-extract] journal-consolidate trigger OK: run_id=${runId}, ` +
          `claims_processed=${payload?.claims_processed ?? "?"}`,
      );
    } finally {
      clearTimeout(timeoutHandle);
    }
  } catch (err: any) {
    console.warn(`[journal-extract] journal-consolidate trigger failed for run ${runId}: ${err.message}`);
  }
}

async function triggerLoopClosure(
  baseUrl: string,
  edgeSecret: string,
  interactionId: string,
  projectId: string,
): Promise<void> {
  try {
    const timeoutMs = Number(Deno.env.get("LOOP_CLOSURE_TRIGGER_TIMEOUT_MS")) || LOOP_CLOSURE_TRIGGER_TIMEOUT_MS;
    const controller = new AbortController();
    const timeoutHandle = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const resp = await fetch(`${baseUrl}/functions/v1/loop-closure`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": edgeSecret,
        },
        body: JSON.stringify({ interaction_id: interactionId, project_id: projectId }),
        signal: controller.signal,
      });

      if (!resp.ok) {
        const errBody = await resp.text().catch(() => "unknown");
        console.warn(
          `[journal-extract] loop-closure trigger ${resp.status}: ${errBody.slice(0, 200)}`,
        );
        return;
      }

      const payload = await resp.json().catch(() => null);
      console.log(
        `[journal-extract] loop-closure trigger OK: interaction_id=${interactionId}, ` +
          `loops_closed=${payload?.loops_closed ?? "?"}, loops_checked=${payload?.loops_checked ?? "?"}`,
      );
    } finally {
      clearTimeout(timeoutHandle);
    }
  } catch (err: any) {
    console.warn(`[journal-extract] loop-closure trigger failed for interaction ${interactionId}: ${err.message}`);
  }
}

/**
 * Call Anthropic API for claim extraction with AbortController-backed timeout.
 * The AbortController ensures the HTTP request is actually cancelled on timeout,
 * not just abandoned (which would leak connections).
 */
async function callLlm(
  anthropicKey: string,
  model: string,
  systemPrompt: string,
  userPrompt: string,
  timeoutMs: number,
): Promise<{ rawContent: string; tokens_used: number; inference_ms: number }> {
  const llmT0 = Date.now();
  const controller = new AbortController();
  const timeoutHandle = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
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
      signal: controller.signal,
    });

    const inference_ms = Date.now() - llmT0;

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`anthropic_${resp.status}: ${errText.slice(0, 200)}`);
    }

    const payload = await resp.json();
    const textBlock = (payload?.content || []).find((b: any) => b?.type === "text");
    const rawContent = textBlock?.text || "";
    const tokens_used = (payload?.usage?.input_tokens || 0) + (payload?.usage?.output_tokens || 0);

    return { rawContent, tokens_used, inference_ms };
  } catch (err: any) {
    if (err.name === "AbortError" || controller.signal.aborted) {
      throw new Error(`anthropic_extract_timeout: request aborted after ${timeoutMs}ms`);
    }
    throw err;
  } finally {
    clearTimeout(timeoutHandle);
  }
}

const SYSTEM_PROMPT = `You are a construction project journal analyst for HCB (Heartwood Custom Builders).
You extract structured epistemic claims from phone call transcript segments.

Each claim represents a discrete piece of project knowledge with its epistemic properties.

CLAIM TYPES (pick exactly one per claim):
- commitment: Someone committed to doing something ("I'll have that done by Friday")
- deadline: A specific date or timeframe was mentioned ("We need permits by March 1st")
- decision: A decision was made ("We're going with the 6-inch baseboards")
- blocker: Something is blocking progress ("We can't start framing until the engineer signs off")
- requirement: A requirement or spec was stated ("The county requires a 30-foot setback")
- preference: A preference was expressed ("The homeowner wants white oak floors")
- concern: A concern or worry was raised ("I'm worried about the lead time on windows")
- fact: A factual statement about the project ("The lot is 2.3 acres")
- question: An unresolved question ("Do we know if they got the variance?")
- update: A status update on something ("Plumbing rough-in is done")

EPISTEMIC STATUS:
- observed: Direct first-hand observation or directly witnessed state
- reported: Relayed from someone else or generally asserted without direct observation
- inferred: Derived from context, implication, or synthesis
- promised: Forward-looking commitment language ("I'll", "we will", "going to")
- decided: Explicit decision or choice made
- disputed: Ambiguous, contested, or uncertain claim
- superseded: Explicitly replaced/overridden by newer information

MAPPING GUIDANCE:
- commitments/deadlines -> usually promised
- decisions -> decided
- facts from direct observation -> observed
- facts relayed by others -> reported
- inferences/implications -> inferred
- concerns/blockers with uncertainty -> disputed or inferred

WARRANT LEVEL (how much evidence supports this claim):
- high: Clear, unambiguous statement with context
- medium: Reasonable interpretation but some ambiguity
- low: Weak signal, single mention, or heavily context-dependent

TESTIMONY TYPE:
- direct: Speaker is the source ("I measured it at 14 feet")
- reported: Speaker is relaying what someone else said ("The engineer said...")
- inferred: Not explicitly spoken, derived from context

OPEN LOOPS: Flag claims that represent incomplete items needing follow-up:
- Unanswered questions
- Commitments without confirmation
- Blockers without resolution
- Items someone said they'd "look into" or "get back to you on"

SPEAKER LABELS: Use the speaker labels from the transcript (e.g., SPEAKER_0, SPEAKER_1).

RULES:
1. Extract ALL meaningful project claims - be thorough
2. Each claim should be one atomic piece of knowledge
3. Do NOT extract small talk, greetings, or non-project conversation
4. Preserve the original meaning - do not embellish or add information
5. If a segment mentions multiple projects, extract claims for each mentioned topic
6. Include temporal references from the transcript (start_sec/end_sec) if available

OUTPUT FORMAT (JSON only, no markdown):
{
  "claims": [
    {
      "claim_type": "commitment|deadline|decision|blocker|requirement|preference|concern|fact|question|update",
      "claim_text": "Clear, concise description of the claim",
      "epistemic_status": "observed|reported|inferred|promised|decided|disputed|superseded",
      "warrant_level": "high|medium|low",
      "testimony_type": "direct|reported|inferred",
      "speaker_label": "SPEAKER_0",
      "start_sec": null,
      "end_sec": null,
      "is_open_loop": false,
      "open_loop_type": null
    }
  ],
  "summary": "One sentence summarizing the key project topics in this segment"
}`;

const RETRY_SYSTEM_PROMPT = `You are a construction project journal analyst for HCB (Heartwood Custom Builders).
You extract structured epistemic claims from phone call transcript segments.

CRITICAL: Your previous response could not be parsed as valid JSON. You MUST output ONLY valid JSON with no extra text, no markdown code fences, no comments, and no trailing commas. Double-check all string values have properly escaped quotes.

OUTPUT FORMAT (strict JSON — nothing else):
{
  "claims": [
    {
      "claim_type": "commitment|deadline|decision|blocker|requirement|preference|concern|fact|question|update",
      "claim_text": "Clear, concise description of the claim",
      "epistemic_status": "observed|reported|inferred|promised|decided|disputed|superseded",
      "warrant_level": "high|medium|low",
      "testimony_type": "direct|reported|inferred",
      "speaker_label": "SPEAKER_0",
      "start_sec": null,
      "end_sec": null,
      "is_open_loop": false,
      "open_loop_type": null
    }
  ],
  "summary": "One sentence summary"
}`;

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const edgeSecretHeader = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");

  const edgeSecret = edgeSecretHeader ? edgeSecretHeader.trim() : "";
  const normalizedExpectedSecret = expectedSecret?.trim() || "";
  const secretOk = normalizedExpectedSecret.length > 0 && edgeSecret === normalizedExpectedSecret;

  if (!secretOk) {
    return new Response(
      JSON.stringify({
        error: "unauthorized",
        hint: normalizedExpectedSecret
          ? "Requires X-Edge-Secret matching EDGE_SHARED_SECRET"
          : "Server auth config missing",
      }),
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

  const model = Deno.env.get("JOURNAL_EXTRACT_MODEL") || DEFAULT_MODEL;
  const timeoutMs = Number(Deno.env.get("JOURNAL_EXTRACT_TIMEOUT_MS")) || DEFAULT_TIMEOUT_MS;
  const dry_run = body.dry_run === true;

  // Hoisted so catch block can reference it for failure recording
  let run_id: string | null = null;

  try {
    let span_id: string | null = body.span_id || null;

    if (!span_id && body.interaction_id) {
      const span_index = body.span_index ?? 0;
      const { data: spanRow } = await db
        .from("conversation_spans")
        .select("id")
        .eq("interaction_id", body.interaction_id)
        .eq("span_index", span_index)
        .eq("is_superseded", false)
        .single();
      if (spanRow) span_id = spanRow.id;
    }

    if (!span_id) {
      return new Response(
        JSON.stringify({ error: "missing_span_id" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    const { data: span, error: spanErr } = await db
      .from("conversation_spans")
      .select("id, interaction_id, transcript_segment, time_start_sec, time_end_sec, span_index")
      .eq("id", span_id)
      .single();

    if (spanErr || !span) {
      return new Response(
        JSON.stringify({ error: "span_not_found", span_id }),
        { status: 404, headers: { "Content-Type": "application/json" } },
      );
    }

    const interaction_id = span.interaction_id;
    const transcript = span.transcript_segment || "";

    if (!transcript || transcript.trim().length < 20) {
      return new Response(
        JSON.stringify({ ok: true, span_id, claims_extracted: 0, reason: "transcript_too_short", ms: Date.now() - t0 }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    const { data: attribution } = await db
      .from("span_attributions")
      .select("project_id, applied_project_id, confidence, decision")
      .eq("span_id", span_id)
      .order("attributed_at", { ascending: false })
      .limit(1)
      .single();

    const project_id = attribution?.applied_project_id || attribution?.project_id || null;

    // ── CLOSED-PROJECT HARD FILTER ─────────────────────────────────
    // Defense-in-depth: skip claim writes when the attributed project
    // is closed/ineligible. Prevents journal contamination from stale
    // attributions pointing at completed projects.
    if (project_id && !dry_run) {
      const { data: projectRow } = await db
        .from("projects")
        .select("status")
        .eq("id", project_id)
        .maybeSingle();

      const projectStatus = String(projectRow?.status || "").trim().toLowerCase();
      if (projectRow && !ATTRIBUTION_ELIGIBLE_STATUSES.has(projectStatus)) {
        console.log(
          `[journal-extract] Closed-project hard filter: skipping writes for span ${span_id}, project ${project_id} status=${projectStatus}`,
        );
        return new Response(
          JSON.stringify({
            ok: true,
            span_id,
            interaction_id,
            project_id,
            skipped_closed_project: true,
            project_status: projectStatus,
            reason: "project_not_attribution_eligible",
            function_version: FUNCTION_VERSION,
            ms: Date.now() - t0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
    }

    // ── IDEMPOTENCY GUARD ──────────────────────────────────────────
    // Check if completed claims already exist for this span_id.
    // Prevents duplicate insertion on re-runs (addresses 32.9% duplication issue).
    if (!dry_run) {
      const { data: existingClaims, error: existErr } = await db
        .from("journal_claims")
        .select("claim_id")
        .eq("source_span_id", span_id)
        .limit(1);

      if (!existErr && existingClaims && existingClaims.length > 0) {
        // Count total existing claims for the response
        const { count } = await db
          .from("journal_claims")
          .select("claim_id", { count: "exact", head: true })
          .eq("source_span_id", span_id);

        return new Response(
          JSON.stringify({
            ok: true,
            span_id,
            interaction_id,
            project_id,
            idempotent_skip: true,
            existing_claims: count || 0,
            reason: "claims_already_exist_for_span",
            function_version: FUNCTION_VERSION,
            ms: Date.now() - t0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
    }

    run_id = crypto.randomUUID();

    if (!dry_run) {
      const { error: runErr } = await db.from("journal_runs").insert({
        run_id,
        call_id: interaction_id,
        project_id,
        status: "running",
        config: { model, prompt_version: PROMPT_VERSION, function_version: FUNCTION_VERSION, span_id },
      });
      if (runErr) {
        console.error("[journal-extract] journal_runs insert failed:", runErr.message);
        return new Response(
          JSON.stringify({
            ok: false,
            error_code: "journal_runs_insert_failed",
            error: runErr.message,
            interaction_id,
            span_id,
          }),
          { status: 500, headers: { "Content-Type": "application/json" } },
        );
      }
    }

    // ── TRANSCRIPT TRUNCATION ────────────────────────────────────
    // Cap transcript to prevent Haiku inference timeouts on very long spans.
    // Spans up to 38K chars were causing 30s+ inference → auto-timeout cascade.
    const truncated = transcript.length > MAX_TRANSCRIPT_CHARS;
    const promptTranscript = truncated ? transcript.slice(0, MAX_TRANSCRIPT_CHARS) + "\n...[truncated]" : transcript;

    if (truncated) {
      console.log(
        `[journal-extract] Truncated transcript from ${transcript.length} to ${MAX_TRANSCRIPT_CHARS} chars for span ${span_id}`,
      );
    }

    const userPrompt =
      `TRANSCRIPT SEGMENT (span_id: ${span_id}, interaction: ${interaction_id}):\n"""\n${promptTranscript}\n"""\n\nExtract all project-relevant claims from this transcript segment.`;

    let extraction: ExtractionResponse;
    let tokens_used = 0;
    let inference_ms = 0;
    let retried = false;

    // ── ATTEMPT 1: Normal extraction ──────────────────────────────
    const result1 = await callLlm(anthropicKey, model, SYSTEM_PROMPT, userPrompt, timeoutMs);
    tokens_used = result1.tokens_used;
    inference_ms = result1.inference_ms;

    try {
      extraction = parseExtractionJson(result1.rawContent);
    } catch (parseErr: any) {
      // ── ATTEMPT 2: Retry with strict JSON-only prompt ─────────
      // Skip retry if the first attempt itself timed out — retrying would
      // also timeout and just double the wall-clock time.
      if (parseErr.message?.includes("timeout")) {
        throw parseErr; // propagate directly to catch block
      }

      console.warn(`[journal-extract] Parse failed on attempt 1: ${parseErr.message}. Retrying with strict prompt.`);
      retried = true;

      const retryPrompt =
        `TRANSCRIPT SEGMENT (span_id: ${span_id}, interaction: ${interaction_id}):\n"""\n${promptTranscript}\n"""\n\nExtract all project-relevant claims. Output ONLY valid JSON — no markdown, no code fences, no comments.`;

      const result2 = await callLlm(anthropicKey, model, RETRY_SYSTEM_PROMPT, retryPrompt, timeoutMs);
      tokens_used += result2.tokens_used;
      inference_ms += result2.inference_ms;

      extraction = parseExtractionJson(result2.rawContent);
      // If this also throws, it propagates to the outer catch
    }

    const speakerContactMap = new Map<string, { contact_id: string; contact_name: string; is_internal: boolean }>();

    if (project_id) {
      const uniqueSpeakers = [...new Set(extraction.claims.map((c) => c.speaker_label).filter(Boolean))];
      for (const label of uniqueSpeakers) {
        try {
          const { data: resolved } = await db.rpc("resolve_speaker_contact", {
            p_speaker_label: label,
            p_project_id: project_id,
          });
          if (resolved && resolved.length > 0) {
            speakerContactMap.set(label!, {
              contact_id: resolved[0].contact_id,
              contact_name: resolved[0].contact_name,
              is_internal: resolved[0].is_internal,
            });
          }
        } catch { /* speaker resolution is best-effort */ }
      }
    }

    let claims_written = 0;
    let loops_written = 0;
    const claim_ids: string[] = [];
    let skipped_no_project = false;
    let skipped_non_assign_write_gate = false;
    let blocked_by_write_gate_claims = 0;
    const attribution_decision = attribution?.decision || null;
    let journal_consolidate_fired = false;
    let loop_closure_fired = false;

    if (!dry_run && extraction.claims.length > 0) {
      // ── NULL PROJECT_ID GUARD ────────────────────────────────────
      // journal_claims.project_id has NOT NULL + FK to projects(id).
      // If span has no attribution yet, we cannot write claims — the FK
      // would reject the insert. Return extraction results so caller
      // knows claims were found, and can re-trigger after attribution.
      if (!project_id) {
        skipped_no_project = true;
        console.warn(
          `[journal-extract] Skipping claim insert: span ${span_id} has no project attribution (FK constraint).`,
        );

        const { error: noProjectUpdateErr } = await db.from("journal_runs").update({
          status: "success",
          completed_at: new Date().toISOString(),
          claims_extracted: 0,
          error_message: "no_project_attribution: claims extracted but not written (FK constraint)",
        }).eq("run_id", run_id);
        if (noProjectUpdateErr) {
          console.error("[journal-extract] journal_runs update (no project) failed:", noProjectUpdateErr.message);
          return new Response(
            JSON.stringify({
              ok: false,
              error_code: "journal_runs_status_update_failed",
              error: noProjectUpdateErr.message,
              interaction_id,
              span_id,
            }),
            { status: 500, headers: { "Content-Type": "application/json" } },
          );
        }
      } else if (SKIP_NON_ASSIGN_WRITES && attribution_decision !== "assign") {
        skipped_non_assign_write_gate = true;
        blocked_by_write_gate_claims = extraction.claims.length;
        console.log(
          `[journal-extract][metric] review_contamination_write_blocked span_id=${span_id} decision=${
            attribution_decision ?? "unknown"
          } blocked_claims=${blocked_by_write_gate_claims}`,
        );

        const { error: gateUpdateErr } = await db.from("journal_runs").update({
          status: "success",
          completed_at: new Date().toISOString(),
          claims_extracted: extraction.claims.length,
          error_message: `write_gate_non_assign_blocked: decision=${
            attribution_decision ?? "unknown"
          } blocked_claims=${blocked_by_write_gate_claims}`,
        }).eq("run_id", run_id);
        if (gateUpdateErr) {
          console.error("[journal-extract] journal_runs update (write gate) failed:", gateUpdateErr.message);
        }
      } else {
        const claimRows = extraction.claims.map((c) => {
          const speaker = c.speaker_label ? speakerContactMap.get(c.speaker_label) : null;
          const claim_id = crypto.randomUUID();
          claim_ids.push(claim_id);
          const claimIsConfirmed = attribution_decision === "assign" && !!project_id;

          return {
            claim_id,
            run_id,
            call_id: interaction_id,
            project_id,
            claim_project_id: project_id,
            claim_project_confidence: attribution?.confidence ?? null,
            source_span_id: span_id,
            claim_type: c.claim_type,
            claim_text: c.claim_text,
            attribution_decision,
            claim_confirmation_state: claimIsConfirmed ? "confirmed" : "unconfirmed",
            confirmed_at: claimIsConfirmed ? new Date().toISOString() : null,
            confirmed_by: claimIsConfirmed ? "journal_extract_auto_assign" : null,
            epistemic_status: c.epistemic_status,
            warrant_level: c.warrant_level,
            testimony_type: c.testimony_type,
            speaker_label: c.speaker_label,
            speaker_contact_id: speaker?.contact_id || null,
            speaker_is_internal: speaker?.is_internal || null,
            start_sec: c.start_sec,
            end_sec: c.end_sec,
            char_start: null,
            char_end: null,
            // Seed span_text so trg_journal_claim_compute_pointer can compute locator/hash.
            span_text: c.claim_text,
            span_hash: null,
            pointer_type: "transcript_span",
            relationship: "new",
            active: true,
            extraction_model_id: model,
            extraction_prompt_version: PROMPT_VERSION,
          };
        });

        // Use insert_journal_claims_dedup RPC for ON CONFLICT DO NOTHING
        // (belt-and-suspenders with application-level idempotency guard above)
        const { data: insertedCountRaw, error: claimErr } = await db.rpc("insert_journal_claims_dedup", {
          p_rows: claimRows,
        });

        if (claimErr) {
          console.error("[journal-extract] journal_claims insert failed:", claimErr.message);
          // Best-effort: mark the run as failed
          try {
            await db.from("journal_runs").update({
              status: "failed",
              completed_at: new Date().toISOString(),
              error_message: `journal_claims_write_failed: ${claimErr.message}`.slice(0, 500),
            }).eq("run_id", run_id);
          } catch { /* best-effort */ }
          return new Response(
            JSON.stringify({
              ok: false,
              error_code: "journal_claims_write_failed",
              error: claimErr.message,
              interaction_id,
              span_id,
            }),
            { status: 500, headers: { "Content-Type": "application/json" } },
          );
        } else {
          const insertedCount = typeof insertedCountRaw === "number"
            ? insertedCountRaw
            : Number.parseInt(String(insertedCountRaw ?? "0"), 10);
          claims_written = Number.isFinite(insertedCount) ? insertedCount : 0;
        }

        const openLoopClaims = extraction.claims.filter((c) => c.is_open_loop);
        if (openLoopClaims.length > 0) {
          const loopRowsRaw = openLoopClaims.map((c) => ({
            run_id,
            call_id: interaction_id,
            project_id,
            loop_type: normalizeLoopType(c.open_loop_type, c.claim_type),
            description: c.claim_text,
            start_sec: c.start_sec,
            end_sec: c.end_sec,
            status: "open",
          }));

          let loopRows = loopRowsRaw;
          const { data: existingLoops, error: existingLoopsErr } = await db
            .from("journal_open_loops")
            .select("loop_type, description")
            .eq("call_id", interaction_id)
            .eq("project_id", project_id)
            .eq("status", "open");

          if (existingLoopsErr) {
            console.warn("[journal-extract] journal_open_loops dedup lookup failed:", existingLoopsErr.message);
          } else if (existingLoops && existingLoops.length > 0) {
            const existingKeys = new Set(
              existingLoops.map((row: any) =>
                `${String(row.loop_type || "").trim().toLowerCase()}|${String(row.description || "").trim()}`
              ),
            );
            loopRows = loopRowsRaw.filter((row) =>
              !existingKeys.has(`${row.loop_type.trim().toLowerCase()}|${row.description.trim()}`)
            );
          }

          if (loopRows.length > 0) {
            const { error: loopErr } = await db.from("journal_open_loops").insert(loopRows);
            if (loopErr) {
              console.error("[journal-extract] journal_open_loops insert failed:", loopErr.message);
              // Best-effort: mark run failed so it doesn't remain stuck in running.
              try {
                await db.from("journal_runs").update({
                  status: "failed",
                  completed_at: new Date().toISOString(),
                  error_message: `journal_open_loops_write_failed: ${loopErr.message}`.slice(0, 500),
                }).eq("run_id", run_id);
              } catch { /* best-effort */ }
              return new Response(
                JSON.stringify({
                  ok: false,
                  error_code: "journal_open_loops_write_failed",
                  error: loopErr.message,
                  interaction_id,
                  span_id,
                }),
                { status: 500, headers: { "Content-Type": "application/json" } },
              );
            }
            loops_written = loopRows.length;
          }
        }

        const { error: successUpdateErr } = await db.from("journal_runs").update({
          status: "success",
          completed_at: new Date().toISOString(),
          claims_extracted: claims_written,
        }).eq("run_id", run_id);
        if (successUpdateErr) {
          console.error("[journal-extract] journal_runs update (success) failed:", successUpdateErr.message);
          return new Response(
            JSON.stringify({
              ok: false,
              error_code: "journal_runs_status_update_failed",
              error: successUpdateErr.message,
              interaction_id,
              span_id,
            }),
            { status: 500, headers: { "Content-Type": "application/json" } },
          );
        }

        if (project_id && run_id && expectedSecret) {
          const supabaseUrl = Deno.env.get("SUPABASE_URL");
          if (supabaseUrl) {
            if (claims_written > 0) {
              journal_consolidate_fired = true;
              void triggerJournalConsolidate(supabaseUrl, expectedSecret, run_id);
            }
            if (claims_written > 0 || loops_written > 0) {
              loop_closure_fired = true;
              void triggerLoopClosure(supabaseUrl, expectedSecret, interaction_id, project_id);
            }
          }
        }
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        span_id,
        interaction_id,
        project_id,
        run_id: dry_run ? null : run_id,
        claims_extracted: extraction.claims.length,
        claims_written,
        open_loops_written: loops_written,
        claim_ids: dry_run ? [] : claim_ids,
        summary: extraction.summary,
        speakers_resolved: speakerContactMap.size,
        write_gate_enabled: SKIP_NON_ASSIGN_WRITES,
        skipped_non_assign_write_gate,
        blocked_by_write_gate_claims,
        attribution_decision,
        skipped_no_project,
        ...(skipped_no_project ? { reason: "no_project_attribution: re-trigger after ai-router attributes span" } : {}),
        model,
        journal_consolidate_fired,
        loop_closure_fired,
        tokens_used,
        inference_ms,
        retried,
        dry_run,
        transcript_chars: transcript.length,
        truncated,
        prompt_version: PROMPT_VERSION,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e: any) {
    console.error("[journal-extract] Error:", e.message);

    if (!body.dry_run && run_id) {
      try {
        // Use run_id (not call_id) to target the exact row this invocation created.
        // Using call_id could match multiple runs for the same interaction.
        const { error: failUpdateErr } = await db.from("journal_runs").update({
          status: "failed",
          completed_at: new Date().toISOString(),
          error_message: e.message?.slice(0, 500),
        }).eq("run_id", run_id).eq("status", "running");
        if (failUpdateErr) {
          console.error("[journal-extract] journal_runs update (failed) error:", failUpdateErr.message);
        }
      } catch { /* ignore — best-effort failure recording */ }
    }

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
