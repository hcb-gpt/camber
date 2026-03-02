export type Intent =
  | "project_status"
  | "schedule_who"
  | "yes_no_followup"
  | "money_owed"
  | "bottleneck"
  | "unknown";

export function classifyIntent(message: string): Intent {
  const m = String(message || "").trim().toLowerCase();
  if (!m) return "unknown";

  // Yes/No follow-up queries tend to be short and should win precedence.
  if (
    /\b(did|has|have|didn't|hasn't|haven't)\b/.test(m) &&
    /\b(call back|called back|call|text|reply|respond|get back)\b/.test(m)
  ) {
    return "yes_no_followup";
  }

  // Scheduling / "who's coming tomorrow" style.
  if (
    /\bwho('?s| is)\b/.test(m) &&
    (/\b(tomorrow|today|this (morning|afternoon|evening)|next)\b/.test(m) ||
      /\b(coming|on site|there|at)\b/.test(m))
  ) {
    return "schedule_who";
  }

  // Money / payments.
  if (/\b(owe|owed|pay|paid|invoice|check)\b/.test(m) || /\$[0-9]/.test(m)) {
    return "money_owed";
  }

  // Bottleneck / hold-up.
  if (/\b(hold\s*up|holdup|stuck|bottleneck|what'?s the hold)\b/.test(m)) {
    return "bottleneck";
  }

  // Default: project status / quick update.
  if (/\b(tell me about|status|update|latest|what'?s going on)\b/.test(m)) {
    return "project_status";
  }

  return "unknown";
}

export type EvidenceItem = {
  who: string;
  when_human: string;
  excerpt: string;
  channel: string;
};

export function clampText(value: string, maxChars: number): string {
  const s = String(value ?? "").trim().replace(/\s+/g, " ");
  if (!s) return "";
  if (s.length <= maxChars) return s;
  return s.slice(0, Math.max(0, maxChars - 1)).trimEnd() + "…";
}

// Strip system-y meta and timestamp-y phrasing from evidence fragments so we don't
// accidentally leak it in deterministic fallback output.
export function sanitizeSuperintendentFragment(raw: string): string {
  let s = String(raw ?? "").replace(/\s+/g, " ").trim();
  if (!s) return "";

  // Remove common timestamp formats.
  s = s.replace(
    /\b\d{4}-\d{2}-\d{2}(?:[T\s]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?Z?)?\b/gi,
    "",
  );
  s = s.replace(
    /\b\d{1,2}\/\d{1,2}\/\d{2,4}\b/g,
    "",
  );
  s = s.replace(
    /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+\d{1,2}(?:,\s*\d{4})?\b/gi,
    "",
  );

  // Remove banned meta-words; replace "interaction" with something a person would say.
  s = s.replace(/\bthese interactions show\b/gi, "");
  s = s.replace(/\binteraction(s)?\b/gi, "update");
  s = s.replace(/\binbound\b/gi, "");
  s = s.replace(/\boutbound\b/gi, "");
  s = s.replace(/\bUTC\b/gi, "");

  // Clean up any punctuation left behind after stripping.
  s = s.replace(/\(\s*\)/g, "");
  s = s.replace(/^[,;:\-]+\s*/g, "");
  s = s.replace(/\s*[,;:\-]+$/g, "");
  s = s.replace(/\s+/g, " ").trim();
  return s;
}

type HumanTimeOpts = {
  event_at_utc: string | null;
  now_utc: Date;
  client_tz_name?: string | null;
  client_utc_offset_minutes?: number | null;
};

function dayPart(hour: number): "morning" | "afternoon" | "evening" | "night" {
  if (hour >= 5 && hour <= 11) return "morning";
  if (hour >= 12 && hour <= 16) return "afternoon";
  if (hour >= 17 && hour <= 21) return "evening";
  return "night";
}

function toLocalWithOffset(dUtc: Date, offsetMinutes: number): Date {
  return new Date(dUtc.getTime() + offsetMinutes * 60_000);
}

function localDayNumber(dLocal: Date): number {
  // Use UTC day number on the local-shifted Date object.
  return Math.floor(Date.UTC(dLocal.getUTCFullYear(), dLocal.getUTCMonth(), dLocal.getUTCDate()) / 86_400_000);
}

export function humanTimePhrase(opts: HumanTimeOpts): string {
  const eventAt = opts.event_at_utc ? new Date(opts.event_at_utc) : null;
  if (!eventAt || Number.isNaN(eventAt.getTime())) return "recently";

  const offset = typeof opts.client_utc_offset_minutes === "number" ? opts.client_utc_offset_minutes : 0;
  const nowLocal = toLocalWithOffset(opts.now_utc, offset);
  const eventLocal = toLocalWithOffset(eventAt, offset);

  const dayDiff = localDayNumber(nowLocal) - localDayNumber(eventLocal);
  const part = dayPart(eventLocal.getUTCHours());

  if (dayDiff === 0) return `this ${part}`;
  if (dayDiff === 1) return `yesterday ${part}`;
  if (dayDiff > 1 && dayDiff <= 6) return `${dayDiff} days ago`;
  return "over a week ago";
}

export function agePhrase(createdAtUtc: string | null, nowUtc: Date): string {
  const d = createdAtUtc ? new Date(createdAtUtc) : null;
  if (!d || Number.isNaN(d.getTime())) return "a while";
  const deltaMs = nowUtc.getTime() - d.getTime();
  const mins = Math.floor(deltaMs / 60_000);
  if (mins < 60) return `${Math.max(1, mins)} min`;
  const hours = Math.floor(mins / 60);
  if (hours < 48) return `${hours}h`;
  const days = Math.floor(hours / 24);
  return `${days}d`;
}

export function extractOpenLoopHintsFromEvidence(excerpts: string[]): string[] {
  const hints: string[] = [];
  const seen = new Set<string>();

  for (const raw of excerpts) {
    const s = String(raw || "").trim();
    if (!s) continue;
    const low = s.toLowerCase();

    // Heuristic: messages that contain a request or a pending dependency.
    const looksOpen =
      /\b(remind|please|need to|can you|could you|bring|call|text|follow up|waiting on|when can|let me know)\b/.test(
        low,
      );
    if (!looksOpen) continue;

    const c = clampText(s, 160);
    if (seen.has(c)) continue;
    seen.add(c);
    hints.push(c);
    if (hints.length >= 2) break;
  }

  return hints;
}

export type HighlightLike = {
  event_at_utc: string | null;
  channel: string | null;
  contact_name: string | null;
  summary_text: string | null;
};

export function buildEvidenceItemsFromHighlights(params: {
  highlights: HighlightLike[];
  now_utc: Date;
  client_tz_name?: string | null;
  client_utc_offset_minutes?: number | null;
  max_items?: number;
}): EvidenceItem[] {
  const maxItems = typeof params.max_items === "number" ? params.max_items : 3;
  const sorted = [...(params.highlights ?? [])];
  sorted.sort((a, b) => (b.event_at_utc ?? "").localeCompare(a.event_at_utc ?? ""));

  const items: EvidenceItem[] = [];
  for (const h of sorted) {
    const excerpt = clampText(
      sanitizeSuperintendentFragment(h.summary_text ?? ""),
      140,
    );
    if (!excerpt) continue;

    const who = clampText(
      sanitizeSuperintendentFragment(h.contact_name ?? ""),
      32,
    ) || "(unknown)";

    items.push({
      who,
      when_human: humanTimePhrase({
        event_at_utc: h.event_at_utc ?? null,
        now_utc: params.now_utc,
        client_tz_name: params.client_tz_name ?? null,
        client_utc_offset_minutes: params.client_utc_offset_minutes ?? null,
      }),
      excerpt,
      channel: h.channel ?? "unknown",
    });

    if (items.length >= maxItems) break;
  }
  return items;
}

export function buildDeterministicFallback(params: {
  projectName: string;
  projectStatusLine?: string | null;
  evidence: EvidenceItem[];
  openLoops: Array<{ description: string; age: string }> | null;
  openLoopHints: string[];
}): string {
  const lines: string[] = [];
  const projectName = clampText(sanitizeSuperintendentFragment(params.projectName), 64) || "Project";
  const statusLine = params.projectStatusLine
    ? clampText(sanitizeSuperintendentFragment(params.projectStatusLine), 64)
    : "";
  const title = statusLine ? `${projectName} — ${statusLine}.` : `${projectName}.`;
  lines.push(title);
  lines.push("");

  const latest = params.evidence[0];
  if (latest) {
    const who = latest.who && latest.who !== "(unknown)" ? latest.who : "Latest";
    lines.push(`Latest: ${who} — ${sanitizeSuperintendentFragment(latest.excerpt)} (${latest.when_human}).`);
    lines.push("");
  }

  const open = (params.openLoops && params.openLoops.length > 0) ? params.openLoops[0] : null;
  const hint = params.openLoopHints.length > 0 ? params.openLoopHints[0] : null;
  if (open) {
    lines.push(`Open loop: ${clampText(sanitizeSuperintendentFragment(open.description), 160)} (open ~${open.age}).`);
    lines.push("");
  } else if (hint) {
    lines.push(`Open loop: ${clampText(sanitizeSuperintendentFragment(hint), 160)}.`);
    lines.push("");
  }

  lines.push("Next: Want me to pull the last few messages for context, or check what’s still waiting on someone?");
  return lines.join("\n").trim() + "\n";
}
