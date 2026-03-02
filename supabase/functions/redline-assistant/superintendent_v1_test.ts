import { assert, assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import {
  buildEvidenceItemsFromHighlights,
  classifyIntent,
  humanTimePhrase,
  sanitizeSuperintendentFragment,
} from "./superintendent_v1.ts";

Deno.test("classifyIntent routes common prompts", () => {
  assertEquals(classifyIntent("Tell me about permar"), "project_status");
  assertEquals(classifyIntent("Who's coming tomorrow?"), "schedule_who");
  assertEquals(classifyIntent("Did the inspector call back"), "yes_no_followup");
  assertEquals(classifyIntent("What do I owe Eddie"), "money_owed");
  assertEquals(classifyIntent("What's the holdup on Woodbery"), "bottleneck");
});

Deno.test("humanTimePhrase uses day parts + relative days", () => {
  const now = new Date("2026-03-02T15:00:00Z");

  assertEquals(
    humanTimePhrase({ event_at_utc: "2026-03-02T08:00:00Z", now_utc: now, client_utc_offset_minutes: 0 }),
    "this morning",
  );
  assertEquals(
    humanTimePhrase({ event_at_utc: "2026-03-02T14:00:00Z", now_utc: now, client_utc_offset_minutes: 0 }),
    "this afternoon",
  );
  assertEquals(
    humanTimePhrase({ event_at_utc: "2026-03-01T18:00:00Z", now_utc: now, client_utc_offset_minutes: 0 }),
    "yesterday evening",
  );
  assertEquals(
    humanTimePhrase({ event_at_utc: "2026-02-27T12:00:00Z", now_utc: now, client_utc_offset_minutes: 0 }),
    "3 days ago",
  );
  assertEquals(
    humanTimePhrase({ event_at_utc: "2026-02-15T12:00:00Z", now_utc: now, client_utc_offset_minutes: 0 }),
    "over a week ago",
  );
});

Deno.test("sanitizeSuperintendentFragment strips meta + timestamp-y text", () => {
  const raw = "On March 1, 2026, at 16:12 UTC, an outbound interaction happened.";
  const s = sanitizeSuperintendentFragment(raw);
  assert(!/UTC/i.test(s));
  assert(!/outbound/i.test(s));
  assert(!/interaction/i.test(s));
  assert(!/2026-03-01/.test(s));
  assert(!/March\s+1/i.test(s));
});

Deno.test("buildEvidenceItemsFromHighlights sorts, clamps, and sanitizes", () => {
  const now = new Date("2026-03-02T15:00:00Z");
  const items = buildEvidenceItemsFromHighlights({
    now_utc: now,
    client_utc_offset_minutes: 0,
    highlights: [
      {
        event_at_utc: "2026-03-01T18:00:00Z",
        channel: "sms",
        contact_name: "Jorge",
        summary_text: "On March 1, 2026, at 16:12 UTC, outbound message confirmed a conversation.",
      },
      {
        event_at_utc: "2026-03-02T10:00:00Z",
        channel: "call",
        contact_name: "Eddie",
        summary_text: "Need invoice details for check. ".repeat(20),
      },
      {
        event_at_utc: "2026-02-28T09:00:00Z",
        channel: "sms",
        contact_name: "Marco",
        summary_text: "Ok",
      },
      {
        event_at_utc: "2026-02-27T09:00:00Z",
        channel: "sms",
        contact_name: "Someone",
        summary_text: "Should be dropped (max_items=3).",
      },
    ],
  });

  assertEquals(items.length, 3);
  assertEquals(items[0].who, "Eddie");
  assertEquals(items[0].channel, "call");
  assert(items[0].excerpt.length <= 140);
  assert(items[0].excerpt.endsWith("…"), "Expected long excerpt to clamp with ellipsis");

  // Sanitization: no meta words/timestamps should survive.
  assert(!/UTC/i.test(items[1].excerpt));
  assert(!/outbound/i.test(items[1].excerpt));
  assert(!/interaction/i.test(items[1].excerpt));
  assert(!/\b2026-03-01\b/.test(items[1].excerpt));
});

