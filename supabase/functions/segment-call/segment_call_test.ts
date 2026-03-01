/**
 * segment-call unit tests
 *
 * Tests pure functions inlined from segment-call/index.ts:
 * - sanitizeTranscriptForPipeline: scrub control chars
 * - normalizeReasonCodes: coerce unknown → string[]
 * - deterministicSegmentsForLength: chunk fallback segmentation
 * - enforceMaxSegmentChars: split oversized segments
 * - isReviewQueueCompatColumnMissing: detect legacy schema errors
 * - isDuplicateKeyError: detect PG 23505 / duplicate-key errors
 * - shouldRunAuditor: decision auditor gate
 */
import {
  assertEquals,
  assertGreater,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

// ── sanitizeTranscriptForPipeline (inlined copy) ────────────────────
type TranscriptSanitizeResult = { text: string; replaced: number };

function sanitizeTranscriptForPipeline(text: string): TranscriptSanitizeResult {
  let replaced = 0;
  // deno-lint-ignore no-control-regex
  const sanitized = String(text || "").replace(/[\x00-\x1F\x7F]/g, () => {
    replaced += 1;
    return " ";
  });
  return { text: sanitized, replaced };
}

// ── normalizeReasonCodes (inlined copy) ─────────────────────────────
function normalizeReasonCodes(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((r) => String(r || "").trim()).filter(Boolean);
}

// ── deterministicSegmentsForLength (inlined copy) ───────────────────
type SegmentFromLLM = {
  span_index: number;
  char_start: number;
  char_end: number;
  boundary_reason: string;
  confidence: number;
  boundary_quote: string | null;
};

function deterministicSegmentsForLength(
  transcriptLength: number,
  maxSegmentChars: number,
  boundaryReason: string,
): SegmentFromLLM[] {
  if (transcriptLength <= 0) {
    return [{
      span_index: 0,
      char_start: 0,
      char_end: 0,
      boundary_reason: boundaryReason,
      confidence: 1,
      boundary_quote: null,
    }];
  }
  const chunkCount = Math.max(1, Math.ceil(transcriptLength / Math.max(1, maxSegmentChars)));
  const segments: SegmentFromLLM[] = [];
  for (let i = 0; i < chunkCount; i++) {
    const charStart = Math.floor((transcriptLength * i) / chunkCount);
    const charEnd = Math.floor((transcriptLength * (i + 1)) / chunkCount);
    segments.push({
      span_index: i,
      char_start: charStart,
      char_end: charEnd,
      boundary_reason: boundaryReason,
      confidence: 0.5,
      boundary_quote: null,
    });
  }
  return segments;
}

// ── enforceMaxSegmentChars (inlined copy) ───────────────────────────
function enforceMaxSegmentChars(
  inputSegments: SegmentFromLLM[],
  maxSegmentChars: number,
  warnings: string[],
): SegmentFromLLM[] {
  const rebuilt: SegmentFromLLM[] = [];
  for (const seg of inputSegments) {
    const segLen = Math.max(0, seg.char_end - seg.char_start);
    if (segLen <= maxSegmentChars || segLen === 0) {
      rebuilt.push(seg);
      continue;
    }
    const chunkCount = Math.ceil(segLen / maxSegmentChars);
    warnings.push(`segment_call_split_oversize_${seg.span_index}_into_${chunkCount}`);
    for (let i = 0; i < chunkCount; i++) {
      const charStart = seg.char_start + Math.floor((segLen * i) / chunkCount);
      const charEnd = seg.char_start + Math.floor((segLen * (i + 1)) / chunkCount);
      rebuilt.push({
        span_index: 0,
        char_start: charStart,
        char_end: charEnd,
        boundary_reason: `${seg.boundary_reason}_segment_call_split`,
        confidence: seg.confidence,
        boundary_quote: i === 0 ? seg.boundary_quote : null,
      });
    }
  }
  return rebuilt.map((seg, idx) => ({ ...seg, span_index: idx }));
}

// ── isReviewQueueCompatColumnMissing (inlined copy) ─────────────────
function isReviewQueueCompatColumnMissing(message: string): boolean {
  const text = String(message || "").toLowerCase();
  return text.includes("does not exist") &&
    (text.includes("module") || text.includes("dedupe_key") || text.includes("reason_codes"));
}

// ── isDuplicateKeyError (inlined copy) ──────────────────────────────
function isDuplicateKeyError(error: any): boolean {
  const code = String(error?.code || "");
  const message = String(error?.message || "").toLowerCase();
  const details = String(error?.details || "").toLowerCase();
  return code === "23505" || message.includes("duplicate key") || details.includes("already exists");
}

// ── shouldRunAuditor (inlined copy) ─────────────────────────────────
function shouldRunAuditor(decision: string, confidence: number): boolean {
  return decision === "assign" && confidence < 0.85;
}

// ═══════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════

Deno.test("sanitizeTranscriptForPipeline: removes control chars", () => {
  const result = sanitizeTranscriptForPipeline("hello\x00world\x01\x7F");
  assertEquals(result.text, "hello world  ");
  assertEquals(result.replaced, 3);
});

Deno.test("sanitizeTranscriptForPipeline: passes clean text through", () => {
  const result = sanitizeTranscriptForPipeline("normal text here");
  assertEquals(result.text, "normal text here");
  assertEquals(result.replaced, 0);
});

Deno.test("sanitizeTranscriptForPipeline: handles empty string", () => {
  const result = sanitizeTranscriptForPipeline("");
  assertEquals(result.text, "");
  assertEquals(result.replaced, 0);
});

Deno.test("normalizeReasonCodes: returns array of trimmed strings", () => {
  assertEquals(normalizeReasonCodes(["  foo ", "bar"]), ["foo", "bar"]);
});

Deno.test("normalizeReasonCodes: filters nulls and empty", () => {
  assertEquals(normalizeReasonCodes([null, "", undefined, "ok"]), ["ok"]);
});

Deno.test("normalizeReasonCodes: returns [] for non-array", () => {
  assertEquals(normalizeReasonCodes("not-array"), []);
  assertEquals(normalizeReasonCodes(null), []);
  assertEquals(normalizeReasonCodes(undefined), []);
});

Deno.test("deterministicSegmentsForLength: single segment for short text", () => {
  const segs = deterministicSegmentsForLength(500, 5000, "fallback");
  assertEquals(segs.length, 1);
  assertEquals(segs[0].char_start, 0);
  assertEquals(segs[0].char_end, 500);
  assertEquals(segs[0].boundary_reason, "fallback");
});

Deno.test("deterministicSegmentsForLength: splits long text into chunks", () => {
  const segs = deterministicSegmentsForLength(10000, 5000, "llm_fallback");
  assertEquals(segs.length, 2);
  assertEquals(segs[0].char_start, 0);
  assertEquals(segs[0].char_end, 5000);
  assertEquals(segs[1].char_start, 5000);
  assertEquals(segs[1].char_end, 10000);
});

Deno.test("deterministicSegmentsForLength: zero-length returns single empty segment", () => {
  const segs = deterministicSegmentsForLength(0, 5000, "empty");
  assertEquals(segs.length, 1);
  assertEquals(segs[0].char_end, 0);
  assertEquals(segs[0].confidence, 1);
});

Deno.test("deterministicSegmentsForLength: contiguous coverage", () => {
  const segs = deterministicSegmentsForLength(15000, 5000, "test");
  assertEquals(segs.length, 3);
  assertEquals(segs[0].char_start, 0);
  for (let i = 1; i < segs.length; i++) {
    assertEquals(segs[i].char_start, segs[i - 1].char_end);
  }
  assertEquals(segs[segs.length - 1].char_end, 15000);
});

Deno.test("enforceMaxSegmentChars: passes small segments through", () => {
  const warnings: string[] = [];
  const input: SegmentFromLLM[] = [
    { span_index: 0, char_start: 0, char_end: 1000, boundary_reason: "topic", confidence: 0.9, boundary_quote: null },
  ];
  const result = enforceMaxSegmentChars(input, 5000, warnings);
  assertEquals(result.length, 1);
  assertEquals(warnings.length, 0);
});

Deno.test("enforceMaxSegmentChars: splits oversized segment", () => {
  const warnings: string[] = [];
  const input: SegmentFromLLM[] = [
    { span_index: 0, char_start: 0, char_end: 12000, boundary_reason: "topic", confidence: 0.8, boundary_quote: "quote" },
  ];
  const result = enforceMaxSegmentChars(input, 5000, warnings);
  assertGreater(result.length, 1);
  assertEquals(warnings.length, 1);
  // First sub-chunk preserves boundary_quote
  assertEquals(result[0].boundary_quote, "quote");
  // Subsequent chunks get null
  assertEquals(result[1].boundary_quote, null);
  // span_index renumbered
  for (let i = 0; i < result.length; i++) {
    assertEquals(result[i].span_index, i);
  }
});

Deno.test("isReviewQueueCompatColumnMissing: detects module missing", () => {
  assertEquals(isReviewQueueCompatColumnMissing('column "module" does not exist'), true);
});

Deno.test("isReviewQueueCompatColumnMissing: detects dedupe_key missing", () => {
  assertEquals(isReviewQueueCompatColumnMissing('column "dedupe_key" does not exist'), true);
});

Deno.test("isReviewQueueCompatColumnMissing: ignores unrelated errors", () => {
  assertEquals(isReviewQueueCompatColumnMissing("connection refused"), false);
});

Deno.test("isDuplicateKeyError: PG code 23505", () => {
  assertEquals(isDuplicateKeyError({ code: "23505" }), true);
});

Deno.test("isDuplicateKeyError: message contains duplicate key", () => {
  assertEquals(isDuplicateKeyError({ message: "duplicate key value violates constraint" }), true);
});

Deno.test("isDuplicateKeyError: details contains already exists", () => {
  assertEquals(isDuplicateKeyError({ details: "Key (id)=(abc) already exists." }), true);
});

Deno.test("isDuplicateKeyError: returns false for generic errors", () => {
  assertEquals(isDuplicateKeyError({ code: "42000", message: "syntax error" }), false);
  assertEquals(isDuplicateKeyError(null), false);
});

Deno.test("shouldRunAuditor: triggers on low-confidence assign", () => {
  assertEquals(shouldRunAuditor("assign", 0.6), true);
  assertEquals(shouldRunAuditor("assign", 0.84), true);
});

Deno.test("shouldRunAuditor: skips high-confidence assign", () => {
  assertEquals(shouldRunAuditor("assign", 0.85), false);
  assertEquals(shouldRunAuditor("assign", 0.99), false);
});

Deno.test("shouldRunAuditor: skips non-assign decisions", () => {
  assertEquals(shouldRunAuditor("review", 0.3), false);
  assertEquals(shouldRunAuditor("none", 0.1), false);
});
