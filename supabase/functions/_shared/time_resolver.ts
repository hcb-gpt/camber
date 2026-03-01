export type TimeResolutionConfidence = "HIGH" | "MEDIUM" | "TENTATIVE" | "LOW";

export interface TimeResolution {
  start_at_utc: string | null;
  end_at_utc: string | null;
  due_at_utc: string | null;
  confidence: TimeResolutionConfidence;
  needs_review: boolean;
  reason_code: string;
  evidence_quote: string | null;
  timezone: string;
}

export interface ResolveTimeOptions {
  timezone?: string | null;
  project_timezone?: string | null;
  user_timezone?: string | null;
}

type LocalDateParts = {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
};

const DEFAULT_USER_TZ = "America/New_York";
const WEEKDAYS = [
  "sunday",
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
  "saturday",
] as const;

const TZ_ALIASES: Record<string, string> = {
  ET: "America/New_York",
  EST: "America/New_York",
  EDT: "America/New_York",
  CT: "America/Chicago",
  CST: "America/Chicago",
  CDT: "America/Chicago",
  MT: "America/Denver",
  MST: "America/Denver",
  MDT: "America/Denver",
  PT: "America/Los_Angeles",
  PST: "America/Los_Angeles",
  PDT: "America/Los_Angeles",
  UTC: "UTC",
  GMT: "UTC",
};

const WORD_NUMBERS: Record<string, number> = {
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
};

function normalizeText(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function toLocalParts(date: Date, timezone: string): LocalDateParts {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const read = (type: string) => Number(parts.find((p) => p.type === type)?.value || 0);
  return {
    year: read("year"),
    month: read("month"),
    day: read("day"),
    hour: read("hour"),
    minute: read("minute"),
  };
}

function localPartsToEpochMinutes(parts: LocalDateParts): number {
  return Math.floor(
    Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute) / 60_000,
  );
}

function zonedLocalToUtcIso(parts: LocalDateParts, timezone: string): string {
  let guessMs = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, 0);
  for (let i = 0; i < 4; i++) {
    const observed = toLocalParts(new Date(guessMs), timezone);
    const deltaMinutes = localPartsToEpochMinutes(parts) - localPartsToEpochMinutes(observed);
    if (deltaMinutes === 0) break;
    guessMs += deltaMinutes * 60_000;
  }
  return new Date(guessMs).toISOString();
}

function plusDays(date: Date, days: number): Date {
  const next = new Date(date.getTime());
  next.setUTCDate(next.getUTCDate() + days);
  return next;
}

function weekdayIndex(name: string): number {
  return WEEKDAYS.indexOf(name as (typeof WEEKDAYS)[number]);
}

function localWeekday(parts: LocalDateParts): number {
  return new Date(Date.UTC(parts.year, parts.month - 1, parts.day)).getUTCDay();
}

function resolveTimezone(timeHint: string, options: ResolveTimeOptions): string {
  const explicit = detectExplicitTimezone(timeHint);
  if (explicit) return explicit;
  if (options.project_timezone) return options.project_timezone;
  if (options.timezone) return options.timezone;
  return options.user_timezone || DEFAULT_USER_TZ;
}

const IANA_PREFIXES = new Set([
  "Africa",
  "America",
  "Antarctica",
  "Arctic",
  "Asia",
  "Atlantic",
  "Australia",
  "Europe",
  "Indian",
  "Pacific",
  "Etc",
  "US",
]);

function detectExplicitTimezone(timeHint: string): string | null {
  const normalized = ` ${timeHint.toUpperCase()} `;
  for (const [abbr, zone] of Object.entries(TZ_ALIASES)) {
    if (normalized.includes(` ${abbr} `)) return zone;
  }
  const iana = timeHint.match(/\b[A-Za-z_]+\/[A-Za-z_]+(?:\/[A-Za-z_]+)?\b/);
  if (iana) {
    const prefix = iana[0].split("/")[0];
    if (IANA_PREFIXES.has(prefix)) return iana[0];
  }
  return null;
}

function extractWeekday(timeHintLower: string): string | null {
  for (const day of WEEKDAYS) {
    if (new RegExp(`\\b${day}\\b`).test(timeHintLower)) return day;
  }
  return null;
}

function nextOccurrence(anchor: LocalDateParts, weekday: number): LocalDateParts {
  const anchorDate = new Date(Date.UTC(anchor.year, anchor.month - 1, anchor.day));
  let cursor = plusDays(anchorDate, 1);
  for (let i = 0; i < 14; i++) {
    if (cursor.getUTCDay() === weekday) {
      return {
        year: cursor.getUTCFullYear(),
        month: cursor.getUTCMonth() + 1,
        day: cursor.getUTCDate(),
        hour: anchor.hour,
        minute: anchor.minute,
      };
    }
    cursor = plusDays(cursor, 1);
  }
  return { ...anchor };
}

function nextDayOfMonth(anchor: LocalDateParts, dayOfMonth: number): LocalDateParts {
  const anchorDate = new Date(Date.UTC(anchor.year, anchor.month - 1, anchor.day));
  for (let i = 0; i < 370; i++) {
    const cursor = plusDays(anchorDate, i);
    if (cursor.getUTCDate() === dayOfMonth && i > 0) {
      return {
        year: cursor.getUTCFullYear(),
        month: cursor.getUTCMonth() + 1,
        day: cursor.getUTCDate(),
        hour: anchor.hour,
        minute: anchor.minute,
      };
    }
  }
  return { ...anchor };
}

function inferDurationMinutes(timeHintLower: string): number {
  if (/\b(check-?in|check in)\b/.test(timeHintLower)) return 15;
  if (/\b(meeting|walkthrough|site visit|onsite|on-site)\b/.test(timeHintLower)) return 60;
  if (/\b(call|phone)\b/.test(timeHintLower)) return 30;
  return 30;
}

function parseWeeksOffset(text: string): number | null {
  const numeric = text.match(/\bin\s+(\d+)\s+weeks?\b/);
  if (numeric) return Number(numeric[1]) * 7;
  const written = text.match(/\bin\s+(one|two|three|four|five|six)\s+weeks?\b/);
  if (written) return (WORD_NUMBERS[written[1]] || 0) * 7;
  return null;
}

type ParsedTime = {
  hour: number;
  minute: number;
  tentative: boolean;
  evidence: string;
};

function parseExplicitTime(text: string): ParsedTime | null {
  const patterns: RegExp[] = [
    /\b(around|about)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/i,
    /\b(\d{1,2})\s*ish\b/i,
    /\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/i,
    /\b(\d{1,2})(?::(\d{2}))\s*(am|pm)?\b/i,
    /\b(\d{1,2})\s*(am|pm)\b/i,
  ];

  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (!match) continue;

    let hourRaw = 0;
    let minuteRaw = 0;
    let suffix: string | undefined;
    if (pattern.source.includes("around|about")) {
      hourRaw = Number(match[2]);
      minuteRaw = Number(match[3] || 0);
      suffix = match[4]?.toLowerCase();
    } else if (pattern.source.includes("ish")) {
      hourRaw = Number(match[1]);
      minuteRaw = 0;
      suffix = undefined;
    } else if (pattern.source.startsWith("\\bat")) {
      hourRaw = Number(match[1]);
      minuteRaw = Number(match[2] || 0);
      suffix = match[3]?.toLowerCase();
    } else if (pattern.source.includes("(?::")) {
      hourRaw = Number(match[1]);
      minuteRaw = Number(match[2] || 0);
      suffix = match[3]?.toLowerCase();
    } else {
      hourRaw = Number(match[1]);
      minuteRaw = 0;
      suffix = match[2]?.toLowerCase();
    }

    if (hourRaw > 23 || minuteRaw > 59) continue;
    let hour = hourRaw;
    if (suffix === "pm" && hour < 12) hour += 12;
    if (suffix === "am" && hour === 12) hour = 0;
    if (!suffix && hourRaw <= 12 && /\b(pm|afternoon|evening|tonight)\b/.test(text)) {
      hour = hourRaw === 12 ? 12 : hourRaw + 12;
    }
    if (!suffix && hourRaw >= 1 && hourRaw <= 7 && !/\b(am|morning)\b/.test(text)) {
      hour = hourRaw + 12;
    }
    const tentative = /\b(around|about)\b/.test(match[0].toLowerCase()) || /ish\b/i.test(match[0]);
    return { hour, minute: minuteRaw, tentative, evidence: match[0] };
  }

  if (/\bend of day\b/i.test(text)) return { hour: 17, minute: 0, tentative: false, evidence: "end of day" };
  if (/\bend of week\b/i.test(text)) return { hour: 17, minute: 0, tentative: false, evidence: "end of week" };
  if (/\bthis morning\b|\bmorning\b/i.test(text)) return { hour: 9, minute: 0, tentative: false, evidence: "morning" };
  if (/\bthis afternoon\b|\bafternoon\b/i.test(text)) {
    return { hour: 13, minute: 0, tentative: false, evidence: "afternoon" };
  }
  if (/\blunch\b/i.test(text)) return { hour: 12, minute: 0, tentative: false, evidence: "lunch" };
  return null;
}

function buildReviewResult(
  timezone: string,
  reason: string,
  evidence: string | null,
): TimeResolution {
  return {
    start_at_utc: null,
    end_at_utc: null,
    due_at_utc: null,
    confidence: "LOW",
    needs_review: true,
    reason_code: reason,
    evidence_quote: evidence,
    timezone,
  };
}

export function resolveTime(
  timeHint: string,
  anchorTs: string | Date,
  options: ResolveTimeOptions = {},
): TimeResolution {
  const normalizedHint = normalizeText(timeHint);
  if (!normalizedHint) {
    return buildReviewResult(resolveTimezone("", options), "empty_hint", null);
  }

  const timezone = resolveTimezone(normalizedHint, options);
  const anchorDate = typeof anchorTs === "string" ? new Date(anchorTs) : anchorTs;
  if (Number.isNaN(anchorDate.getTime())) {
    return buildReviewResult(timezone, "invalid_anchor_ts", normalizedHint);
  }

  const hintLower = normalizedHint.toLowerCase();
  const anchorLocal = toLocalParts(anchorDate, timezone);
  let targetDate = {
    year: anchorLocal.year,
    month: anchorLocal.month,
    day: anchorLocal.day,
  };
  let hasExplicitDate = false;

  const weekdayName = extractWeekday(hintLower);
  const dayOfMonthMatch = hintLower.match(/\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\b/);
  if (weekdayName && dayOfMonthMatch) {
    const dayNum = Number(dayOfMonthMatch[1]);
    if (dayNum >= 1 && dayNum <= 31) {
      const candidate = nextDayOfMonth(anchorLocal, dayNum);
      const actualWeekday = WEEKDAYS[localWeekday(candidate)];
      if (actualWeekday !== weekdayName) {
        return buildReviewResult(timezone, "day_date_mismatch", `${weekdayName} ${dayOfMonthMatch[0]}`);
      }
      targetDate = { year: candidate.year, month: candidate.month, day: candidate.day };
      hasExplicitDate = true;
    }
  }

  if (!hasExplicitDate) {
    const weeksOffset = parseWeeksOffset(hintLower);
    if (weeksOffset !== null) {
      const day = plusDays(new Date(Date.UTC(anchorLocal.year, anchorLocal.month - 1, anchorLocal.day)), weeksOffset);
      targetDate = { year: day.getUTCFullYear(), month: day.getUTCMonth() + 1, day: day.getUTCDate() };
      hasExplicitDate = true;
    } else if (/\btomorrow\b/.test(hintLower)) {
      const day = plusDays(new Date(Date.UTC(anchorLocal.year, anchorLocal.month - 1, anchorLocal.day)), 1);
      targetDate = { year: day.getUTCFullYear(), month: day.getUTCMonth() + 1, day: day.getUTCDate() };
      hasExplicitDate = true;
    } else if (/\bend of week\b/.test(hintLower)) {
      const friday = nextOccurrence(anchorLocal, weekdayIndex("friday"));
      targetDate = { year: friday.year, month: friday.month, day: friday.day };
      hasExplicitDate = true;
    } else if (/\bnext\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/.test(hintLower)) {
      const nextDay = hintLower.match(
        /\bnext\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/,
      )![1];
      const resolved = nextOccurrence(anchorLocal, weekdayIndex(nextDay));
      targetDate = { year: resolved.year, month: resolved.month, day: resolved.day };
      hasExplicitDate = true;
    } else if (weekdayName) {
      const resolved = nextOccurrence(anchorLocal, weekdayIndex(weekdayName));
      targetDate = { year: resolved.year, month: resolved.month, day: resolved.day };
      hasExplicitDate = true;
    }
  }

  const parsedTime = parseExplicitTime(hintLower);
  const durationMinutes = parsedTime?.tentative ? 30 : inferDurationMinutes(hintLower);

  let hour = parsedTime?.hour;
  let minute = parsedTime?.minute || 0;
  let confidence: TimeResolutionConfidence = parsedTime?.tentative ? "TENTATIVE" : "HIGH";
  let needsReview = false;
  let reasonCode = parsedTime?.tentative ? "window_language" : "resolved";
  const evidence = parsedTime?.evidence || normalizedHint;

  if (hour == null) {
    if (hasExplicitDate) {
      hour = 9;
      minute = 0;
      confidence = "LOW";
      needsReview = true;
      reasonCode = "time_missing_assumed_default";
    } else {
      return buildReviewResult(timezone, "unparseable_time_hint", normalizedHint);
    }
  }

  if (!hasExplicitDate) {
    const anchorMins = anchorLocal.hour * 60 + anchorLocal.minute;
    const targetMins = hour * 60 + minute;
    if (targetMins <= anchorMins) {
      const day = plusDays(new Date(Date.UTC(anchorLocal.year, anchorLocal.month - 1, anchorLocal.day)), 1);
      targetDate = { year: day.getUTCFullYear(), month: day.getUTCMonth() + 1, day: day.getUTCDate() };
    }
  }

  const startLocal: LocalDateParts = {
    year: targetDate.year,
    month: targetDate.month,
    day: targetDate.day,
    hour,
    minute,
  };
  const endDate = new Date(zonedLocalToUtcIso(startLocal, timezone));
  endDate.setUTCMinutes(endDate.getUTCMinutes() + durationMinutes);
  const startIso = zonedLocalToUtcIso(startLocal, timezone);
  const endIso = endDate.toISOString();

  return {
    start_at_utc: startIso,
    end_at_utc: endIso,
    due_at_utc: startIso,
    confidence,
    needs_review: needsReview,
    reason_code: reasonCode,
    evidence_quote: evidence,
    timezone,
  };
}
