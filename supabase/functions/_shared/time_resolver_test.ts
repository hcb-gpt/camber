import { assert, assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import { resolveTime } from "./time_resolver.ts";

const ANCHOR = "2026-03-01T15:00:00Z"; // Sunday 10:00 America/New_York

function asLocalStamp(iso: string | null, timezone: string): string | null {
  if (!iso) return null;
  const date = new Date(iso);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const get = (type: string) => parts.find((p) => p.type === type)?.value || "00";
  return `${get("year")}-${get("month")}-${get("day")} ${get("hour")}:${get("minute")}`;
}

Deno.test("resolveTime handles 30+ core scheduler phrases deterministically", () => {
  const cases: Array<{
    hint: string;
    timezone?: string;
    project_timezone?: string;
    expectedTz: string;
    expectedLocal: string;
    expectedConfidence?: string;
    expectedReview?: boolean;
  }> = [
    { hint: "tomorrow at 2", expectedTz: "America/New_York", expectedLocal: "2026-03-02 14:00" },
    { hint: "tomorrow 2pm", expectedTz: "America/New_York", expectedLocal: "2026-03-02 14:00" },
    {
      hint: "tomorrow around 2",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-02 14:00",
      expectedConfidence: "TENTATIVE",
    },
    { hint: "tomorrow at 09:30", expectedTz: "America/New_York", expectedLocal: "2026-03-02 09:30" },
    { hint: "next tuesday at 11", expectedTz: "America/New_York", expectedLocal: "2026-03-03 11:00" },
    {
      hint: "next Thursday",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-05 09:00",
      expectedReview: true,
    },
    { hint: "this afternoon", expectedTz: "America/New_York", expectedLocal: "2026-03-01 13:00" },
    { hint: "morning", expectedTz: "America/New_York", expectedLocal: "2026-03-02 09:00" },
    { hint: "lunch", expectedTz: "America/New_York", expectedLocal: "2026-03-01 12:00" },
    { hint: "end of day", expectedTz: "America/New_York", expectedLocal: "2026-03-01 17:00" },
    {
      hint: "around 2",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-01 14:00",
      expectedConfidence: "TENTATIVE",
    },
    {
      hint: "10ish",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-02 10:00",
      expectedConfidence: "TENTATIVE",
    },
    { hint: "at 4pm", expectedTz: "America/New_York", expectedLocal: "2026-03-01 16:00" },
    { hint: "at 8am", expectedTz: "America/New_York", expectedLocal: "2026-03-02 08:00" },
    {
      hint: "in two weeks",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-15 09:00",
      expectedReview: true,
    },
    { hint: "in three weeks at 9", expectedTz: "America/New_York", expectedLocal: "2026-03-22 09:00" },
    { hint: "in one week at 15", expectedTz: "America/New_York", expectedLocal: "2026-03-08 15:00" },
    {
      hint: "Friday walkthrough at the site",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-06 09:00",
      expectedReview: true,
    },
    {
      hint: "check-in tomorrow",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-02 09:00",
      expectedReview: true,
    },
    { hint: "call tomorrow at 3pm", expectedTz: "America/New_York", expectedLocal: "2026-03-02 15:00" },
    { hint: "meeting tomorrow at 3pm", expectedTz: "America/New_York", expectedLocal: "2026-03-02 15:00" },
    { hint: "next monday at 10", expectedTz: "America/New_York", expectedLocal: "2026-03-02 10:00" },
    { hint: "tuesday", expectedTz: "America/New_York", expectedLocal: "2026-03-03 09:00", expectedReview: true },
    { hint: "today at 11", expectedTz: "America/New_York", expectedLocal: "2026-03-01 11:00" },
    { hint: "today at 8", expectedTz: "America/New_York", expectedLocal: "2026-03-02 08:00" },
    { hint: "tomorrow at 14:30", expectedTz: "America/New_York", expectedLocal: "2026-03-02 14:30" },
    {
      hint: "tomorrow at 2 ET",
      project_timezone: "America/Los_Angeles",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-02 14:00",
    },
    {
      hint: "tomorrow at 2 PT",
      project_timezone: "America/New_York",
      expectedTz: "America/Los_Angeles",
      expectedLocal: "2026-03-02 14:00",
    },
    { hint: "tomorrow at 2 UTC", expectedTz: "UTC", expectedLocal: "2026-03-02 14:00" },
    {
      hint: "tomorrow at 2 America/Chicago",
      expectedTz: "America/Chicago",
      expectedLocal: "2026-03-02 14:00",
    },
    { hint: "end of week", expectedTz: "America/New_York", expectedLocal: "2026-03-06 17:00" },
    { hint: "next saturday at 7pm", expectedTz: "America/New_York", expectedLocal: "2026-03-07 19:00" },
    {
      hint: "this afternoon check-in",
      expectedTz: "America/New_York",
      expectedLocal: "2026-03-01 13:00",
    },
  ];

  for (const testCase of cases) {
    const result = resolveTime(testCase.hint, ANCHOR, {
      project_timezone: testCase.project_timezone,
    });
    assert(result.start_at_utc, `start_at_utc missing for ${testCase.hint}`);
    assertEquals(result.timezone, testCase.expectedTz, `timezone mismatch for ${testCase.hint}`);
    assertEquals(asLocalStamp(result.start_at_utc, testCase.expectedTz), testCase.expectedLocal, testCase.hint);
    if (testCase.expectedConfidence) {
      assertEquals(result.confidence, testCase.expectedConfidence, testCase.hint);
    }
    if (typeof testCase.expectedReview === "boolean") {
      assertEquals(result.needs_review, testCase.expectedReview, testCase.hint);
    }
  }
});

Deno.test("resolveTime flags day/date mismatch and never auto-corrects", () => {
  const mismatch = resolveTime("Monday the 15th at 2", ANCHOR);
  assertEquals(mismatch.needs_review, true);
  assertEquals(mismatch.reason_code, "day_date_mismatch");
  assertEquals(mismatch.start_at_utc, null);
  assertEquals(mismatch.end_at_utc, null);
});

Deno.test("resolveTime preserves day/date pair when weekday matches", () => {
  const result = resolveTime("Sunday the 15th at 2", ANCHOR);
  assertEquals(result.needs_review, false);
  assertEquals(asLocalStamp(result.start_at_utc, "America/New_York"), "2026-03-15 14:00");
});

Deno.test("resolveTime applies default durations by activity type", () => {
  const meeting = resolveTime("tomorrow meeting at 3pm", ANCHOR);
  const call = resolveTime("tomorrow call at 3pm", ANCHOR);
  const checkIn = resolveTime("tomorrow check-in at 3pm", ANCHOR);

  assertEquals(
    new Date(meeting.end_at_utc!).getTime() - new Date(meeting.start_at_utc!).getTime(),
    60 * 60 * 1000,
  );
  assertEquals(
    new Date(call.end_at_utc!).getTime() - new Date(call.start_at_utc!).getTime(),
    30 * 60 * 1000,
  );
  assertEquals(
    new Date(checkIn.end_at_utc!).getTime() - new Date(checkIn.start_at_utc!).getTime(),
    15 * 60 * 1000,
  );
});
