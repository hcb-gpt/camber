/**
 * segment-llm guardrail unit tests
 *
 * Tests pure functions exported/inlined in segment-llm:
 * - normalizeSegmentationChannel: channel string → "call" | "sms_thread"
 * - quoteAroundIndex: extract snippet around a character offset
 */
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

// ── normalizeSegmentationChannel (inlined copy for testing) ──────────
type SegmentationChannel = "call" | "sms_thread";

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

// ── quoteAroundIndex (inlined copy for testing) ──────────────────────
const QUOTE_CONTEXT_CHARS = 40;

function quoteAroundIndex(transcript: string, index: number): string | null {
  const lo = Math.max(0, index - QUOTE_CONTEXT_CHARS);
  const hi = Math.min(transcript.length, index + QUOTE_CONTEXT_CHARS);
  const snippet = transcript.slice(lo, hi).replace(/\s+/g, " ").trim();
  return snippet.length > 0 ? snippet.slice(0, 50) : null;
}

// ── normalizeSegmentationChannel tests ───────────────────────────────

Deno.test("normalizeSegmentationChannel: explicit sms_thread channel", () => {
  assertEquals(normalizeSegmentationChannel("sms_thread", null), "sms_thread");
});

Deno.test("normalizeSegmentationChannel: sms alias", () => {
  assertEquals(normalizeSegmentationChannel("sms", null), "sms_thread");
});

Deno.test("normalizeSegmentationChannel: text alias", () => {
  assertEquals(normalizeSegmentationChannel("text", null), "sms_thread");
});

Deno.test("normalizeSegmentationChannel: text_message alias", () => {
  assertEquals(normalizeSegmentationChannel("text_message", null), "sms_thread");
});

Deno.test("normalizeSegmentationChannel: defaults to call", () => {
  assertEquals(normalizeSegmentationChannel("call", null), "call");
  assertEquals(normalizeSegmentationChannel(null, null), "call");
  assertEquals(normalizeSegmentationChannel(undefined, null), "call");
  assertEquals(normalizeSegmentationChannel("", null), "call");
});

Deno.test("normalizeSegmentationChannel: infers sms from sms_thread_ interaction_id", () => {
  assertEquals(normalizeSegmentationChannel(null, "sms_thread_12345"), "sms_thread");
});

Deno.test("normalizeSegmentationChannel: infers sms from beside_sms_ interaction_id", () => {
  assertEquals(normalizeSegmentationChannel(null, "beside_sms_67890"), "sms_thread");
});

Deno.test("normalizeSegmentationChannel: explicit channel overrides interaction_id inference", () => {
  assertEquals(normalizeSegmentationChannel("sms", "cll_12345"), "sms_thread");
});

Deno.test("normalizeSegmentationChannel: call interaction_id stays call", () => {
  assertEquals(normalizeSegmentationChannel(null, "cll_12345"), "call");
});

// ── quoteAroundIndex tests ───────────────────────────────────────────

Deno.test("quoteAroundIndex: extracts snippet around index", () => {
  const transcript = "Hello world, we need to discuss the Hurley project timeline.";
  const result = quoteAroundIndex(transcript, 30);
  assertEquals(typeof result, "string");
  assertEquals(result!.length <= 50, true);
});

Deno.test("quoteAroundIndex: returns null for empty transcript", () => {
  assertEquals(quoteAroundIndex("", 0), null);
});

Deno.test("quoteAroundIndex: clamps to start of transcript", () => {
  const transcript = "Short text.";
  const result = quoteAroundIndex(transcript, 0);
  assertEquals(typeof result, "string");
});

Deno.test("quoteAroundIndex: clamps to end of transcript", () => {
  const transcript = "Short text.";
  const result = quoteAroundIndex(transcript, transcript.length);
  assertEquals(typeof result, "string");
});

Deno.test("quoteAroundIndex: collapses whitespace", () => {
  const transcript = "word1\n\n\n   word2\t\tword3";
  const result = quoteAroundIndex(transcript, 5);
  assertEquals(result!.includes("\n"), false);
  assertEquals(result!.includes("\t"), false);
});
