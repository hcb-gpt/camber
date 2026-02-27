/**
 * segment-llm Edge Function v1.0.0
 * LLM-powered call segmenter: identifies project-switch boundaries in transcripts
 *
 * @version 1.0.0
 * @date 2026-01-31
 * @purpose Segment transcripts into N spans for multi-project attribution
 *
 * Auth: X-Edge-Secret == EDGE_SHARED_SECRET (verify_jwt: false)
 * Called from: segment-call only
 *
 * STOPLINES (from CLAUDE.md):
 * - Never assigns project truth
 * - Never writes DB
 * - Never drops transcript content
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { parseLlmJson } from "../_shared/llm_json.ts";

const SEGMENT_LLM_VERSION = "segment-llm_v1.5.0";

// ============================================================
// STRUCTURED LOGGING (per GPT-DEV-6 spec)
// ============================================================
type LogLevel = "DEBUG" | "INFO" | "WARN" | "ERROR";

function structuredLog(
  level: LogLevel,
  event: string,
  requestId: string,
  interactionId: string | null,
  extra: Record<string, unknown> = {},
): void {
  const log = {
    ts: new Date().toISOString(),
    level,
    service: "edge-function",
    function: "segment-llm",
    event,
    interaction_id: interactionId,
    generation: null, // segment-llm doesn't track generation
    request_id: requestId,
    correlation_id: `${interactionId || "unknown"}:0:${requestId}`,
    segmenter_version: SEGMENT_LLM_VERSION,
    ...extra,
  };
  if (level === "ERROR") {
    console.error(JSON.stringify(log));
  } else {
    console.log(JSON.stringify(log));
  }
}

// ============================================================
// GUARDRAIL DEFAULTS
// ============================================================
const DEFAULT_MAX_SEGMENTS = 6;
const DEFAULT_MIN_SEGMENT_CHARS = 200;
const DEFAULT_MAX_SEGMENT_CHARS = 8000;
const DEFAULT_TARGET_SEGMENT_CHARS = 5000;
const PROJECT_ANCHOR_TERMS = ["woodberry", "sparta"];
type SegmentationChannel = "call" | "sms_thread";

// ============================================================
// TYPES
// ============================================================
interface Segment {
  span_index: number;
  char_start: number;
  char_end: number;
  boundary_reason: string;
  confidence: number;
  boundary_quote: string | null;
}

interface SegmentLLMOutput {
  ok: boolean;
  segmenter_version: string;
  segments: Segment[];
  warnings: string[];
  error_code?: string;
  ms?: number;
}

// ============================================================
// LLM PROMPT
// ============================================================
const CALL_SEGMENTATION_PROMPT = `You are a call transcript segmenter for a construction company.

Your task: Identify boundaries where the conversation switches from one PROJECT to another.

RULES:
1. A "project" is a specific construction job (e.g., "Johnson Residence", "Smith Project", "the Hurley job")
2. Split ONLY when there's a clear topic/project switch
3. Do NOT split for:
   - Speaker changes within same project discussion
   - Brief tangents that return to same project
   - General greetings/closings
4. Each segment must be >= {MIN_CHARS} characters (merge smaller ones into previous)
5. Maximum {MAX_SEGMENTS} segments total
6. Segments must be contiguous (no gaps, no overlaps)

OUTPUT FORMAT (JSON only, no markdown):
{
  "segments": [
    {
      "span_index": 0,
      "char_start": 0,
      "char_end": <end_char>,
      "boundary_reason": "initial_project|topic_shift|project_switch",
      "confidence": 0.0-1.0,
      "boundary_quote": "<exact quote <=50 chars showing the switch>"
    }
  ]
}

TRANSCRIPT:
{TRANSCRIPT}`;

const SMS_SEGMENTATION_PROMPT = `You are an SMS thread segmenter for a construction company.

Your task: Identify boundaries where the thread switches to a different project/work context.

RULES:
1. Split when there is a clear project switch, scheduling block shift, issue/resolution shift, or major participant intent shift
2. Do NOT split for brief acknowledgements, short confirmations, emojis, or duplicate follow-ups within the same topic
3. Keep multi-message exchanges on the same project together
4. Each segment must be >= {MIN_CHARS} characters (merge smaller ones into previous)
5. Maximum {MAX_SEGMENTS} segments total
6. Segments must be contiguous (no gaps, no overlaps)

OUTPUT FORMAT (JSON only, no markdown):
{
  "segments": [
    {
      "span_index": 0,
      "char_start": 0,
      "char_end": <end_char>,
      "boundary_reason": "thread_start|topic_shift|project_switch|time_gap|participant_shift",
      "confidence": 0.0-1.0,
      "boundary_quote": "<exact quote <=50 chars showing the switch>"
    }
  ]
}

TRANSCRIPT:
{TRANSCRIPT}`;

const CALL_SEGMENTATION_RETRY_PROMPT = `You are a call transcript segmenter for a construction company.

CRITICAL REQUIREMENT: For transcripts over 2000 characters, you MUST produce AT LEAST 2 segments unless the call is genuinely single-topic with NO project switches whatsoever.

Your task: Identify boundaries where the conversation switches from one PROJECT to another.

RULES:
1. A "project" is a specific construction job (e.g., "Johnson Residence", "Smith Project", "the Hurley job")
2. For transcripts > 2000 chars: find at least ONE natural break point (topic shift, pause, speaker change on different topic)
3. If truly single-topic: return 1 segment with high confidence, but this should be rare for long calls
4. Each segment must be >= {MIN_CHARS} characters (merge smaller ones into previous)
5. Maximum {MAX_SEGMENTS} segments total
6. Segments must be contiguous (no gaps, no overlaps)

OUTPUT FORMAT (JSON only, no markdown):
{
  "segments": [
    {
      "span_index": 0,
      "char_start": 0,
      "char_end": <end_char>,
      "boundary_reason": "initial_project|topic_shift|project_switch|natural_break",
      "confidence": 0.0-1.0,
      "boundary_quote": "<exact quote <=50 chars showing the switch>"
    }
  ]
}

TRANSCRIPT:
{TRANSCRIPT}`;

const SMS_SEGMENTATION_RETRY_PROMPT = `You are an SMS thread segmenter for a construction company.

CRITICAL REQUIREMENT: For long SMS threads over 2000 characters, produce AT LEAST 2 segments unless all messages clearly remain in one continuous topic.

Your task: Identify boundaries where the thread switches project/work context.

RULES:
1. Prefer boundaries at project switches, scheduling windows, issue handoffs, or substantial context changes
2. Avoid splitting short acknowledgements, repetitive check-ins, or minor wording changes
3. If truly single-topic: return 1 segment with high confidence, but this should be rare for long threads
4. Each segment must be >= {MIN_CHARS} characters (merge smaller ones into previous)
5. Maximum {MAX_SEGMENTS} segments total
6. Segments must be contiguous (no gaps, no overlaps)

OUTPUT FORMAT (JSON only, no markdown):
{
  "segments": [
    {
      "span_index": 0,
      "char_start": 0,
      "char_end": <end_char>,
      "boundary_reason": "thread_start|topic_shift|project_switch|time_gap|participant_shift",
      "confidence": 0.0-1.0,
      "boundary_quote": "<exact quote <=50 chars showing the switch>"
    }
  ]
}

TRANSCRIPT:
{TRANSCRIPT}`;

function normalizeSegmentationChannel(
  rawChannel: unknown,
  interactionId: string | null,
): SegmentationChannel {
  const normalized = String(rawChannel || "").trim().toLowerCase();
  if (
    normalized === "sms_thread" || normalized === "sms" ||
    normalized === "text" || normalized === "text_message"
  ) {
    return "sms_thread";
  }
  const iid = String(interactionId || "").toLowerCase();
  if (iid.startsWith("sms_thread_") || iid.startsWith("beside_sms_")) {
    return "sms_thread";
  }
  return "call";
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

  // ============================================================
  // AUTH GATE: X-Edge-Secret
  // ============================================================
  const edgeSecretHeader = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const provenanceSource = body.source || "unknown";

  // Strict auth: matching shared edge secret
  const hasValidAuth = expectedSecret &&
    edgeSecretHeader === expectedSecret;

  if (!hasValidAuth) {
    console.error(
      `[segment-llm] Auth failed: source=${provenanceSource}, hasSecret=${!!edgeSecretHeader}`,
    );
    return new Response(
      JSON.stringify({
        ok: false,
        error: "unauthorized",
        error_code: "auth_failed",
        hint: "Requires X-Edge-Secret matching EDGE_SHARED_SECRET",
        version: SEGMENT_LLM_VERSION,
      }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  console.log(`[segment-llm] Auth passed: source=${provenanceSource}`);

  // ============================================================
  // INPUT VALIDATION
  // ============================================================
  const {
    interaction_id,
    transcript,
    channel,
    max_segments = DEFAULT_MAX_SEGMENTS,
    min_segment_chars = DEFAULT_MIN_SEGMENT_CHARS,
    max_segment_chars = DEFAULT_MAX_SEGMENT_CHARS,
  } = body;

  const parsedMaxSegmentChars = Number(max_segment_chars);
  const maxSegmentChars = Number.isFinite(parsedMaxSegmentChars) &&
      parsedMaxSegmentChars >= min_segment_chars * 2
    ? Math.floor(parsedMaxSegmentChars)
    : DEFAULT_MAX_SEGMENT_CHARS;

  if (!interaction_id) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "missing_interaction_id",
        error_code: "bad_request",
        version: SEGMENT_LLM_VERSION,
      }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  if (!transcript || typeof transcript !== "string") {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "missing_or_invalid_transcript",
        error_code: "bad_request",
        version: SEGMENT_LLM_VERSION,
      }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  const transcriptLength = transcript.length;
  const requestId = req.headers.get("x-request-id") || crypto.randomUUID();
  const caller = provenanceSource;
  const segmentationChannel = normalizeSegmentationChannel(channel, interaction_id);

  // Structured log: segment_llm_request
  structuredLog("INFO", "segment_llm_request", requestId, interaction_id, {
    transcript_chars: transcriptLength,
    caller,
    channel: segmentationChannel,
    params: { max_segments, min_segment_chars, max_segment_chars: maxSegmentChars },
  });

  console.log(
    `[segment-llm] Processing: interaction_id=${interaction_id}, len=${transcriptLength}`,
  );

  // ============================================================
  // SHORT TRANSCRIPT FAST PATH
  // ============================================================
  if (transcriptLength < min_segment_chars * 2) {
    // Too short for meaningful segmentation - return single span
    console.log(`[segment-llm] Short transcript (${transcriptLength} chars), returning single span`);
    return new Response(
      JSON.stringify({
        ok: true,
        segmenter_version: SEGMENT_LLM_VERSION,
        segments: [
          {
            span_index: 0,
            char_start: 0,
            char_end: transcriptLength,
            boundary_reason: "full_call_short",
            confidence: 1.0,
            boundary_quote: null,
          },
        ],
        warnings: ["transcript_too_short_for_segmentation"],
        ms: Date.now() - t0,
      } as SegmentLLMOutput),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  // ============================================================
  // LLM CALL (OpenAI)
  // ============================================================
  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) {
    console.error("[segment-llm] OPENAI_API_KEY not configured");
    return fallbackResponse(transcriptLength, ["config_error_no_api_key"], t0);
  }

  const promptTemplate = segmentationChannel === "sms_thread" ? SMS_SEGMENTATION_PROMPT : CALL_SEGMENTATION_PROMPT;
  const prompt = promptTemplate
    .replace("{TRANSCRIPT}", transcript)
    .replace("{MIN_CHARS}", String(min_segment_chars))
    .replace("{MAX_SEGMENTS}", String(max_segments));

  let llmResponse: any;
  try {
    const resp = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${openaiKey}`,
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        max_tokens: 1024,
        messages: [
          {
            role: "user",
            content: prompt,
          },
        ],
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      console.error(`[segment-llm] LLM API error: ${resp.status} ${errText}`);
      // Structured log: segment_llm_error
      structuredLog("ERROR", "segment_llm_error", requestId, interaction_id, {
        error_code: `llm_api_${resp.status}`,
        error_class: "openai_http_error",
        duration_ms: Date.now() - t0,
      });
      return fallbackResponse(transcriptLength, [`llm_api_error_${resp.status}`], t0);
    }

    llmResponse = await resp.json();
  } catch (fetchErr: any) {
    console.error(`[segment-llm] LLM fetch error: ${fetchErr.message}`);
    // Structured log: segment_llm_error
    structuredLog("ERROR", "segment_llm_error", requestId, interaction_id, {
      error_code: "llm_fetch_error",
      error_class: fetchErr.message || "unknown",
      duration_ms: Date.now() - t0,
    });
    return fallbackResponse(transcriptLength, [`llm_fetch_error`], t0);
  }

  // ============================================================
  // PARSE LLM OUTPUT (OpenAI format)
  // ============================================================
  let rawContent = "";
  try {
    rawContent = llmResponse.choices?.[0]?.message?.content || "";
  } catch {
    console.error("[segment-llm] Failed to extract LLM text");
    return fallbackResponse(transcriptLength, ["llm_parse_error_extract"], t0);
  }

  let parsed: { segments?: Segment[] };
  try {
    parsed = parseLlmJson<{ segments?: Segment[] }>(rawContent).value;
  } catch (_parseErr) {
    console.error(`[segment-llm] JSON parse failed: ${rawContent.slice(0, 200)}`);
    return fallbackResponse(transcriptLength, ["llm_parse_error_json"], t0);
  }

  if (!Array.isArray(parsed.segments) || parsed.segments.length === 0) {
    console.error("[segment-llm] No segments array in LLM output");
    return fallbackResponse(transcriptLength, ["llm_output_invalid_no_segments"], t0);
  }

  // ============================================================
  // GUARDRAILS: Validate and fix segments
  // ============================================================
  const warnings: string[] = [];
  let segments = parsed.segments;

  // 1. Clamp boundaries to [0, transcriptLength]
  segments = segments.map((seg) => ({
    ...seg,
    char_start: Math.max(0, Math.min(seg.char_start, transcriptLength)),
    char_end: Math.max(0, Math.min(seg.char_end, transcriptLength)),
  }));

  // 2. Sort by char_start and fix span_index
  segments.sort((a, b) => a.char_start - b.char_start);
  segments = segments.map((seg, idx) => ({ ...seg, span_index: idx }));

  // 3. Make contiguous (no gaps, no overlaps)
  for (let i = 1; i < segments.length; i++) {
    if (segments[i].char_start !== segments[i - 1].char_end) {
      warnings.push(`gap_fixed_at_index_${i}`);
      segments[i].char_start = segments[i - 1].char_end;
    }
  }

  // 4. Ensure first starts at 0, last ends at transcriptLength
  if (segments[0].char_start !== 0) {
    warnings.push("first_segment_start_fixed");
    segments[0].char_start = 0;
  }
  if (segments[segments.length - 1].char_end !== transcriptLength) {
    warnings.push("last_segment_end_fixed");
    segments[segments.length - 1].char_end = transcriptLength;
  }

  // 5. Merge undersized segments into previous
  let merged = true;
  while (merged && segments.length > 1) {
    merged = false;
    for (let i = segments.length - 1; i >= 0; i--) {
      const size = segments[i].char_end - segments[i].char_start;
      if (size < min_segment_chars && segments.length > 1) {
        if (i > 0) {
          // Merge into previous
          segments[i - 1].char_end = segments[i].char_end;
          segments[i - 1].boundary_reason += "_merged_undersized";
          segments.splice(i, 1);
          warnings.push(`merged_undersized_segment_${i}`);
          merged = true;
          break;
        } else if (i === 0 && segments.length > 1) {
          // First segment undersized - merge with next
          segments[1].char_start = segments[0].char_start;
          segments.splice(0, 1);
          warnings.push("merged_undersized_first_segment");
          merged = true;
          break;
        }
      }
    }
  }

  // 6. Re-index after merges
  segments = segments.map((seg, idx) => ({ ...seg, span_index: idx }));

  // 7. Enforce max_segments by merging lowest-confidence boundaries
  while (segments.length > max_segments) {
    // Find lowest confidence segment (excluding first)
    let minConfIdx = 1;
    let minConf = segments[1].confidence;
    for (let i = 2; i < segments.length; i++) {
      if (segments[i].confidence < minConf) {
        minConf = segments[i].confidence;
        minConfIdx = i;
      }
    }
    // Merge with previous
    segments[minConfIdx - 1].char_end = segments[minConfIdx].char_end;
    segments.splice(minConfIdx, 1);
    warnings.push(`merged_low_confidence_segment_${minConfIdx}`);
  }

  // 8. Final re-index
  segments = segments.map((seg, idx) => ({ ...seg, span_index: idx }));

  // 9. Validate no zero-length segments
  segments = segments.filter((seg) => {
    if (seg.char_end <= seg.char_start) {
      warnings.push(`removed_zero_length_segment_${seg.span_index}`);
      return false;
    }
    return true;
  });

  // 10. Final re-index
  segments = segments.map((seg, idx) => ({ ...seg, span_index: idx }));

  // If all segments got filtered out, fallback
  if (segments.length === 0) {
    return fallbackResponse(transcriptLength, ["all_segments_invalid"], t0);
  }

  // ============================================================
  // RETRY LOGIC: Single span on long transcript (P0 Task)
  // ============================================================
  // If transcript > 2000 chars and LLM returned only 1 span, retry with stricter instruction
  let retriedOnce = false;
  if (transcriptLength > 2000 && segments.length === 1) {
    console.log(
      `[segment-llm] Single span on long transcript (${transcriptLength} chars) - retrying with stricter instruction`,
    );
    warnings.push("single_span_retry_attempt");
    retriedOnce = true;

    const stricterPromptTemplate = segmentationChannel === "sms_thread"
      ? SMS_SEGMENTATION_RETRY_PROMPT
      : CALL_SEGMENTATION_RETRY_PROMPT;
    const retryPrompt = stricterPromptTemplate
      .replace("{TRANSCRIPT}", transcript)
      .replace("{MIN_CHARS}", String(min_segment_chars))
      .replace("{MAX_SEGMENTS}", String(max_segments));

    try {
      const retryResp = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${openaiKey}`,
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          max_tokens: 1024,
          messages: [
            {
              role: "user",
              content: retryPrompt,
            },
          ],
        }),
      });

      if (retryResp.ok) {
        const retryData = await retryResp.json();
        const retryContent = (retryData.choices?.[0]?.message?.content || "")
          .replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();

        try {
          const retryParsed = parseLlmJson<{ segments?: Segment[] }>(retryContent).value;
          if (Array.isArray(retryParsed.segments) && retryParsed.segments.length > 0) {
            // Re-run guardrails on retry result (simplified version)
            let retrySegments = retryParsed.segments;
            retrySegments = retrySegments.map((seg: any) => ({
              ...seg,
              char_start: Math.max(0, Math.min(seg.char_start, transcriptLength)),
              char_end: Math.max(0, Math.min(seg.char_end, transcriptLength)),
            }));
            retrySegments.sort((a: any, b: any) => a.char_start - b.char_start);
            retrySegments = retrySegments.map((seg: any, idx: number) => ({ ...seg, span_index: idx }));

            // Make contiguous
            for (let i = 1; i < retrySegments.length; i++) {
              if (retrySegments[i].char_start !== retrySegments[i - 1].char_end) {
                retrySegments[i].char_start = retrySegments[i - 1].char_end;
              }
            }
            if (retrySegments[0].char_start !== 0) retrySegments[0].char_start = 0;
            if (retrySegments[retrySegments.length - 1].char_end !== transcriptLength) {
              retrySegments[retrySegments.length - 1].char_end = transcriptLength;
            }

            // If retry gave us multiple segments, use them!
            if (retrySegments.length > 1) {
              console.log(`[segment-llm] Retry successful: ${retrySegments.length} segments`);
              segments = retrySegments;
              warnings.push("single_span_retry_successful");
            } else {
              warnings.push("single_span_retry_still_single");
            }
          }
        } catch (_retryParseErr) {
          warnings.push("single_span_retry_parse_error");
        }
      } else {
        warnings.push("single_span_retry_http_error");
      }
    } catch (_retryErr: any) {
      warnings.push("single_span_retry_fetch_error");
    }
  }

  // ============================================================
  // DETERMINISTIC FALLBACK: If still single span after retry
  // ============================================================
  if (transcriptLength > 2000 && segments.length === 1) {
    console.log(`[segment-llm] Still single span after retry - using deterministic fallback split`);
    warnings.push("deterministic_fallback_applied");

    // Split transcript into deterministic equal segments to keep long calls bounded.
    const numFallbackSegments = Math.max(
      2,
      Math.min(max_segments, Math.ceil(transcriptLength / DEFAULT_TARGET_SEGMENT_CHARS)),
    );
    const segmentSize = Math.floor(transcriptLength / numFallbackSegments);

    segments = [];
    for (let i = 0; i < numFallbackSegments; i++) {
      const charStart = i * segmentSize;
      const charEnd = i === numFallbackSegments - 1 ? transcriptLength : (i + 1) * segmentSize;
      segments.push({
        span_index: i,
        char_start: charStart,
        char_end: charEnd,
        boundary_reason: "deterministic_fallback_split",
        confidence: 0.5, // Lower confidence for fallback
        boundary_quote: null,
      });
    }

    // Mark these segments with fallback metadata flag
    // This will be added to segment_metadata in segment-call
    warnings.push(`fallback_split_${numFallbackSegments}_segments`);
  }

  // ============================================================
  // OVERSIZE GUARDRAIL: Split oversized segments in multi-span output
  // ============================================================
  if (segments.some((seg) => (seg.char_end - seg.char_start) > maxSegmentChars)) {
    const beforeCount = segments.length;
    segments = splitOversizedSegments(
      segments,
      transcript,
      min_segment_chars,
      maxSegmentChars,
      warnings,
    );
    if (segments.length > beforeCount) {
      warnings.push(`oversize_guardrail_segments_added_${segments.length - beforeCount}`);
    }
  }

  // Preserve boundary evidence for known anchor terms when present.
  segments = ensureAnchorBoundaryEvidence(segments, transcript, warnings);

  // Truncate boundary_quote to 50 chars
  segments = segments.map((seg) => ({
    ...seg,
    boundary_quote: seg.boundary_quote ? seg.boundary_quote.slice(0, 50) : null,
  }));

  const durationMs = Date.now() - t0;
  console.log(`[segment-llm] Produced ${segments.length} segments with ${warnings.length} warnings`);

  // Structured log: segment_llm_response
  structuredLog("INFO", "segment_llm_response", requestId, interaction_id, {
    segments_returned: segments.length,
    duration_ms: durationMs,
    retry_attempted: retriedOnce,
    deterministic_fallback: warnings.includes("deterministic_fallback_applied"),
    max_segment_chars: maxSegmentChars,
  });

  return new Response(
    JSON.stringify({
      ok: true,
      segmenter_version: SEGMENT_LLM_VERSION,
      segmentation_channel: segmentationChannel,
      segments,
      warnings,
      ms: durationMs,
    } as SegmentLLMOutput),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});

// ============================================================
// FALLBACK: Return single full-call segment
// ============================================================
function fallbackResponse(
  transcriptLength: number,
  warnings: string[],
  t0: number,
): Response {
  console.log(`[segment-llm] Fallback: ${warnings.join(", ")}`);
  return new Response(
    JSON.stringify({
      ok: true,
      segmenter_version: "fallback_trivial_v1",
      segments: [
        {
          span_index: 0,
          char_start: 0,
          char_end: transcriptLength,
          boundary_reason: "fallback_full_call",
          confidence: 1.0,
          boundary_quote: null,
        },
      ],
      warnings: ["llm_failed_fallback", ...warnings],
      ms: Date.now() - t0,
    } as SegmentLLMOutput),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

function splitOversizedSegments(
  segments: Segment[],
  transcript: string,
  minSegmentChars: number,
  maxSegmentChars: number,
  warnings: string[],
): Segment[] {
  const result: Segment[] = [];
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    const segLen = seg.char_end - seg.char_start;
    if (segLen <= maxSegmentChars) {
      result.push(seg);
      continue;
    }

    const split = splitOneSegmentBySize(
      seg,
      transcript,
      minSegmentChars,
      maxSegmentChars,
    );

    if (split.length > 1) {
      warnings.push(`oversize_segment_split_${i}_into_${split.length}`);
    } else {
      warnings.push(`oversize_segment_unsplit_${i}`);
    }
    result.push(...split);
  }

  return result.map((seg, idx) => ({ ...seg, span_index: idx }));
}

function splitOneSegmentBySize(
  segment: Segment,
  transcript: string,
  minSegmentChars: number,
  maxSegmentChars: number,
): Segment[] {
  const segmentLen = segment.char_end - segment.char_start;
  if (segmentLen <= maxSegmentChars) return [segment];

  const maxPossibleChunks = Math.max(1, Math.floor(segmentLen / Math.max(1, minSegmentChars)));
  const desiredChunks = Math.max(
    2,
    Math.ceil(segmentLen / maxSegmentChars),
    Math.ceil(segmentLen / DEFAULT_TARGET_SEGMENT_CHARS),
  );
  const chunkCount = Math.min(desiredChunks, maxPossibleChunks);
  if (chunkCount <= 1) return [segment];

  const splitPoints: number[] = [];
  let cursor = segment.char_start;

  // Split near known project anchors first (if feasible), then by natural boundaries.
  const anchorPositions = collectAnchorPositions(transcript, segment.char_start, segment.char_end);
  let nextAnchorIdx = 0;

  for (let chunkIdx = 1; chunkIdx < chunkCount; chunkIdx++) {
    const remainingChunksAfterSplit = chunkCount - chunkIdx;
    const remainingLen = segment.char_end - cursor;
    const target = cursor + Math.floor(remainingLen / (remainingChunksAfterSplit + 1));

    let splitPoint: number | null = null;
    for (let j = nextAnchorIdx; j < anchorPositions.length; j++) {
      const anchor = anchorPositions[j];
      if (anchor <= cursor + minSegmentChars) continue;
      splitPoint = findNaturalSplitPoint(
        transcript,
        cursor,
        segment.char_end,
        anchor,
        minSegmentChars,
        remainingChunksAfterSplit,
        maxSegmentChars,
      );
      nextAnchorIdx = j + 1;
      break;
    }

    if (splitPoint === null) {
      splitPoint = findNaturalSplitPoint(
        transcript,
        cursor,
        segment.char_end,
        target,
        minSegmentChars,
        remainingChunksAfterSplit,
        maxSegmentChars,
      );
    }

    if (
      splitPoint === null || splitPoint <= cursor ||
      splitPoint >= segment.char_end
    ) {
      break;
    }

    splitPoints.push(splitPoint);
    cursor = splitPoint;
  }

  if (splitPoints.length === 0) return [segment];

  const boundaries = [segment.char_start, ...splitPoints, segment.char_end];
  const rebuilt: Segment[] = [];
  for (let i = 0; i < boundaries.length - 1; i++) {
    const start = boundaries[i];
    const end = boundaries[i + 1];
    rebuilt.push({
      span_index: i,
      char_start: start,
      char_end: end,
      boundary_reason: i === 0 ? segment.boundary_reason : "oversize_guardrail_split",
      confidence: i === 0 ? segment.confidence : Math.max(0.55, segment.confidence - 0.15),
      boundary_quote: i === 0 ? segment.boundary_quote : quoteAroundIndex(transcript, start),
    });
  }

  return rebuilt;
}

function findNaturalSplitPoint(
  transcript: string,
  start: number,
  end: number,
  target: number,
  minSegmentChars: number,
  remainingChunksAfterSplit: number,
  maxSegmentChars: number,
): number | null {
  const minSplit = start + minSegmentChars;
  const maxSplitByRemaining = end - (remainingChunksAfterSplit * minSegmentChars);
  const maxSplitBySize = start + maxSegmentChars;
  const maxSplit = Math.min(maxSplitByRemaining, maxSplitBySize);
  if (minSplit >= maxSplit) return null;

  const searchMin = Math.max(minSplit, target - 280);
  const searchMax = Math.min(maxSplit, target + 280);

  // Prefer clear conversational boundaries near the target.
  for (let i = searchMin; i <= searchMax; i++) {
    const prev = transcript[i - 1] || "";
    const curr = transcript[i] || "";
    if ((prev === "\n" && curr !== "\n") || (":.!?;,".includes(prev) && /\s/.test(curr))) {
      return i;
    }
  }

  // Fallback to whitespace closest to target.
  let bestWhitespace = -1;
  let bestDistance = Number.POSITIVE_INFINITY;
  for (let i = minSplit; i <= maxSplit; i++) {
    if (!/\s/.test(transcript[i] || "")) continue;
    const dist = Math.abs(i - target);
    if (dist < bestDistance) {
      bestDistance = dist;
      bestWhitespace = i;
    }
  }
  if (bestWhitespace >= minSplit && bestWhitespace <= maxSplit) return bestWhitespace;

  return Math.max(minSplit, Math.min(target, maxSplit));
}

function collectAnchorPositions(transcript: string, start: number, end: number): number[] {
  const lower = transcript.toLowerCase();
  const positions = new Set<number>();
  for (const term of PROJECT_ANCHOR_TERMS) {
    let idx = lower.indexOf(term, start);
    while (idx !== -1 && idx < end) {
      positions.add(idx);
      idx = lower.indexOf(term, idx + term.length);
    }
  }
  return Array.from(positions).sort((a, b) => a - b);
}

function quoteAroundIndex(transcript: string, index: number): string | null {
  const lo = Math.max(0, index - 40);
  const hi = Math.min(transcript.length, index + 40);
  const snippet = transcript.slice(lo, hi).replace(/\s+/g, " ").trim();
  return snippet.length > 0 ? snippet.slice(0, 50) : null;
}

function ensureAnchorBoundaryEvidence(
  segments: Segment[],
  transcript: string,
  warnings: string[],
): Segment[] {
  const transcriptLower = transcript.toLowerCase();
  const termsPresent = PROJECT_ANCHOR_TERMS.filter((term) => transcriptLower.includes(term));
  if (termsPresent.length === 0) return segments;

  const covered = new Set<string>();
  for (const seg of segments) {
    const quote = (seg.boundary_quote || "").toLowerCase();
    for (const term of termsPresent) {
      if (quote.includes(term)) covered.add(term);
    }
  }

  for (const term of termsPresent) {
    if (covered.has(term)) continue;

    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i];
      const text = transcriptLower.slice(seg.char_start, seg.char_end);
      const localIdx = text.indexOf(term);
      if (localIdx === -1) continue;

      const globalIdx = seg.char_start + localIdx;
      const anchorQuote = quoteAroundIndex(transcript, globalIdx);
      if (!anchorQuote) continue;

      segments[i] = {
        ...seg,
        boundary_quote: anchorQuote,
      };
      covered.add(term);
      warnings.push(`boundary_quote_anchor_${term}`);
      break;
    }
  }

  return segments;
}
