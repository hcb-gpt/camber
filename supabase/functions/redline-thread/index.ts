import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "redline-thread_v2.7.0";
const OWNER_SMS_USER_IDS = ["+17066889158", "usr_4PCSTDQ8N161KAC4GG7AF9CR94"];
const OUTBOUND_INFERENCE_WINDOW_MS = 30 * 60 * 1000;
const OUTBOUND_INFERENCE_MAX_GAP_MS = 60 * 1000;
const IN_QUERY_BATCH_SIZE = 200;
const CONTACTS_CACHE_TTL_MS = 15_000;
const REDLINE_RESET_TZ = Deno.env.get("REDLINE_RESET_TZ") || "America/New_York";
const REDLINE_RESET_HOUR_LOCAL = Number(Deno.env.get("REDLINE_RESET_HOUR_LOCAL") || "1");

let contactsCache: { expiresAt: number; contacts: any[] } | null = null;

type ReviewQueueSource = "pipeline" | "redline";

type RedlineApiRoute =
  | { kind: "contacts" }
  | { kind: "thread"; contactId: string }
  | { kind: "spans"; contactId: string }
  | { kind: "verdict" }
  | { kind: "unknown"; path: string[] };

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}

function json(data: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(), ...extraHeaders },
  });
}

function buildServerTimingHeader(stages: Record<string, number>, totalMs: number): string {
  const entries: string[] = [];
  for (const [rawName, duration] of Object.entries(stages)) {
    if (!Number.isFinite(duration) || duration <= 0) continue;
    const name = rawName.toLowerCase().replace(/[^a-z0-9_-]/g, "_");
    entries.push(`${name};dur=${duration.toFixed(1)}`);
  }
  if (Number.isFinite(totalMs) && totalMs > 0) {
    entries.push(`total;dur=${totalMs.toFixed(1)}`);
  }
  return entries.join(", ");
}

function groupBy<T>(arr: T[], keyFn: (item: T) => string): Map<string, T[]> {
  const map = new Map<string, T[]>();
  for (const item of arr) {
    const key = keyFn(item);
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push(item);
  }
  return map;
}

async function batchIn<T>(
  values: string[],
  fetchChunk: (chunk: string[]) => Promise<{ data: T[] | null; error: any }>,
): Promise<{ data: T[]; error: any | null }> {
  const uniqueValues = [...new Set(values.filter((value) => value.length > 0))];
  if (uniqueValues.length === 0) {
    return { data: [], error: null };
  }

  const merged: T[] = [];
  for (let start = 0; start < uniqueValues.length; start += IN_QUERY_BATCH_SIZE) {
    const chunk = uniqueValues.slice(start, start + IN_QUERY_BATCH_SIZE);
    const { data, error } = await fetchChunk(chunk);
    if (error) {
      return { data: [], error };
    }
    if (data && data.length > 0) {
      merged.push(...data);
    }
  }

  return { data: merged, error: null };
}

// deduplicate spans by transcript content (>80% overlap = dupe)
function overlapRatio(a: string, b: string): number {
  if (!a || !b) return 0;
  const shorter = a.length <= b.length ? a : b;
  const longer = a.length <= b.length ? b : a;
  if (longer.includes(shorter)) return 1.0;
  const windowSize = Math.floor(shorter.length * 0.8);
  if (windowSize < 10) return 0;
  for (let i = 0; i <= shorter.length - windowSize; i++) {
    const chunk = shorter.slice(i, i + windowSize);
    if (longer.includes(chunk)) return windowSize / shorter.length;
  }
  return 0;
}

function deduplicateSpans(spans: any[]): any[] {
  const unique: any[] = [];
  for (const span of spans) {
    const seg = (span.transcript_segment || "").trim();
    if (!seg) {
      unique.push(span);
      continue;
    }
    const isDupe = unique.some((u) => {
      const uSeg = (u.transcript_segment || "").trim();
      return overlapRatio(seg, uSeg) > 0.8;
    });
    if (!isDupe) unique.push(span);
  }
  return unique;
}

// extract speaker names from transcript header lines
const SPEAKER_LINE_RE = /^(?:\[\d+:\d+\]\s*)?([A-Za-z][A-Za-z0-9_ +().-]*?):\s.+/;

function extractParticipants(transcript: string | null): string[] {
  if (!transcript) return [];
  const lines = transcript.split("\n").slice(0, 40);
  const seen = new Set<string>();
  for (const line of lines) {
    const m = line.trim().match(SPEAKER_LINE_RE);
    if (m) seen.add(m[1].trim());
    if (seen.size >= 6) break;
  }
  return [...seen];
}

function parseEventMs(value: unknown): number | null {
  const parsed = Date.parse(String(value || ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function zonedDateParts(date: Date, timeZone: string): { year: number; month: number; day: number; hour: number } {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hour12: false,
  });

  const parts = formatter.formatToParts(date);
  const value = (type: string): number =>
    Number(parts.find((part) => part.type === type)?.value || "0");

  return {
    year: value("year"),
    month: value("month"),
    day: value("day"),
    hour: value("hour"),
  };
}

function sameLocalDay(
  lhs: { year: number; month: number; day: number },
  rhs: { year: number; month: number; day: number },
): boolean {
  return lhs.year === rhs.year && lhs.month === rhs.month && lhs.day === rhs.day;
}

async function maybeAutoResetGradingCutoff(db: any): Promise<{ resetApplied: boolean; cutoff: string | null }> {
  const { data, error } = await db
    .from("redline_settings")
    .select("value_timestamptz")
    .eq("key", "grading_cutoff")
    .single();

  if (error) {
    console.warn("[redline-thread] grading cutoff fetch failed:", error.message);
    return { resetApplied: false, cutoff: null };
  }

  const now = new Date();
  const nowParts = zonedDateParts(now, REDLINE_RESET_TZ);
  if (!Number.isFinite(REDLINE_RESET_HOUR_LOCAL) || nowParts.hour < REDLINE_RESET_HOUR_LOCAL) {
    return { resetApplied: false, cutoff: data?.value_timestamptz || null };
  }

  const cutoffRaw = String(data?.value_timestamptz || "").trim();
  const cutoffDate = cutoffRaw ? new Date(cutoffRaw) : null;
  if (cutoffDate && !Number.isNaN(cutoffDate.getTime())) {
    const cutoffParts = zonedDateParts(cutoffDate, REDLINE_RESET_TZ);
    if (sameLocalDay(nowParts, cutoffParts)) {
      return { resetApplied: false, cutoff: cutoffRaw };
    }
  }

  const newCutoff = now.toISOString();
  const { data: updated, error: updateError } = await db
    .from("redline_settings")
    .update({
      value_timestamptz: newCutoff,
      updated_at: newCutoff,
    })
    .eq("key", "grading_cutoff")
    .select("value_timestamptz")
    .single();

  if (updateError) {
    console.warn("[redline-thread] grading cutoff auto-reset failed:", updateError.message);
    return { resetApplied: false, cutoff: cutoffRaw || null };
  }

  return { resetApplied: true, cutoff: updated?.value_timestamptz || newCutoff };
}

function isTruthy(value: string | null): boolean {
  if (!value) return false;
  const normalized = value.trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes" || normalized === "y";
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str);
}

function normalizeReviewQueueSource(
  raw: unknown,
  fallback: ReviewQueueSource = "redline",
): ReviewQueueSource {
  const normalized = String(raw || "").trim().toLowerCase();
  if (normalized === "redline") return "redline";
  if (normalized === "pipeline") return "pipeline";
  return fallback;
}

function isMissingReviewQueueSourceColumnError(message: string): boolean {
  return /column .*source.* does not exist/i.test(message);
}

async function tagReviewQueueSource(
  db: any,
  reviewQueueId: string,
  source: ReviewQueueSource,
  ctx: string,
): Promise<void> {
  const { error } = await db
    .from("review_queue")
    .update({ source })
    .eq("id", reviewQueueId);
  if (!error) return;
  if (isMissingReviewQueueSourceColumnError(error.message)) {
    console.warn(`[${ctx}] review_queue.source column missing; skipped source tag (${source})`);
    return;
  }
  console.warn(`[${ctx}] review_queue source tag warning: ${error.message}`);
}

function encodeOffsetCursor(offset: number): string {
  return btoa(JSON.stringify({ v: 1, offset: Math.max(0, Math.floor(offset)) }));
}

function decodeOffsetCursor(raw: string | null): number | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(atob(raw));
    const offset = Number(parsed?.offset);
    if (!Number.isFinite(offset) || offset < 0) return null;
    return Math.floor(offset);
  } catch {
    return null;
  }
}

function parseLimitOffset(
  url: URL,
  defaults: { limit: number; maxLimit: number; offset?: number },
): { limit: number; offset: number; cursor: string | null } {
  const rawLimit = parseInt(url.searchParams.get("limit") || `${defaults.limit}`, 10);
  const limit = Math.min(Math.max(Number.isNaN(rawLimit) ? defaults.limit : rawLimit, 1), defaults.maxLimit);

  const cursor = url.searchParams.get("cursor") || url.searchParams.get("after");
  const cursorOffset = decodeOffsetCursor(cursor);
  if (cursorOffset !== null) {
    return { limit, offset: cursorOffset, cursor };
  }

  const rawOffset = parseInt(url.searchParams.get("offset") || `${defaults.offset || 0}`, 10);
  const offset = Math.max(Number.isNaN(rawOffset) ? (defaults.offset || 0) : rawOffset, 0);
  return { limit, offset, cursor: null };
}

function parseRedlineApiRoute(url: URL): RedlineApiRoute | null {
  const parts = url.pathname
    .split("/")
    .map((part) => part.trim())
    .filter((part) => part.length > 0);

  const redlineIndex = parts.lastIndexOf("redline");
  if (redlineIndex === -1) return null;

  const tail = parts.slice(redlineIndex + 1);
  if (tail.length === 0) return { kind: "unknown", path: tail };
  if (tail[0] === "contacts" && tail.length === 1) return { kind: "contacts" };
  if (tail[0] === "thread" && tail.length >= 2) return { kind: "thread", contactId: decodeURIComponent(tail[1]) };
  if (tail[0] === "spans" && tail.length >= 2) return { kind: "spans", contactId: decodeURIComponent(tail[1]) };
  if (tail[0] === "verdict" && tail.length === 1) return { kind: "verdict" };
  return { kind: "unknown", path: tail };
}

function normalizePhoneDigits(value: unknown): string {
  const digits = String(value || "").replace(/\D/g, "");
  if (!digits) return "";
  return digits.length > 10 ? digits.slice(-10) : digits;
}

function buildPhoneVariants(value: unknown): string[] {
  const raw = String(value || "").trim();
  const digits = String(value || "").replace(/\D/g, "");
  const variants = new Set<string>();

  if (raw) variants.add(raw);
  if (digits) {
    variants.add(digits);
    if (digits.length === 10) {
      variants.add(`+1${digits}`);
      variants.add(`1${digits}`);
    } else if (digits.length === 11 && digits.startsWith("1")) {
      variants.add(digits.slice(1));
      variants.add(`+${digits}`);
    }
  }

  return [...variants].filter((variant) => variant.length > 0);
}

function deriveSmsInteractionKeys(row: any, fallbackPhone: string | null): string[] {
  const sentAtMs = parseEventMs(row?.sent_at);
  if (sentAtMs === null) return [];
  const sentAtSeconds = Math.floor(sentAtMs / 1000);
  const phoneDigits = normalizePhoneDigits(row?.contact_phone || fallbackPhone || "");
  const keys: string[] = [];
  if (phoneDigits) {
    keys.push(`sms_thread_${phoneDigits}_${sentAtSeconds}`);
  }
  keys.push(`sms_thread__${sentAtSeconds}`);
  return keys;
}

function deriveContactLastSummary(row: any): string | null {
  const snippet = String(row?.last_snippet || "").trim();
  if (snippet) return snippet;
  if (!row?.last_activity) return null;

  const interactionType = String(row?.last_interaction_type || "").toLowerCase();
  const direction = String(row?.last_direction || "").toLowerCase();

  if (interactionType === "call") {
    if (direction === "inbound") return "Incoming phone call";
    if (direction === "outbound") return "Outgoing phone call";
    return "Phone call";
  }

  if (interactionType === "sms") {
    if (direction === "inbound") return "Incoming text message";
    if (direction === "outbound") return "Outgoing text message";
    return "Text message";
  }

  return "Recent activity";
}

function isLikelyOwnerOutboundCandidate(row: any): boolean {
  if (String(row?.direction || "").toLowerCase() !== "outbound") {
    return false;
  }
  const senderUserId = String(row?.sender_user_id || "");
  const contactName = String(row?.contact_name || "").trim().toLowerCase();
  return OWNER_SMS_USER_IDS.includes(senderUserId) || contactName === "zack sittler";
}

function shouldAssignOutboundToInboundWindow(sentAt: unknown, inboundMs: number[]): boolean {
  const sentMs = parseEventMs(sentAt);
  if (sentMs === null || inboundMs.length === 0) {
    return false;
  }

  let minGap = Number.POSITIVE_INFINITY;
  for (const inbound of inboundMs) {
    const gap = Math.abs(sentMs - inbound);
    if (gap < minGap) minGap = gap;
    if (minGap <= OUTBOUND_INFERENCE_MAX_GAP_MS) {
      return true;
    }
  }
  return false;
}

// Infer outbound SMS that belong to the same conversation thread as the
// contact's inbound messages.  We scope by contact_phone so that outbound
// messages sent to *other* contacts within the same time window are excluded.
async function inferMissingOutboundSms(
  db: any,
  inboundMs: number[],
  existingSmsIds: Set<string>,
  contactPhoneVariants: string[],
): Promise<any[]> {
  if (inboundMs.length === 0) return [];
  if (contactPhoneVariants.length === 0) {
    console.warn("inferMissingOutboundSms: no contactPhone variants — skipping inference");
    return [];
  }

  const minInboundMs = Math.min(...inboundMs);
  const maxInboundMs = Math.max(...inboundMs);
  const lowerBound = new Date(minInboundMs - OUTBOUND_INFERENCE_WINDOW_MS).toISOString();
  const upperBound = new Date(maxInboundMs + OUTBOUND_INFERENCE_WINDOW_MS).toISOString();

  let outboundQuery = db
    .from("sms_messages")
    .select("id, sent_at, content, direction, contact_name, contact_phone, sender_user_id")
    .eq("direction", "outbound")
    .in("sender_user_id", OWNER_SMS_USER_IDS)
    .gte("sent_at", lowerBound)
    .lte("sent_at", upperBound)
    .order("sent_at", { ascending: false });

  if (contactPhoneVariants.length === 1) {
    outboundQuery = outboundQuery.eq("contact_phone", contactPhoneVariants[0]);
  } else {
    outboundQuery = outboundQuery.in("contact_phone", contactPhoneVariants);
  }

  const { data, error } = await outboundQuery;

  if (error) {
    console.warn("outbound inference query failed:", error.message);
    return [];
  }

  return (data || [])
    .filter((row: any) => !!row.id && !existingSmsIds.has(row.id))
    .filter((row: any) => isLikelyOwnerOutboundCandidate(row))
    .filter((row: any) => shouldAssignOutboundToInboundWindow(row.sent_at, inboundMs));
}

// reset grading clock endpoint
async function handleResetClock(db: any, t0: number): Promise<Response> {
  const { data, error } = await db
    .from("redline_settings")
    .update({ value_timestamptz: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq("key", "grading_cutoff")
    .select()
    .single();

  if (error) {
    return json({ ok: false, error_code: "reset_clock_failed", error: error.message }, 500);
  }

  return json({
    ok: true,
    grading_cutoff: data.value_timestamptz,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// get grading cutoff endpoint
async function handleGetCutoff(db: any, t0: number): Promise<Response> {
  const { data, error } = await db
    .from("redline_settings")
    .select("value_timestamptz")
    .eq("key", "grading_cutoff")
    .single();

  if (error) {
    return json({ ok: false, error_code: "get_cutoff_failed", error: error.message }, 500);
  }

  return json({
    ok: true,
    grading_cutoff: data?.value_timestamptz || null,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// contacts endpoint
async function handleContacts(db: any, url: URL, t0: number): Promise<Response> {
  const { resetApplied, cutoff } = await maybeAutoResetGradingCutoff(db);
  if (resetApplied) {
    contactsCache = null;
  }

  const forceRefresh = isTruthy(url.searchParams.get("refresh"));
  if (!forceRefresh && contactsCache && contactsCache.expiresAt > Date.now()) {
    return json({
      ok: true,
      contacts: contactsCache.contacts,
      cached: true,
      source: "memory_cache",
      grading_cutoff: cutoff,
      auto_reset_applied: resetApplied,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const selectColumns =
    "contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type";

  const contactsSource = "redline_contacts";
  const { data, error } = await db
    .from(contactsSource)
    .select(selectColumns)
    .order("last_activity", { ascending: false, nullsFirst: false });

  if (error) {
    return json({ ok: false, error_code: "contacts_query_failed", error: error.message }, 500);
  }

  const contacts = (data || [])
    .map((row: any) => ({
      contact_id: row.contact_id,
      name: row.contact_name,
      phone: row.contact_phone,
      call_count: Number(row.call_count ?? 0),
      sms_count: Number(row.sms_count ?? 0),
      claim_count: Number(row.claim_count ?? 0),
      ungraded_count: Number(row.ungraded_count ?? 0),
      last_activity: row.last_activity || null,
      last_summary: deriveContactLastSummary(row),
      last_direction: row.last_direction || null,
      last_interaction_type: row.last_interaction_type || null,
    }))
    .filter((row: any) => row.call_count > 0 || row.sms_count > 0)
    .sort((a: any, b: any) => {
      const aTime = Date.parse(a.last_activity || "") || 0;
      const bTime = Date.parse(b.last_activity || "") || 0;
      if (aTime !== bTime) return bTime - aTime;
      return String(a.name || "").localeCompare(String(b.name || ""));
    });

  contactsCache = {
    expiresAt: Date.now() + CONTACTS_CACHE_TTL_MS,
    contacts,
  };

  return json({
    ok: true,
    contacts,
    cached: false,
    source: contactsSource,
    grading_cutoff: cutoff,
    auto_reset_applied: resetApplied,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// projects endpoint
async function handleProjects(db: any, t0: number): Promise<Response> {
  const { data, error } = await db
    .from("projects")
    .select("id, name, status, job_type")
    .eq("status", "active")
    .not("job_type", "is", null)
    .order("name", { ascending: true });

  if (error) {
    return json({ ok: false, error_code: "projects_query_failed", error: error.message }, 500);
  }

  return json({
    ok: true,
    projects: data || [],
    count: (data || []).length,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// top candidates endpoint
async function handleTopCandidates(db: any, url: URL, t0: number): Promise<Response> {
  const rawLimit = parseInt(url.searchParams.get("limit") || "50", 10);
  const limit = Math.min(Math.max(Number.isNaN(rawLimit) ? 50 : rawLimit, 1), 500);
  const shouldRefresh = isTruthy(url.searchParams.get("refresh"));

  let refreshedAt: string | null = null;
  if (shouldRefresh) {
    const { data: refreshData, error: refreshErr } = await db.rpc("refresh_redline_top_candidates");
    if (refreshErr) {
      return json({ ok: false, error_code: "top_candidates_refresh_failed", error: refreshErr.message }, 500);
    }
    refreshedAt = refreshData ? String(refreshData) : new Date().toISOString();
  }

  const { data, error } = await db
    .from("redline_top_candidates")
    .select(
      "contact_id, contact_name, contact_phone, pending_review_count, total_interaction_count, last_activity, oldest_pending_review",
    )
    .order("pending_review_count", { ascending: false })
    .order("oldest_pending_review", { ascending: true, nullsFirst: false })
    .order("last_activity", { ascending: false, nullsFirst: false })
    .range(0, limit - 1);

  if (error) {
    return json({ ok: false, error_code: "top_candidates_query_failed", error: error.message }, 500);
  }

  const candidates = (data || []).map((row: any) => ({
    contact_id: row.contact_id,
    contact_name: row.contact_name,
    contact_phone: row.contact_phone,
    pending_review_count: Number(row.pending_review_count ?? 0),
    total_interaction_count: Number(row.total_interaction_count ?? 0),
    last_activity: row.last_activity || null,
    oldest_pending_review: row.oldest_pending_review || null,
  }));

  return json({
    ok: true,
    candidates,
    count: candidates.length,
    refreshed: shouldRefresh,
    refreshed_at: refreshedAt,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// sanity endpoint
async function handleSanity(db: any, t0: number): Promise<Response> {
  const startOfUtcDay = new Date();
  startOfUtcDay.setUTCHours(0, 0, 0, 0);

  const [
    latestCallsRes,
    latestSmsRes,
    latestContactsRes,
    pendingCountRes,
    resolvedTodayRes,
    dbNowProbeRes,
  ] = await Promise.all([
    db
      .from("interactions")
      .select("id, interaction_id, contact_name, event_at_utc, channel")
      .order("event_at_utc", { ascending: false, nullsFirst: false })
      .limit(10),
    db
      .from("sms_messages")
      .select("id, contact_phone, contact_name, direction, sent_at")
      .order("sent_at", { ascending: false, nullsFirst: false })
      .limit(10),
    db
      .from("redline_contacts")
      .select("contact_id, contact_name, last_activity, last_interaction_type")
      .order("last_activity", { ascending: false, nullsFirst: false })
      .limit(5),
    db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending"),
    db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "resolved")
      .gte("resolved_at", startOfUtcDay.toISOString()),
    db
      .rpc("get_hard_drop_sla_monitor", {
        p_sla_window_hours: 1,
        p_hard_drop_deadline_hours: 24,
        p_top_n_clusters: 1,
      }),
  ]);

  if (latestCallsRes.error) {
    return json({
      ok: false,
      error_code: "sanity_latest_calls_failed",
      error: latestCallsRes.error.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
  if (latestSmsRes.error) {
    return json({
      ok: false,
      error_code: "sanity_latest_sms_failed",
      error: latestSmsRes.error.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
  if (latestContactsRes.error) {
    return json({
      ok: false,
      error_code: "sanity_latest_contacts_failed",
      error: latestContactsRes.error.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
  if (pendingCountRes.error) {
    return json({
      ok: false,
      error_code: "sanity_pending_count_failed",
      error: pendingCountRes.error.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
  if (resolvedTodayRes.error) {
    return json({
      ok: false,
      error_code: "sanity_resolved_today_count_failed",
      error: resolvedTodayRes.error.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
  if (dbNowProbeRes.error) {
    return json({
      ok: false,
      error_code: "sanity_db_now_probe_failed",
      error: dbNowProbeRes.error.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }

  const dbNow = ((dbNowProbeRes.data || [])[0] as any)?.generated_at_utc || null;

  return json({
    ok: true,
    latest_calls: latestCallsRes.data || [],
    latest_sms: latestSmsRes.data || [],
    latest_contacts: latestContactsRes.data || [],
    review_queue_stats: {
      pending: pendingCountRes.count ?? 0,
      resolved_today: resolvedTodayRes.count ?? 0,
    },
    function_version: FUNCTION_VERSION,
    db_now: dbNow,
    ms: Date.now() - t0,
  });
}

// thread endpoint
async function handleThread(
  db: any,
  contactId: string,
  limit: number,
  offset: number,
  t0: number,
): Promise<Response> {
  const stageMs: Record<string, number> = {};
  const timeDb = async (stage: string, fn: () => Promise<any>): Promise<any> => {
    const start = performance.now();
    const result = await fn();
    stageMs[stage] = (stageMs[stage] || 0) + (performance.now() - start);
    return result;
  };
  const computeStart = performance.now();

  const { data: contact, error: contactErr } = await timeDb("db_contact", () =>
    db
      .from("contacts")
      .select("id, name, phone")
      .eq("id", contactId)
      .single()
  );

  if (contactErr || !contact) {
    return json({ ok: false, error_code: "contact_not_found", error: contactErr?.message || "not found" }, 404);
  }
  const contactPhoneVariants = buildPhoneVariants(contact.phone);

  const scanWindow = Math.min(Math.max(offset + limit + 20, 40), 120);
  const queryPageSize = 40;

  let allInteractions: any[] = [];
  let interactionsFrom = 0;
  let hasMoreInteractions = false;
  while (allInteractions.length < scanWindow) {
    const interactionsTo = interactionsFrom + queryPageSize - 1;
    const { data: page, error: intErr } = await timeDb("db_interactions", () =>
      db
        .from("interactions")
        .select("id, interaction_id, event_at_utc, human_summary, contact_name, is_shadow")
        .eq("contact_id", contactId)
        // Keep call-only scope while tolerating legacy call-like channel values.
        .or("channel.eq.call,channel.eq.phone,channel.is.null")
        .or("is_shadow.is.false,is_shadow.is.null")
        .not("interaction_id", "like", "cll_SHADOW_%")
        .not("event_at_utc", "is", null)
        .order("event_at_utc", { ascending: false })
        .range(interactionsFrom, interactionsTo)
    );

    if (intErr) {
      return json({ ok: false, error_code: "interactions_query_failed", error: intErr.message }, 500);
    }

    if (!page || page.length === 0) break;
    allInteractions = allInteractions.concat(page);
    if (page.length < queryPageSize) break;
    interactionsFrom += queryPageSize;
    if (allInteractions.length >= scanWindow) {
      hasMoreInteractions = true;
      break;
    }
  }
  if (allInteractions.length > scanWindow) {
    allInteractions = allInteractions.slice(0, scanWindow);
  }

  let inboundProbeQuery = db
    .from("sms_messages")
    .select("id")
    .eq("direction", "inbound")
    .limit(1);
  if (contactPhoneVariants.length === 1) {
    inboundProbeQuery = inboundProbeQuery.eq("contact_phone", contactPhoneVariants[0]);
  } else if (contactPhoneVariants.length > 1) {
    inboundProbeQuery = inboundProbeQuery.in("contact_phone", contactPhoneVariants);
  } else {
    inboundProbeQuery = inboundProbeQuery.eq("contact_phone", "__no_contact_phone_match__");
  }
  const { data: inboundProbe, error: inboundProbeErr } = await timeDb(
    "db_sms_inbound_probe",
    () => inboundProbeQuery
  );

  if (inboundProbeErr) {
    return json({ ok: false, error_code: "sms_inbound_probe_failed", error: inboundProbeErr.message }, 500);
  }

  const hasInboundSms = (inboundProbe || []).length > 0;
  let allSmsMessages: any[] = [];
  let hasMoreSms = false;

  if (hasInboundSms) {
    let smsFrom = 0;
    while (allSmsMessages.length < scanWindow) {
      const smsTo = smsFrom + queryPageSize - 1;
      let smsQuery = db
        .from("sms_messages")
        .select("id, sent_at, content, direction, contact_name, contact_phone, sender_user_id")
        .order("sent_at", { ascending: false })
        .range(smsFrom, smsTo);
      if (contactPhoneVariants.length === 1) {
        smsQuery = smsQuery.eq("contact_phone", contactPhoneVariants[0]);
      } else if (contactPhoneVariants.length > 1) {
        smsQuery = smsQuery.in("contact_phone", contactPhoneVariants);
      } else {
        smsQuery = smsQuery.eq("contact_phone", "__no_contact_phone_match__");
      }
      const { data: page, error: smsErr } = await timeDb("db_sms_messages", () => smsQuery);

      if (smsErr) {
        return json({ ok: false, error_code: "sms_query_failed", error: smsErr.message }, 500);
      }

      if (!page || page.length === 0) break;
      allSmsMessages = allSmsMessages.concat(page);
      if (page.length < queryPageSize) break;
      smsFrom += queryPageSize;
      if (allSmsMessages.length >= scanWindow) {
        hasMoreSms = true;
        break;
      }
    }
    if (allSmsMessages.length > scanWindow) {
      allSmsMessages = allSmsMessages.slice(0, scanWindow);
    }
  }

  const inboundSms = allSmsMessages.filter((s: any) => String(s.direction || "").toLowerCase() === "inbound");
  const outboundSms = allSmsMessages.filter((s: any) => String(s.direction || "").toLowerCase() === "outbound");
  const hasAnyInbound = inboundSms.length > 0;
  let smsMessages = hasAnyInbound ? allSmsMessages : [];

  if (hasAnyInbound && outboundSms.length === 0) {
    const inboundMs = inboundSms
      .map((s: any) => parseEventMs(s.sent_at))
      .filter((ms: number | null) => ms !== null) as number[];
    if (inboundMs.length > 0) {
      const inferredOutbound = await inferMissingOutboundSms(
        db,
        inboundMs,
        new Set(smsMessages.map((s: any) => s.id)),
        contactPhoneVariants,
      );
      if (inferredOutbound.length > 0) {
        smsMessages = smsMessages.concat(inferredOutbound);
        smsMessages.sort((a: any, b: any) => {
          const aTime = Date.parse(a.sent_at || "") || 0;
          const bTime = Date.parse(b.sent_at || "") || 0;
          if (aTime !== bTime) return bTime - aTime;
          return String(b.id).localeCompare(String(a.id));
        });
      }
    }
  }

  const timeline = [
    ...allInteractions.map((i: any) => ({
      kind: "call",
      key: i.interaction_id,
      event_at: i.event_at_utc,
    })),
    ...smsMessages
      .filter((s: any) => !!s.sent_at)
      .map((s: any) => ({
        kind: "sms",
        key: s.id,
        event_at: s.sent_at,
      })),
  ].sort((a: any, b: any) => {
    const aTime = Date.parse(a.event_at || "") || 0;
    const bTime = Date.parse(b.event_at || "") || 0;
    if (aTime !== bTime) return bTime - aTime;
    return String(b.key).localeCompare(String(a.key));
  });

  const pagedTimeline = timeline.slice(offset, offset + limit);
  const likelyMore = hasMoreInteractions || hasMoreSms;
  const totalCount = likelyMore
    ? Math.max(offset + pagedTimeline.length + 1, timeline.length)
    : offset + pagedTimeline.length;

  if (pagedTimeline.length === 0) {
    return json({
      ok: true,
      contact: { id: contact.id, name: contact.name, phone: contact.phone },
      thread: [],
      pagination: { limit, offset, total: totalCount },
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const pagedCallIds = new Set(
    pagedTimeline
      .filter((entry: any) => entry.kind === "call")
      .map((entry: any) => entry.key),
  );
  const pagedSmsIds = new Set(
    pagedTimeline
      .filter((entry: any) => entry.kind === "sms")
      .map((entry: any) => entry.key),
  );

  const interactions = allInteractions.filter((i: any) => pagedCallIds.has(i.interaction_id));
  const interactionIds = interactions.map((i: any) => i.interaction_id);
  const interactionAliasToCanonical = new Map<string, string>();
  for (const interaction of interactions) {
    if (interaction?.interaction_id) {
      interactionAliasToCanonical.set(String(interaction.interaction_id), String(interaction.interaction_id));
    }
    if (interaction?.id) {
      interactionAliasToCanonical.set(String(interaction.id), String(interaction.interaction_id));
    }
  }
  const pagedSmsMessages = smsMessages.filter((s: any) => pagedSmsIds.has(s.id));

  const pendingSmsReviewByInteractionId = new Map<string, any>();
  const pendingSmsReviewByMessageId = new Map<string, any>();
  const smsInteractionKeys = [
    ...new Set(
      pagedSmsMessages.flatMap((sms: any) => deriveSmsInteractionKeys(sms, contact.phone)),
    ),
  ];

  if (smsInteractionKeys.length > 0) {
    const { data: pendingSmsReviewRows, error: pendingSmsReviewErr } = await timeDb(
      "db_pending_sms_reviews",
      () =>
        db
          .from("review_queue")
          .select("id, interaction_id, created_at")
          .eq("status", "pending")
          .in("interaction_id", smsInteractionKeys)
          .order("created_at", { ascending: false })
    );

    if (pendingSmsReviewErr) {
      return json(
        { ok: false, error_code: "pending_sms_review_query_failed", error: pendingSmsReviewErr.message },
        500,
      );
    }

    for (const row of pendingSmsReviewRows || []) {
      const interactionId = String(row?.interaction_id || "");
      if (!interactionId) continue;
      if (!pendingSmsReviewByInteractionId.has(interactionId)) {
        pendingSmsReviewByInteractionId.set(interactionId, row);
      }
    }

    for (const sms of pagedSmsMessages) {
      const matchingReview = deriveSmsInteractionKeys(sms, contact.phone)
        .map((key) => pendingSmsReviewByInteractionId.get(key))
        .find((value) => !!value);
      if (matchingReview) {
        pendingSmsReviewByMessageId.set(String(sms.id), matchingReview);
      }
    }
  }

  let callsRaw: any[] = [];
  if (interactionIds.length > 0) {
    const { data, error } = await timeDb("db_calls_raw", () =>
      db
        .from("calls_raw")
        .select("interaction_id, direction, transcript")
        .in("interaction_id", interactionIds)
    );

    if (error) {
      return json({ ok: false, error_code: "calls_raw_query_failed", error: error.message }, 500);
    }
    callsRaw = data || [];
  }

  const directionMap = new Map((callsRaw || []).map((c: any) => [c.interaction_id, c.direction]));
  const transcriptMap = new Map((callsRaw || []).map((c: any) => [c.interaction_id, c.transcript]));

  let spans: any[] = [];
  if (interactionIds.length > 0) {
    const { data, error } = await timeDb("db_conversation_spans", () =>
      batchIn<any>(
        interactionIds,
        (chunk: string[]) =>
          db
            .from("conversation_spans")
            .select("id, interaction_id, span_index, transcript_segment, word_count")
            .in("interaction_id", chunk)
            .eq("is_superseded", false)
            .order("span_index", { ascending: true }),
      )
    );

    if (error) {
      return json({ ok: false, error_code: "spans_query_failed", error: error.message }, 500);
    }
    spans = (data || []).sort((a: any, b: any) => {
      const interactionCmp = String(a?.interaction_id || "").localeCompare(String(b?.interaction_id || ""));
      if (interactionCmp !== 0) return interactionCmp;
      return Number(a?.span_index || 0) - Number(b?.span_index || 0);
    });
  }

  const spansPerInteraction = groupBy(spans || [], (s: any) => s.interaction_id);
  const spanIds = (spans || [])
    .map((span: any) => String(span.id || ""))
    .filter((id: string) => id.length > 0);

  let spanAttributionRows: any[] = [];
  if (spanIds.length > 0) {
    const { data, error } = await timeDb("db_span_attributions", () =>
      batchIn<any>(
        spanIds,
        (chunk: string[]) =>
          db
            .from("span_attributions")
            .select("span_id, project_id, applied_project_id, confidence")
            .in("span_id", chunk),
      )
    );

    if (error) {
      return json({ ok: false, error_code: "span_attributions_query_failed", error: error.message }, 500);
    }
    spanAttributionRows = data || [];
  }

  const spanAttributionBySpanId = new Map<string, any>();
  for (const row of spanAttributionRows) {
    const spanId = String(row?.span_id || "");
    if (!spanId) continue;
    const existing = spanAttributionBySpanId.get(spanId);
    if (!existing) {
      spanAttributionBySpanId.set(spanId, row);
      continue;
    }

    const score = (candidate: any) => {
      const applied = candidate?.applied_project_id ? 1000 : 0;
      const confidence = Number(candidate?.confidence ?? 0);
      return applied + (Number.isFinite(confidence) ? Math.round(confidence * 100) : 0);
    };
    if (score(row) > score(existing)) {
      spanAttributionBySpanId.set(spanId, row);
    }
  }

  const spanProjectIds = [
    ...new Set(
      [...spanAttributionBySpanId.values()]
        .map((row: any) => String(row?.applied_project_id || row?.project_id || ""))
        .filter((value: string) => value.length > 0),
    ),
  ];

  const projectNameById = new Map<string, string>();
  if (spanProjectIds.length > 0) {
    const { data, error } = await timeDb("db_projects", () =>
      batchIn<any>(
        spanProjectIds,
        (chunk: string[]) =>
          db
            .from("projects")
            .select("id, name")
            .in("id", chunk),
      )
    );

    if (error) {
      return json({ ok: false, error_code: "projects_for_spans_query_failed", error: error.message }, 500);
    }

    for (const project of data || []) {
      const id = String(project?.id || "");
      const name = String(project?.name || "");
      if (!id || !name) continue;
      projectNameById.set(id, name);
    }
  }

  let pendingReviewRows: any[] = [];
  if (spanIds.length > 0) {
    const { data, error } = await timeDb("db_pending_span_reviews", () =>
      batchIn<any>(
        spanIds,
        (chunk: string[]) =>
          db
            .from("review_queue")
            .select("id, span_id, interaction_id, created_at")
            .eq("status", "pending")
            .in("span_id", chunk)
            .order("created_at", { ascending: false }),
      )
    );

    if (error) {
      return json({ ok: false, error_code: "pending_review_query_failed", error: error.message }, 500);
    }
    pendingReviewRows = (data || []).sort((a: any, b: any) => {
      const bTs = Date.parse(String(b?.created_at || "")) || 0;
      const aTs = Date.parse(String(a?.created_at || "")) || 0;
      if (bTs !== aTs) return bTs - aTs;
      return String(a?.id || "").localeCompare(String(b?.id || ""));
    });
  }

  const pendingReviewBySpanId = new Map<string, any>();
  for (const row of pendingReviewRows) {
    const spanId = String(row?.span_id || "");
    if (!spanId) continue;
    if (!pendingReviewBySpanId.has(spanId)) {
      pendingReviewBySpanId.set(spanId, row);
    }
  }

  const pendingCountByInteraction = new Map<string, number>();
  for (const row of pendingReviewRows) {
    const rawInteraction = String(row?.interaction_id || "");
    if (!rawInteraction) continue;
    const interactionKey = interactionAliasToCanonical.get(rawInteraction) || rawInteraction;
    pendingCountByInteraction.set(
      interactionKey,
      (pendingCountByInteraction.get(interactionKey) || 0) + 1,
    );
  }

  let callClaims: any[] = [];
  if (interactionIds.length > 0) {
    const claimCallKeys = [
      ...new Set(
        interactions.flatMap((interaction: any) => [
          interaction?.interaction_id ? String(interaction.interaction_id) : "",
          interaction?.id ? String(interaction.id) : "",
        ]).filter((value: string) => value.length > 0),
      ),
    ];
    const { data: claimData, error: claimsErr } = await timeDb("db_journal_claims", () =>
      batchIn<any>(
        claimCallKeys,
        (chunk: string[]) =>
          db
            .from("journal_claims")
            .select("id, call_id, source_span_id, claim_type, claim_text, speaker_label")
            .in("call_id", chunk),
      )
    );

    if (claimsErr) {
      return json({ ok: false, error_code: "claims_query_failed", error: claimsErr.message }, 500);
    }
    const dedupedClaims = new Map<string, any>();
    for (const claim of claimData || []) {
      if (claim?.id) {
        dedupedClaims.set(String(claim.id), claim);
      }
    }
    callClaims = [...dedupedClaims.values()];
  }

  const allClaimIds = callClaims.map((c: any) => c.id);
  const claimsPerCall = groupBy(
    callClaims,
    (claim: any) => interactionAliasToCanonical.get(String(claim.call_id)) || String(claim.call_id),
  );

  let grades: any[] = [];
  if (allClaimIds.length > 0) {
    const { data: gradeData, error: gradesErr } = await timeDb("db_claim_grades", () =>
      batchIn<any>(
        allClaimIds,
        (chunk: string[]) =>
          db
            .from("claim_grades")
            .select("claim_id, grade, correction_text, graded_by")
            .in("claim_id", chunk),
      )
    );

    if (gradesErr) {
      return json({ ok: false, error_code: "grades_query_failed", error: gradesErr.message }, 500);
    }
    grades = gradeData || [];
  }

  const gradeMap = new Map((grades || []).map((g: any) => [g.claim_id, g]));

  const callEntries = interactions.map((i: any) => {
    const rawTranscript: string | null = transcriptMap.get(i.interaction_id) || null;
    const rawSpans = spansPerInteraction.get(i.interaction_id) || [];
    const dedupedSpans = deduplicateSpans(rawSpans);
    const participants = extractParticipants(rawTranscript);
    let pendingSpanCount = 0;

    const interactionClaims = (claimsPerCall.get(i.interaction_id) || []).map((c: any) => {
      const g = gradeMap.get(c.id);
      return {
        claim_id: c.id,
        source_span_id: c.source_span_id || null,
        claim_type: c.claim_type,
        claim_text: c.claim_text,
        grade: g?.grade || null,
        correction_text: g?.correction_text || null,
        graded_by: g?.graded_by || null,
      };
    });
    const interactionClaimPayload = interactionClaims.map(({ source_span_id: _sourceSpanId, ...claim }) => claim);
    const claimsPerSpan = groupBy(
      interactionClaims.filter((claim: any) => !!claim.source_span_id),
      (claim: any) => String(claim.source_span_id),
    );
    const unscopedClaims = interactionClaims.filter((claim: any) => !claim.source_span_id);

    return {
      type: "call",
      interaction_id: i.interaction_id,
      event_at: i.event_at_utc,
      direction: directionMap.get(i.interaction_id) || null,
      summary: i.human_summary,
      contact_name: i.contact_name || contact.name,
      raw_transcript: rawTranscript,
      participants,
      spans: dedupedSpans.map((s: any, index: number) => {
        const pendingReview = pendingReviewBySpanId.get(String(s.id));
        const attribution = spanAttributionBySpanId.get(String(s.id));
        const projectId = String(
          attribution?.applied_project_id || attribution?.project_id || "",
        );
        const projectName = projectId ? projectNameById.get(projectId) || null : null;
        const confidenceValue = Number(attribution?.confidence);
        if (pendingReview) pendingSpanCount += 1;
        const scopedClaims = (claimsPerSpan.get(String(s.id)) || [])
          .map(({ source_span_id: _sourceSpanId, ...claim }: any) => claim);
        const fallbackUnscopedClaims = index === 0
          ? unscopedClaims.map(({ source_span_id: _sourceSpanId, ...claim }: any) => claim)
          : [];
        return {
          span_id: s.id,
          span_index: s.span_index,
          transcript_segment: s.transcript_segment,
          word_count: s.word_count,
          review_queue_id: pendingReview?.id || null,
          needs_attribution: !!pendingReview,
          project_id: projectId || null,
          project_name: projectName,
          confidence: Number.isFinite(confidenceValue) ? confidenceValue : null,
          claims: [...scopedClaims, ...fallbackUnscopedClaims],
        };
      }),
      pending_attribution_count: Math.max(
        pendingSpanCount,
        pendingCountByInteraction.get(i.interaction_id) || 0,
      ),
      claims: interactionClaimPayload,
    };
  });

  const smsEntries = pagedSmsMessages.map((s: any) => {
    const pendingReview = pendingSmsReviewByMessageId.get(String(s.id));
    return {
      type: "sms",
      sms_id: s.id,
      event_at: s.sent_at,
      direction: s.direction,
      content: s.content,
      sender_name: s.direction === "outbound" ? "Zack" : (s.contact_name || contact.name),
      review_queue_id: pendingReview?.id || null,
      needs_attribution: !!pendingReview,
    };
  });

  const thread = [...callEntries, ...smsEntries].sort(
    (a, b) => new Date(a.event_at).getTime() - new Date(b.event_at).getTime(),
  );

  const totalMs = Date.now() - t0;
  const dbMs = Object.entries(stageMs)
    .filter(([stage]) => stage.startsWith("db_"))
    .reduce((sum, [, ms]) => sum + ms, 0);
  const computeMs = Math.max(0, performance.now() - computeStart - dbMs);
  const serverTiming = buildServerTimingHeader(
    {
      db_ms: dbMs,
      compute_ms: computeMs,
      db_interactions: stageMs.db_interactions || 0,
      db_sms_messages: stageMs.db_sms_messages || 0,
      db_calls_raw: stageMs.db_calls_raw || 0,
      db_conversation_spans: stageMs.db_conversation_spans || 0,
      db_journal_claims: stageMs.db_journal_claims || 0,
      db_claim_grades: stageMs.db_claim_grades || 0,
    },
    totalMs,
  );

  return json({
    ok: true,
    contact: { id: contact.id, name: contact.name, phone: contact.phone },
    thread,
    pagination: { limit, offset, total: totalCount },
    function_version: FUNCTION_VERSION,
    ms: totalMs,
  }, 200, serverTiming ? { "Server-Timing": serverTiming } : {});
}

async function handleThreadApi(db: any, contactId: string, url: URL, t0: number): Promise<Response> {
  const { limit, offset, cursor } = parseLimitOffset(url, { limit: 50, maxLimit: 200, offset: 0 });
  const response = await handleThread(db, contactId, limit, offset, t0);
  if (!response.ok) return response;

  let payload: any;
  try {
    payload = await response.clone().json();
  } catch {
    return response;
  }
  if (!payload?.ok) return response;

  const total = Number(payload?.pagination?.total ?? 0);
  const hasMore = total > offset + limit;
  const prevOffset = Math.max(offset - limit, 0);

  return json({
    ...payload,
    endpoint: "GET /redline/thread/:contact_id",
    pagination: {
      ...payload.pagination,
      mode: "offset_cursor_v1",
      order: [
        "event_at DESC",
        "entity_id DESC",
      ],
      cursor: cursor || null,
      next_cursor: hasMore ? encodeOffsetCursor(offset + limit) : null,
      prev_cursor: offset > 0 ? encodeOffsetCursor(prevOffset) : null,
      has_more: hasMore,
    },
  });
}

async function handleSpansApi(db: any, contactId: string, url: URL, t0: number): Promise<Response> {
  const { limit, offset, cursor } = parseLimitOffset(url, { limit: 100, maxLimit: 500, offset: 0 });

  const { data: contact, error: contactErr } = await db
    .from("contacts")
    .select("id, name, phone")
    .eq("id", contactId)
    .single();

  if (contactErr || !contact) {
    return json({ ok: false, error_code: "contact_not_found", error: contactErr?.message || "not found" }, 404);
  }

  const scanWindow = Math.min(Math.max(offset + limit + 200, 300), 2000);
  const queryPageSize = 200;

  let allInteractions: any[] = [];
  let interactionsFrom = 0;
  let hasMoreInteractions = false;
  while (allInteractions.length < scanWindow) {
    const interactionsTo = interactionsFrom + queryPageSize - 1;
    const { data: page, error: intErr } = await db
      .from("interactions")
      .select("id, interaction_id, event_at_utc, contact_name, is_shadow")
      .eq("contact_id", contactId)
      .or("channel.eq.call,channel.eq.phone,channel.is.null")
      .or("is_shadow.is.false,is_shadow.is.null")
      .not("interaction_id", "like", "cll_SHADOW_%")
      .not("event_at_utc", "is", null)
      .order("event_at_utc", { ascending: false })
      .range(interactionsFrom, interactionsTo);

    if (intErr) {
      return json({ ok: false, error_code: "interactions_query_failed", error: intErr.message }, 500);
    }

    if (!page || page.length === 0) break;
    allInteractions = allInteractions.concat(page);
    if (page.length < queryPageSize) break;
    interactionsFrom += queryPageSize;
    if (allInteractions.length >= scanWindow) {
      hasMoreInteractions = true;
      break;
    }
  }

  if (allInteractions.length === 0) {
    return json({
      ok: true,
      contact: { id: contact.id, name: contact.name, phone: contact.phone },
      spans: [],
      pagination: {
        mode: "offset_cursor_v1",
        limit,
        offset,
        total: 0,
        cursor: cursor || null,
        next_cursor: null,
        prev_cursor: offset > 0 ? encodeOffsetCursor(Math.max(offset - limit, 0)) : null,
        has_more: false,
        order: ["event_at DESC", "interaction_id DESC", "span_index ASC", "span_id ASC"],
      },
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const interactionIds = allInteractions
    .map((i: any) => String(i?.interaction_id || ""))
    .filter((value: string) => value.length > 0);

  const interactionMap = new Map(
    allInteractions
      .filter((row: any) => !!row?.interaction_id)
      .map((row: any) => [String(row.interaction_id), row]),
  );

  const { data: callRows, error: callErr } = await batchIn<any>(
    interactionIds,
    (chunk: string[]) =>
      db
        .from("calls_raw")
        .select("interaction_id, direction")
        .in("interaction_id", chunk),
  );
  if (callErr) {
    return json({ ok: false, error_code: "calls_raw_query_failed", error: callErr.message }, 500);
  }
  const directionByInteraction = new Map(
    (callRows || []).map((row: any) => [String(row?.interaction_id || ""), row?.direction || null]),
  );

  const { data: spansRaw, error: spansErr } = await batchIn<any>(
    interactionIds,
    (chunk: string[]) =>
      db
        .from("conversation_spans")
        .select("id, interaction_id, span_index, transcript_segment, word_count")
        .in("interaction_id", chunk)
        .eq("is_superseded", false)
        .order("span_index", { ascending: true }),
  );
  if (spansErr) {
    return json({ ok: false, error_code: "spans_query_failed", error: spansErr.message }, 500);
  }
  const spans = spansRaw || [];
  const spanIds = spans
    .map((span: any) => String(span?.id || ""))
    .filter((value: string) => value.length > 0);

  const { data: spanAttributions, error: attributionErr } = await batchIn<any>(
    spanIds,
    (chunk: string[]) =>
      db
        .from("span_attributions")
        .select("span_id, project_id, applied_project_id, confidence")
        .in("span_id", chunk),
  );
  if (attributionErr) {
    return json({ ok: false, error_code: "span_attributions_query_failed", error: attributionErr.message }, 500);
  }
  const attributionBySpan = new Map(
    (spanAttributions || []).map((row: any) => [String(row?.span_id || ""), row]),
  );

  const projectIds = [...new Set(
    (spanAttributions || [])
      .map((row: any) => String(row?.applied_project_id || row?.project_id || ""))
      .filter((value: string) => value.length > 0),
  )];
  const { data: projectRows, error: projectErr } = await batchIn<any>(
    projectIds,
    (chunk: string[]) =>
      db
        .from("projects")
        .select("id, name")
        .in("id", chunk),
  );
  if (projectErr) {
    return json({ ok: false, error_code: "projects_query_failed", error: projectErr.message }, 500);
  }
  const projectNameById = new Map(
    (projectRows || []).map((row: any) => [String(row?.id || ""), String(row?.name || "")]),
  );

  const { data: pendingRows, error: pendingErr } = await batchIn<any>(
    spanIds,
    (chunk: string[]) =>
      db
        .from("review_queue")
        .select("id, span_id, created_at")
        .eq("status", "pending")
        .in("span_id", chunk)
        .order("created_at", { ascending: false }),
  );
  if (pendingErr) {
    return json({ ok: false, error_code: "pending_review_query_failed", error: pendingErr.message }, 500);
  }
  const pendingBySpan = new Map<string, any>();
  for (const row of pendingRows || []) {
    const spanId = String(row?.span_id || "");
    if (!spanId || pendingBySpan.has(spanId)) continue;
    pendingBySpan.set(spanId, row);
  }

  const { data: claimRows, error: claimsErr } = await batchIn<any>(
    spanIds,
    (chunk: string[]) =>
      db
        .from("journal_claims")
        .select("id, source_span_id, claim_type, claim_text, speaker_label")
        .eq("active", true)
        .in("source_span_id", chunk),
  );
  if (claimsErr) {
    return json({ ok: false, error_code: "claims_query_failed", error: claimsErr.message }, 500);
  }
  const claimsBySpan = groupBy(
    (claimRows || []).filter((row: any) => !!row?.source_span_id),
    (row: any) => String(row.source_span_id),
  );

  const entries = spans.map((span: any) => {
    const interactionId = String(span?.interaction_id || "");
    const interaction = interactionMap.get(interactionId);
    const attribution = attributionBySpan.get(String(span?.id || ""));
    const pending = pendingBySpan.get(String(span?.id || ""));
    const resolvedProjectId = String(attribution?.applied_project_id || attribution?.project_id || "");
    const confidence = Number(attribution?.confidence);
    const spanClaims = (claimsBySpan.get(String(span?.id || "")) || []).map((claim: any) => ({
      claim_id: claim.id,
      claim_type: claim.claim_type || null,
      claim_text: claim.claim_text || null,
      speaker_label: claim.speaker_label || null,
    }));

    return {
      span_id: span.id,
      interaction_id: interactionId,
      event_at: interaction?.event_at_utc || null,
      direction: directionByInteraction.get(interactionId) || null,
      contact_id: contact.id,
      contact_name: interaction?.contact_name || contact.name,
      span_index: span.span_index,
      transcript_segment: span.transcript_segment,
      word_count: span.word_count,
      review_queue_id: pending?.id || null,
      needs_attribution: !!pending,
      project_id: resolvedProjectId || null,
      project_name: resolvedProjectId ? projectNameById.get(resolvedProjectId) || null : null,
      confidence: Number.isFinite(confidence) ? confidence : null,
      claims: spanClaims,
    };
  });

  entries.sort((lhs: any, rhs: any) => {
    const lhsTs = Date.parse(String(lhs?.event_at || "")) || 0;
    const rhsTs = Date.parse(String(rhs?.event_at || "")) || 0;
    if (lhsTs !== rhsTs) return rhsTs - lhsTs;

    const interactionCmp = String(rhs?.interaction_id || "").localeCompare(String(lhs?.interaction_id || ""));
    if (interactionCmp !== 0) return interactionCmp;

    const indexCmp = Number(lhs?.span_index || 0) - Number(rhs?.span_index || 0);
    if (indexCmp !== 0) return indexCmp;

    return String(lhs?.span_id || "").localeCompare(String(rhs?.span_id || ""));
  });

  const paged = entries.slice(offset, offset + limit);
  const hasMore = hasMoreInteractions || entries.length > offset + limit;

  return json({
    ok: true,
    endpoint: "GET /redline/spans/:contact_id",
    contact: { id: contact.id, name: contact.name, phone: contact.phone },
    spans: paged,
    pagination: {
      mode: "offset_cursor_v1",
      limit,
      offset,
      total: hasMore ? Math.max(entries.length, offset + paged.length + 1) : entries.length,
      cursor: cursor || null,
      next_cursor: hasMore ? encodeOffsetCursor(offset + limit) : null,
      prev_cursor: offset > 0 ? encodeOffsetCursor(Math.max(offset - limit, 0)) : null,
      has_more: hasMore,
      order: ["event_at DESC", "interaction_id DESC", "span_index ASC", "span_id ASC"],
    },
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

async function handleVerdict(db: any, req: Request, t0: number): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json(
      { ok: false, error_code: "invalid_json", error: "Request body must be valid JSON" },
      400,
    );
  }

  const reviewQueueId = String(body?.review_queue_id || "").trim();
  const verdict = String(body?.verdict || "assign").trim().toLowerCase();
  const projectId = String(body?.project_id || "").trim();
  const notes = String(body?.notes || "").trim() || null;
  const userId = String(body?.user_id || "redline_api").trim() || "redline_api";
  const source = normalizeReviewQueueSource(body?.source, "redline");

  if (!reviewQueueId || !isValidUUID(reviewQueueId)) {
    return json(
      { ok: false, error_code: "missing_review_queue_id", error: "review_queue_id required (uuid)" },
      400,
    );
  }

  await tagReviewQueueSource(db, reviewQueueId, source, "redline-thread:verdict");

  const { data: queueRow, error: queueErr } = await db
    .from("review_queue")
    .select("id, status, span_id, interaction_id")
    .eq("id", reviewQueueId)
    .maybeSingle();

  if (queueErr) {
    return json({ ok: false, error_code: "review_queue_lookup_failed", error: queueErr.message }, 500);
  }
  if (!queueRow) {
    return json({ ok: false, error_code: "review_queue_not_found" }, 404);
  }

  if (verdict === "dismiss" || verdict === "skip" || verdict === "ignore") {
    const { error: dismissErr } = await db
      .from("review_queue")
      .update({
        status: "resolved",
        resolved_at: new Date().toISOString(),
        resolved_by: userId,
      })
      .eq("id", reviewQueueId)
      .eq("status", "pending");

    if (dismissErr) {
      return json({ ok: false, error_code: "dismiss_failed", error: dismissErr.message }, 500);
    }

    return json({
      ok: true,
      action: "dismiss",
      review_queue_id: reviewQueueId,
      interaction_id: queueRow.interaction_id || null,
      source,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  if (!projectId || !isValidUUID(projectId)) {
    return json(
      { ok: false, error_code: "missing_project_id", error: "project_id required (uuid)" },
      400,
    );
  }

  if (!queueRow.span_id) {
    const { error: resolveErr } = await db
      .from("review_queue")
      .update({
        status: "resolved",
        resolved_at: new Date().toISOString(),
        resolved_by: userId,
      })
      .eq("id", reviewQueueId)
      .eq("status", "pending");

    if (resolveErr) {
      return json({ ok: false, error_code: "non_span_resolve_failed", error: resolveErr.message }, 500);
    }

    return json({
      ok: true,
      action: "resolve_without_span",
      review_queue_id: reviewQueueId,
      chosen_project_id: projectId,
      interaction_id: queueRow.interaction_id || null,
      notes,
      source,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const { data: rpcData, error: rpcErr } = await db.rpc("resolve_review_item", {
    p_review_queue_id: reviewQueueId,
    p_chosen_project_id: projectId,
    p_notes: notes,
    p_user_id: userId,
  });

  if (rpcErr) {
    return json({ ok: false, error_code: "rpc_failed", error: rpcErr.message, review_queue_id: reviewQueueId }, 500);
  }

  const resolved = typeof rpcData === "string" ? JSON.parse(rpcData) : rpcData;
  if (!resolved?.ok) {
    const status =
      resolved?.error === "review_queue_item_not_found"
        ? 404
        : resolved?.error === "human_lock_conflict"
        ? 409
        : 400;
    return json({ ...resolved, ms: Date.now() - t0 }, status);
  }

  return json({
    ...resolved,
    ok: true,
    action: "resolve",
    source,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// grade endpoint
async function handleGrade(db: any, req: Request, t0: number): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error_code: "invalid_json", error: "Request body must be valid JSON" }, 400);
  }

  const { claim_id, grade, correction_text, graded_by } = body;

  if (!claim_id) return json({ ok: false, error_code: "missing_claim_id" }, 400);
  if (!grade) return json({ ok: false, error_code: "missing_grade" }, 400);
  if (!["confirm", "reject", "correct"].includes(grade)) {
    return json({ ok: false, error_code: "invalid_grade", error: "grade must be confirm, reject, or correct" }, 400);
  }
  if (grade === "correct" && !correction_text) {
    return json(
      { ok: false, error_code: "missing_correction_text", error: "correction_text required for grade=correct" },
      400,
    );
  }
  if (!graded_by) return json({ ok: false, error_code: "missing_graded_by" }, 400);

  const { data, error } = await db
    .from("claim_grades")
    .upsert(
      {
        claim_id,
        grade,
        correction_text: correction_text || null,
        graded_by,
        graded_at: new Date().toISOString(),
      },
      { onConflict: "claim_id,graded_by" },
    )
    .select()
    .single();

  if (error) {
    return json({ ok: false, error_code: "grade_insert_failed", error: error.message }, 500);
  }

  return json({ ok: true, grade: data, function_version: FUNCTION_VERSION, ms: Date.now() - t0 });
}

// PWA icon base64 strings (red R on black, 3 sizes)
const ICON_180 =
  "iVBORw0KGgoAAAANSUhEUgAAALQAAAC0CAYAAAA9zQYyAAAHN0lEQVR4nO3d32tk5R3H8c+ZmcxkJpmdTEhMd7Puxeq67I2CRUQsiFTx1uJCKVIvLLrYXvRG7EVB8Mc/oMVSXV2oiOKqvagWlhYRUdtSSr3o0tZa67a4m6zZZDI7M2cyk5xzeiErpTWa5JnNec73vF+Qyzl5MnnzcObMeZ4TSEoEGFFIewDAKBE0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKQQNUwgaphA0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKaW0B+CDQNI3JiZ0Vbm8629ILGmQJBrEsZajSAsbG/rXcKh+kuzySGwIJOX+nXtsbk7faTTSHsbnIkn/HA71hzDUW72e3gtDrRP4luQ+6IKk04cOqRwEaQ9lU8tRpJPttk60WmpFUdrD8Vrug64XCnr/6qvTHsaWdONYTy0v67lWS3Hag/FU7j8U+jsv/7/JQkE/mp3VS1deqbkSH3++SO6DzqKvV6t67cABXVOppD0U7xB0Rn2tVNLz+/frwNhY2kPxCkFn2EyxqGfn51Ut8G+8hHci4w6Wy3p4djbtYXiDoA042mjouvHxtIfhBYI2IJD04MxM2sPwAkEbcVOtpsNc9SBoS+7asyftIaSOoEcgljRMkm39XA63TU5eluNmCV83OfpNt6sfLixsO9JiEKhZKOjI+LhuqdV0V6OhuuPltwNjY9pXKuncxobTcbKMGdrR78JwRzNulCS6EEV6p9fT40tLuv3jj/X7MHQez7U5v9pB0I5GdfJwIYp07Nw5nRkOnY5zKOcfDAnaI7041lMrK07H2Jvzm5YI2jO/7nadbg2dIWj4pBfHTqcdVY8XKuwGgvaQy6qU8ZzfqJTvv95TYbzzk468/0Pz/vfDGIKGKQQNUwgaphA0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKQQNUwgaphA0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKQQNUwgaphA0TCFomELQMOU/hcvt+Vd481YAAAAASUVORK5CYII=";

const _ICON_192 =
  "iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAYAAABS3GwHAAAHp0lEQVR4nO3dT4ic9R3H8c8zf5edfWZ3JtkYs1C3CsWCQm7ioR70YhOoSm0pRGoVNNaTNw+9KD2UIkhDD7ZJwHqQCiIWPYSqQS9KaUshVPqHRoxsYsi6M7OTmdmZzD4zTw9eHJxsdn1+w/Pn+37d99kvO/vmeZ55fs/zeJJCAUbl4h4AiBMBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwLRC3AMk1a2lko76vpYLBXkxzTAKQ/XDUP3xWOtBoMtBoPPDoS5tb8c0UfZ4ksK4h0iabxWLOrO6qrIX17/+zjZHI/2t39f7vZ7e7XbVGo3iHim1CGCKJ2o1Pbu8HPcYuzIMQ53pdHSq1dJ/rl2Le5zU4Rxgin2F9BwZljxPD1SreuuWW/TCwYOq5fNxj5QqBDBFMg98dpaT9FC1qjOrq7qnUol7nNQggIzZn8/r1MqKHllainuUVCCADMpLeu7AAf2sVot7lMQjgAz7xfKy7vf9uMdINALIMF/Sr266SSvFYtyjJBYBZJyfy+mXBw7IPUaCAACShAAAhAQAAISEAACSEgAAkJAAAICEBAAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQ==";

const _ICON_512 =
  "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAXbUlEQVR4nO3de4yld13H8e+ZM2dmzs7s7Ozvfda2DoEAobTgqCJAgwq9qCRSsFIoBaVuTHwhuEKibap8lapS1EaldakqggNyTMBCKQWKrFwELimVSeQkmGJhJQ12cNhdh7t3zs7O3C9nTg9eHJxsdn1+w/Pn+37d99kvO/vmeZ55fs/zeJJCAUbl4h4AiBMBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwLRC3AMk1a2lko76vpYLBXkxzTAKQ/XDUP3xWOtBoMtBoPPDoS5tb8c0UfZ4ksK4h0iabxWLOrO6qrIX17/+zjZHI/2t39f7vZ7e7XbVGo3iHim1CGCKJ2o1Pbu8HPcYuzIMQ53pdHSq1dJ/rl2Le5zU4Rxgin2F9BwZljxPD1SreuuWW/TCwYOq5fNxj5QqBDBFMg98dpaT9FC1qjOrq7qnUol7nNQggIzZn8/r1MqKHllainuUVCCADMpLeu7AAf2sVot7lMQjgAz7xfKy7vf9uMdINALIMF/Sr266SSvFYtyjJBYBZJyfy+mXBw7IPUaCAACShAAAhAQAAISEAACSEgAAkJAAAICEBAAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQ==";

// HTML UI — all user content goes through textContent (XSS safe). Static innerHTML only for spinners/empty states.
const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="Redline">
  <title>Redline</title>
  <link rel="apple-touch-icon" sizes="180x180" href="data:image/png;base64,${ICON_180}">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #000; color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      font-size: 16px; -webkit-font-smoothing: antialiased;
      min-height: 100dvh;
      padding-bottom: env(safe-area-inset-bottom, 0px);
    }
    #top-bar {
      position: sticky; top: 0; z-index: 10;
      background: rgba(28,28,30,0.92);
      backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
      padding: 12px 16px; border-bottom: 0.5px solid #38383A;
      display: flex; align-items: center; gap: 12px;
    }
    #top-bar h1 { font-size: 17px; font-weight: 600; white-space: nowrap; }
    .search-container { position: relative; flex: 1; max-width: 320px; }
    .search-input {
      width: 100%; background: #2C2C2E; color: #fff; border: none; border-radius: 10px;
      padding: 8px 36px 8px 12px; font-size: 15px; outline: none; min-height: 44px;
    }
    .search-input::placeholder { color: #8E8E93; }
    .search-input:focus { box-shadow: 0 0 0 2px #007AFF; }
    .search-clear {
      position: absolute; right: 8px; top: 50%; transform: translateY(-50%);
      background: none; border: none; color: #8E8E93; font-size: 18px;
      cursor: pointer; padding: 4px; min-width: 32px; min-height: 32px;
      display: flex; align-items: center; justify-content: center;
    }
    .search-dropdown {
      position: absolute; top: calc(100% + 4px); left: 0; right: 0; max-height: 320px;
      overflow-y: auto; background: #1C1C1E; border-radius: 12px;
      z-index: 20; display: none; -webkit-overflow-scrolling: touch;
      box-shadow: 0 8px 32px rgba(0,0,0,0.6); border: 0.5px solid #38383A;
    }
    .search-dropdown.open { display: block; }
    .search-item {
      padding: 12px 14px; cursor: pointer; font-size: 15px;
      border-bottom: 0.5px solid #2C2C2E; min-height: 48px;
      display: flex; align-items: center; justify-content: space-between;
    }
    .search-item:last-child { border-bottom: none; }
    .search-item:active, .search-item.selected { background: #2C2C2E; }
    .search-item-name { flex: 1; font-weight: 500; }
    .search-item-meta { color: #8E8E93; font-size: 13px; margin-left: 10px; flex-shrink: 0; }
    #contact-header { display: none; padding: 12px 16px 4px; max-width: 800px; margin: 0 auto; }
    #contact-header-name { font-size: 20px; font-weight: 700; }
    #contact-header-meta { font-size: 13px; color: #8E8E93; margin-top: 2px; }
    #thread-container { max-width: 800px; margin: 0 auto; padding: 8px 16px 120px; }
    .date-separator {
      text-align: center; color: #8E8E93; font-size: 12px; font-weight: 500;
      padding: 18px 0 6px; letter-spacing: 0.2px;
    }
    .call-card { background: #1C1C1E; border-radius: 16px; padding: 14px 16px; margin: 8px 0; }
    .call-card-header { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
    .call-icon {
      width: 36px; height: 36px; border-radius: 50%; background: #30D158;
      display: flex; align-items: center; justify-content: center; font-size: 16px; flex-shrink: 0;
    }
    .call-icon.outbound { background: #007AFF; }
    .call-icon.unknown { background: #636366; }
    .call-card-top { flex: 1; }
    .call-card-type-row { display: flex; align-items: center; justify-content: space-between; }
    .call-card-type { font-size: 13px; color: #8E8E93; font-weight: 500; }
    .call-card-time { font-size: 13px; color: #8E8E93; }
    .call-card-title { font-size: 16px; font-weight: 600; margin-bottom: 4px; line-height: 1.3; }
    .call-card-participants { font-size: 13px; color: #8E8E93; margin-bottom: 8px; }
    .call-card-summary { font-size: 14px; color: #EBEBF5; line-height: 1.5; margin-bottom: 10px; }
    .read-convo-btn {
      display: inline-flex; align-items: center; gap: 6px;
      background: #2C2C2E; color: #007AFF; border: none; border-radius: 20px;
      padding: 8px 16px; font-size: 14px; font-weight: 500; cursor: pointer;
      margin-bottom: 10px; min-height: 36px; -webkit-tap-highlight-color: transparent;
    }
    .read-convo-btn:active { opacity: 0.7; }
    .transcript-area { display: none; margin-bottom: 10px; }
    .transcript-area.open { display: block; }
    .speaker-group { margin: 6px 0; }
    .speaker-name-label { font-size: 11px; color: #8E8E93; padding: 0 6px; margin-bottom: 3px; }
    .speaker-name-label.our-side { text-align: right; }
    .speaker-row { display: flex; margin: 2px 0; }
    .speaker-row.our-side { justify-content: flex-end; }
    .speaker-row.their-side { justify-content: flex-start; }
    .speaker-bubble { max-width: 80%; padding: 10px 14px; font-size: 15px; line-height: 1.4; word-wrap: break-word; }
    .speaker-row.our-side .speaker-bubble {
      background: #007AFF; border-radius: 18px; border-bottom-right-radius: 4px; color: #fff;
    }
    .speaker-row.their-side .speaker-bubble {
      background: #2C2C2E; border-radius: 18px; border-bottom-left-radius: 4px; color: #fff;
    }
    .claims-section { margin-top: 10px; }
    .claims-header {
      font-size: 12px; font-weight: 600; color: #8E8E93; text-transform: uppercase;
      letter-spacing: 0.6px; margin-bottom: 6px;
    }
    .claim-item {
      padding: 10px 12px; margin: 4px 0; border-radius: 10px; background: #2C2C2E;
      font-size: 14px; line-height: 1.4; cursor: pointer;
      display: flex; align-items: flex-start; gap: 8px; min-height: 44px;
      -webkit-tap-highlight-color: transparent;
    }
    .claim-item:active { background: #3A3A3C; }
    .claim-bullet { flex-shrink: 0; width: 7px; height: 7px; border-radius: 50%; background: #636366; margin-top: 5px; }
    .claim-item.graded-confirm .claim-bullet { background: #30D158; }
    .claim-item.graded-reject .claim-bullet { background: #FF453A; }
    .claim-item.graded-correct .claim-bullet { background: #FF9F0A; }
    .claim-text-wrap { flex: 1; }
    .claim-type-tag {
      display: inline-block; font-size: 11px; font-weight: 600; color: #8E8E93;
      background: #3A3A3C; padding: 2px 6px; border-radius: 4px; margin-right: 5px;
    }
    .claim-badge { flex-shrink: 0; font-size: 15px; margin-left: 4px; }
    .sms-group { margin: 6px 0; }
    .sms-sender-label { font-size: 11px; color: #8E8E93; padding: 0 6px; margin-bottom: 3px; }
    .sms-sender-label.outbound { text-align: right; }
    .sms-row { display: flex; margin: 2px 0; }
    .sms-row.inbound { justify-content: flex-start; }
    .sms-row.outbound { justify-content: flex-end; }
    .sms-bubble { max-width: 75%; padding: 10px 14px; font-size: 15px; line-height: 1.4; word-wrap: break-word; }
    .sms-row.inbound .sms-bubble { background: #2C2C2E; border-radius: 18px; border-bottom-left-radius: 4px; }
    .sms-row.outbound .sms-bubble { background: #007AFF; border-radius: 18px; border-bottom-right-radius: 4px; }
    .stats-bar { display: flex; gap: 14px; padding: 4px 0 10px; font-size: 13px; color: #8E8E93; flex-wrap: wrap; }
    .stat-item { display: flex; align-items: center; gap: 5px; }
    .stat-dot { width: 8px; height: 8px; border-radius: 50%; }
    .stat-dot.green { background: #30D158; }
    .stat-dot.red { background: #FF453A; }
    .stat-dot.yellow { background: #FF9F0A; }
    .stat-dot.gray { background: #8E8E93; }
    #grade-overlay {
      display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.65);
      backdrop-filter: blur(4px); -webkit-backdrop-filter: blur(4px);
      z-index: 100; justify-content: center; align-items: flex-end;
      padding: 0 16px calc(32px + env(safe-area-inset-bottom, 0px));
    }
    #grade-overlay.open { display: flex; }
    #grade-sheet { background: #2C2C2E; border-radius: 16px; padding: 20px; width: 100%; max-width: 380px; }
    #grade-sheet h3 { font-size: 16px; font-weight: 600; margin-bottom: 6px; }
    #grade-claim-preview {
      font-size: 13px; color: #8E8E93; margin-bottom: 18px; line-height: 1.5;
      max-height: 90px; overflow-y: auto;
    }
    .grade-btn {
      display: block; width: 100%; padding: 14px; margin: 6px 0; border: none;
      border-radius: 12px; font-size: 16px; font-weight: 600; cursor: pointer;
      text-align: center; min-height: 50px;
    }
    .grade-btn:active { opacity: 0.7; }
    .grade-btn.confirm { background: #30D158; color: #000; }
    .grade-btn.reject { background: #FF453A; color: #fff; }
    .grade-btn.correct-btn { background: #FF9F0A; color: #000; }
    .grade-btn.cancel { background: #3A3A3C; color: #fff; margin-top: 14px; }
    #correction-area { display: none; margin-top: 12px; }
    #correction-area textarea {
      width: 100%; min-height: 80px; padding: 10px; background: #1C1C1E; color: #fff;
      border: 1px solid #48484A; border-radius: 10px; font-size: 15px; resize: vertical;
    }
    #correction-area .grade-btn { margin-top: 8px; }
    .loading { text-align: center; padding: 48px; color: #8E8E93; font-size: 15px; }
    .spinner {
      display: inline-block; width: 26px; height: 26px;
      border: 2px solid #3A3A3C; border-top-color: #007AFF;
      border-radius: 50%; animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .empty-state { text-align: center; padding: 60px 20px; color: #636366; font-size: 15px; }
    @media (max-width: 600px) {
      .search-container { max-width: none; }
      #top-bar { flex-wrap: wrap; }
      #top-bar h1 { flex: 0 0 auto; }
    }
  </style>
</head>
<body>
  <div id="top-bar">
    <h1>Redline</h1>
    <div class="search-container">
      <input type="text" class="search-input" id="contact-search"
        placeholder="Search contacts..." autocomplete="off" spellcheck="false" />
      <button class="search-clear" id="contact-clear" aria-label="Clear"></button>
      <div class="search-dropdown" id="contact-dropdown"></div>
    </div>
  </div>
  <div id="contact-header">
    <div id="contact-header-name"></div>
    <div id="contact-header-meta"></div>
  </div>
  <div id="thread-container">
    <div class="loading"><div class="spinner"></div><div style="margin-top:14px">Loading contacts\u2026</div></div>
  </div>
  <div id="grade-overlay">
    <div id="grade-sheet">
      <h3>Grade Claim</h3>
      <div id="grade-claim-preview"></div>
      <button class="grade-btn confirm" data-action="grade-confirm">\u2705 Confirm</button>
      <button class="grade-btn reject" data-action="grade-reject">\u274C Reject</button>
      <button class="grade-btn correct-btn" data-action="grade-show-correct">\u270F\uFE0F Correct</button>
      <div id="correction-area">
        <textarea id="correction-text" placeholder="Enter correction\u2026"></textarea>
        <button class="grade-btn confirm" data-action="grade-submit-correct">Submit Correction</button>
      </div>
      <button class="grade-btn cancel" data-action="grade-cancel">Cancel</button>
    </div>
  </div>
  <script>
    (function () {
      "use strict";
      var BASE_URL = window.location.origin + window.location.pathname;
      var currentClaimId = null;
      var allContacts = [];
      var selectedContactId = null;

      function escText(t) {
        var d = document.createElement("div");
        d.textContent = t || "";
        return d.innerHTML;
      }

      var OUR_NAMES = ["zack sittler","zachary sittler","zack","zach","chad","chad barlow","hcb"];
      function isOurSide(name) {
        if (!name) return false;
        var l = name.toLowerCase().trim();
        for (var i = 0; i < OUR_NAMES.length; i++) {
          if (l === OUR_NAMES[i]) return true;
        }
        return l.indexOf("zack") === 0 || l.indexOf("zachary") === 0;
      }

      var SPEAKER_RE = /^(?:\\[\\d+:\\d+\\]\\s*)?([A-Za-z][A-Za-z0-9_ +().-]*?):\\s(.+)/;
      function parseTranscriptTurns(text) {
        if (!text) return [];
        var lines = text.split("\\n");
        var turns = [];
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (!line) continue;
          var m = line.match(SPEAKER_RE);
          if (m) {
            var sp = m[1].trim();
            var ct = m[2].trim();
            if (turns.length > 0 && turns[turns.length - 1].speaker === sp) {
              turns[turns.length - 1].text += " " + ct;
            } else {
              turns.push({ speaker: sp, text: ct, ourSide: isOurSide(sp) });
            }
          } else if (turns.length > 0) {
            turns[turns.length - 1].text += " " + line;
          } else {
            turns.push({ speaker: "Unknown", text: line, ourSide: false });
          }
        }
        return turns;
      }

      function buildTranscriptBubbles(item) {
        var transcript = item.raw_transcript || "";
        if (!transcript && item.spans && item.spans.length > 0) {
          transcript = item.spans.map(function (s) { return s.transcript_segment || ""; }).join("\\n");
        }
        if (!transcript.trim()) return null;
        var container = document.createElement("div");
        container.className = "transcript-area";
        var turns = parseTranscriptTurns(transcript);
        if (turns.length === 0) return null;
        var prevSpeaker = null;
        var groupEl = null;
        for (var i = 0; i < turns.length; i++) {
          var turn = turns[i];
          var side = turn.ourSide ? "our-side" : "their-side";
          if (turn.speaker !== prevSpeaker) {
            groupEl = document.createElement("div");
            groupEl.className = "speaker-group";
            var lbl = document.createElement("div");
            lbl.className = "speaker-name-label" + (turn.ourSide ? " our-side" : "");
            lbl.textContent = turn.speaker;
            groupEl.appendChild(lbl);
            container.appendChild(groupEl);
          }
          var row = document.createElement("div");
          row.className = "speaker-row " + side;
          var bub = document.createElement("div");
          bub.className = "speaker-bubble";
          bub.textContent = turn.text;
          row.appendChild(bub);
          groupEl.appendChild(row);
          prevSpeaker = turn.speaker;
        }
        return container;
      }

      function formatDateSep(date) {
        var now = new Date();
        var today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        var yesterday = new Date(today.getTime() - 86400000);
        var d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
        var diff = today.getTime() - d.getTime();
        var timeStr = date.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
        if (d.getTime() === today.getTime()) return "Today " + timeStr;
        if (d.getTime() === yesterday.getTime()) return "Yesterday " + timeStr;
        if (diff < 7 * 86400000) return date.toLocaleDateString("en-US", { weekday: "long" }) + " at " + timeStr;
        return date.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) + " " + timeStr;
      }

      function formatTime(ds) {
        return new Date(ds).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
      }

      var searchInput = document.getElementById("contact-search");
      var searchClear = document.getElementById("contact-clear");
      var searchDropdown = document.getElementById("contact-dropdown");

      function renderDropdown(filter) {
        while (searchDropdown.firstChild) searchDropdown.removeChild(searchDropdown.firstChild);
        var query = (filter || "").toLowerCase().trim();
        var matches = allContacts.filter(function (c) {
          return !query || c.name.toLowerCase().indexOf(query) !== -1;
        }).slice(0, 60);
        if (matches.length === 0) {
          var empty = document.createElement("div");
          empty.className = "search-item";
          empty.style.color = "#636366";
          empty.textContent = "No contacts found";
          searchDropdown.appendChild(empty);
        } else {
          matches.forEach(function (c) {
            var item = document.createElement("div");
            item.className = "search-item";
            item.setAttribute("data-contact-id", c.contact_id);
            var ns = document.createElement("span");
            ns.className = "search-item-name";
            ns.textContent = c.name;
            var ms = document.createElement("span");
            ms.className = "search-item-meta";
            var parts = [];
            if (c.call_count > 0) parts.push(c.call_count + " calls");
            if (c.sms_count > 0) parts.push(c.sms_count + " sms");
            ms.textContent = parts.join(" \u00b7 ");
            item.appendChild(ns);
            item.appendChild(ms);
            searchDropdown.appendChild(item);
          });
        }
        searchDropdown.classList.add("open");
      }

      function selectContact(contactId, contactName) {
        selectedContactId = contactId;
        searchInput.value = contactName;
        searchClear.textContent = "\u00d7";
        searchDropdown.classList.remove("open");
        loadThread(contactId);
      }

      function clearContactSearch() {
        selectedContactId = null;
        searchInput.value = "";
        searchClear.textContent = "";
        searchDropdown.classList.remove("open");
        document.getElementById("contact-header").style.display = "none";
      }

      searchInput.addEventListener("focus", function () { renderDropdown(searchInput.value); });
      searchInput.addEventListener("input", function () {
        selectedContactId = null;
        searchClear.textContent = searchInput.value ? "\u00d7" : "";
        renderDropdown(searchInput.value);
      });
      searchClear.addEventListener("click", function (e) {
        e.stopPropagation();
        clearContactSearch();
        searchInput.focus();
      });
      searchDropdown.addEventListener("click", function (e) {
        var item = e.target.closest(".search-item");
        if (item && item.dataset.contactId) {
          var nameEl = item.querySelector(".search-item-name");
          selectContact(item.dataset.contactId, nameEl ? nameEl.textContent : "");
        }
      });
      document.addEventListener("click", function (e) {
        if (!e.target.closest(".search-container")) searchDropdown.classList.remove("open");
      });

      async function loadContacts() {
        try {
          var res = await fetch(BASE_URL + "?action=contacts");
          var data = await res.json();
          if (!data.ok) throw new Error(data.error || "Failed to load contacts");
          allContacts = data.contacts;
          var defaultId = new URLSearchParams(window.location.search).get("contact_id");
          if (!defaultId && allContacts.length > 0) defaultId = allContacts[0].contact_id;
          if (defaultId) {
            var match = allContacts.find(function (c) { return c.contact_id === defaultId; });
            if (match) {
              selectContact(match.contact_id, match.name);
            } else if (allContacts.length > 0) {
              selectContact(allContacts[0].contact_id, allContacts[0].name);
            }
          } else {
            var tc = document.getElementById("thread-container");
            tc.textContent = "";
            var es = document.createElement("div");
            es.className = "empty-state";
            es.textContent = "Select a contact to view their thread";
            tc.appendChild(es);
          }
        } catch (e) {
          var tc2 = document.getElementById("thread-container");
          tc2.textContent = "Error: " + e.message;
        }
      }

      async function loadThread(contactId) {
        var container = document.getElementById("thread-container");
        container.textContent = "";
        var loadDiv = document.createElement("div");
        loadDiv.className = "loading";
        var spinDiv = document.createElement("div");
        spinDiv.className = "spinner";
        var msgDiv = document.createElement("div");
        msgDiv.style.marginTop = "14px";
        msgDiv.textContent = "Loading thread\u2026";
        loadDiv.appendChild(spinDiv);
        loadDiv.appendChild(msgDiv);
        container.appendChild(loadDiv);
        try {
          var res = await fetch(BASE_URL + "?contact_id=" + encodeURIComponent(contactId) + "&limit=100");
          var data = await res.json();
          if (!data.ok) throw new Error(data.error || "Failed to load thread");
          renderThread(data, container);
          history.replaceState(null, "", "?contact_id=" + encodeURIComponent(contactId));
        } catch (e) {
          container.textContent = "Error: " + e.message;
        }
      }

      function renderThread(data, container) {
        container.textContent = "";
        var hdr = document.getElementById("contact-header");
        document.getElementById("contact-header-name").textContent = data.contact.name;
        document.getElementById("contact-header-meta").textContent =
          data.pagination.total + " calls \u00b7 " + (data.contact.phone || "");
        hdr.style.display = "block";

        if (!data.thread || data.thread.length === 0) {
          var es = document.createElement("div");
          es.className = "empty-state";
          es.textContent = "No messages found";
          container.appendChild(es);
          return;
        }

        var gradeStats = { confirm: 0, reject: 0, correct: 0, ungraded: 0 };
        data.thread.forEach(function (item) {
          if (item.type !== "call") return;
          (item.claims || []).forEach(function (c) {
            if (c.grade) gradeStats[c.grade] = (gradeStats[c.grade] || 0) + 1;
            else gradeStats.ungraded++;
          });
        });
        var totalClaims = gradeStats.confirm + gradeStats.reject + gradeStats.correct + gradeStats.ungraded;
        if (totalClaims > 0) {
          var statsDiv = document.createElement("div");
          statsDiv.className = "stats-bar";
          [
            { cls: "green", count: gradeStats.confirm, label: " confirmed" },
            { cls: "red", count: gradeStats.reject, label: " rejected" },
            { cls: "yellow", count: gradeStats.correct, label: " corrected" },
            { cls: "gray", count: gradeStats.ungraded, label: " ungraded" },
          ].forEach(function (s) {
            if (s.count === 0) return;
            var si = document.createElement("div");
            si.className = "stat-item";
            var dot = document.createElement("span");
            dot.className = "stat-dot " + s.cls;
            si.appendChild(dot);
            si.appendChild(document.createTextNode(s.count + s.label));
            statsDiv.appendChild(si);
          });
          container.appendChild(statsDiv);
        }

        var lastDateKey = "";
        data.thread.forEach(function (item) {
          var eventDate = new Date(item.event_at);
          var dateKey = eventDate.toDateString();
          if (dateKey !== lastDateKey) {
            var sep = document.createElement("div");
            sep.className = "date-separator";
            sep.textContent = formatDateSep(eventDate);
            container.appendChild(sep);
            lastDateKey = dateKey;
          }
          if (item.type === "call") container.appendChild(buildCallCard(item, data.contact));
          else if (item.type === "sms") container.appendChild(buildSmsItem(item));
        });

        window.scrollTo(0, document.body.scrollHeight);
      }

      function buildCallCard(item, contact) {
        var card = document.createElement("div");
        card.className = "call-card";

        var hdr = document.createElement("div");
        hdr.className = "call-card-header";
        var dir = item.direction || "unknown";
        var iconEl = document.createElement("div");
        iconEl.className = "call-icon" + (dir === "outbound" ? " outbound" : dir === "unknown" ? " unknown" : "");
        iconEl.textContent = "\uD83D\uDCDE";
        hdr.appendChild(iconEl);

        var topInfo = document.createElement("div");
        topInfo.className = "call-card-top";
        var typeRow = document.createElement("div");
        typeRow.className = "call-card-type-row";
        var typeLabel = document.createElement("span");
        typeLabel.className = "call-card-type";
        typeLabel.textContent = "Phone Call";
        var timeLabel = document.createElement("span");
        timeLabel.className = "call-card-time";
        timeLabel.textContent = formatTime(item.event_at);
        typeRow.appendChild(typeLabel);
        typeRow.appendChild(timeLabel);
        topInfo.appendChild(typeRow);
        hdr.appendChild(topInfo);
        card.appendChild(hdr);

        if (item.summary) {
          var titleEl = document.createElement("div");
          titleEl.className = "call-card-title";
          var firstLine = item.summary.split("\\n")[0].trim();
          titleEl.textContent = firstLine.length > 80 ? firstLine.slice(0, 80) + "\u2026" : firstLine;
          card.appendChild(titleEl);
        }

        var contactName = item.contact_name || (contact && contact.name) || "Contact";
        var partEl = document.createElement("div");
        partEl.className = "call-card-participants";
        partEl.textContent = "\uD83D\uDC64 Zack \u2194 " + contactName;
        card.appendChild(partEl);

        if (item.summary) {
          var sumEl = document.createElement("div");
          sumEl.className = "call-card-summary";
          var full = item.summary;
          sumEl.textContent = full.length > 200 ? full.slice(0, 200) + "\u2026" : full;
          card.appendChild(sumEl);
        }

        var hasTranscript = (item.raw_transcript && item.raw_transcript.trim().length > 0) ||
          (item.spans || []).some(function (s) { return s.transcript_segment; });

        if (hasTranscript) {
          var btn = document.createElement("button");
          btn.className = "read-convo-btn";
          btn.setAttribute("data-action", "toggle-transcript");
          btn.textContent = "\uD83D\uDCAC Read Conversation";
          card.appendChild(btn);
          var bubblesContainer = buildTranscriptBubbles(item);
          if (bubblesContainer) card.appendChild(bubblesContainer);
        }

        var claims = item.claims || [];
        if (claims.length > 0) {
          var section = document.createElement("div");
          section.className = "claims-section";
          var claimsHdr = document.createElement("div");
          claimsHdr.className = "claims-header";
          claimsHdr.textContent = "Claims (" + claims.length + ")";
          section.appendChild(claimsHdr);
          claims.forEach(function (claim) {
            var el = document.createElement("div");
            el.className = "claim-item" + (claim.grade ? " graded-" + claim.grade : "");
            el.setAttribute("data-claim-id", claim.claim_id);
            el.setAttribute("data-claim-text", claim.claim_text || "");
            var bullet = document.createElement("div");
            bullet.className = "claim-bullet";
            el.appendChild(bullet);
            var tw = document.createElement("div");
            tw.className = "claim-text-wrap";
            if (claim.claim_type) {
              var tag = document.createElement("span");
              tag.className = "claim-type-tag";
              tag.textContent = claim.claim_type;
              tw.appendChild(tag);
            }
            tw.appendChild(document.createTextNode(claim.claim_text || ""));
            el.appendChild(tw);
            if (claim.grade) {
              var badge = document.createElement("span");
              badge.className = "claim-badge";
              badge.textContent =
                claim.grade === "confirm" ? "\u2705" : claim.grade === "reject" ? "\u274C" : "\u270F\uFE0F";
              el.appendChild(badge);
            }
            section.appendChild(el);
          });
          card.appendChild(section);
        }

        return card;
      }

      function buildSmsItem(item) {
        var dir = item.direction || "inbound";
        var group = document.createElement("div");
        group.className = "sms-group";
        var senderLabel = document.createElement("div");
        senderLabel.className = "sms-sender-label" + (dir === "outbound" ? " outbound" : "");
        senderLabel.textContent = item.sender_name || (dir === "outbound" ? "Zack" : "Contact");
        group.appendChild(senderLabel);
        var row = document.createElement("div");
        row.className = "sms-row " + dir;
        var bubble = document.createElement("div");
        bubble.className = "sms-bubble";
        bubble.textContent = item.content || "";
        row.appendChild(bubble);
        group.appendChild(row);
        return group;
      }

      function openGradeSheet(claimId, claimText) {
        currentClaimId = claimId;
        document.getElementById("grade-claim-preview").textContent = claimText;
        document.getElementById("correction-area").style.display = "none";
        document.getElementById("correction-text").value = "";
        document.getElementById("grade-overlay").classList.add("open");
      }

      function closeGradeSheet() {
        document.getElementById("grade-overlay").classList.remove("open");
        currentClaimId = null;
      }

      async function submitGrade(grade) {
        if (!currentClaimId) return;
        var correctionText = null;
        if (grade === "correct") {
          correctionText = document.getElementById("correction-text").value.trim();
          if (!correctionText) { alert("Enter a correction"); return; }
        }
        try {
          var res = await fetch(BASE_URL, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ claim_id: currentClaimId, grade: grade, correction_text: correctionText, graded_by: "chad" }),
          });
          var data = await res.json();
          if (!data.ok) throw new Error(data.error || "Failed to save grade");
          closeGradeSheet();
          if (selectedContactId) loadThread(selectedContactId);
        } catch (e) {
          alert("Grade failed: " + e.message);
        }
      }

      document.addEventListener("click", function (e) {
        if (e.target.closest(".search-container")) return;
        var claimItem = e.target.closest(".claim-item");
        if (claimItem) { openGradeSheet(claimItem.dataset.claimId, claimItem.dataset.claimText); return; }
        var actionEl = e.target.closest("[data-action]");
        var action = actionEl ? actionEl.dataset.action : null;
        if (action === "toggle-transcript") {
          var area = actionEl.nextElementSibling;
          if (area && area.classList.contains("transcript-area")) {
            area.classList.toggle("open");
            actionEl.textContent = area.classList.contains("open")
              ? "\uD83D\uDCAC Hide Conversation"
              : "\uD83D\uDCAC Read Conversation";
          }
          return;
        }
        if (action === "grade-confirm") { submitGrade("confirm"); return; }
        if (action === "grade-reject") { submitGrade("reject"); return; }
        if (action === "grade-show-correct") { document.getElementById("correction-area").style.display = "block"; return; }
        if (action === "grade-submit-correct") { submitGrade("correct"); return; }
        if (action === "grade-cancel") { closeGradeSheet(); return; }
      });

      document.getElementById("grade-overlay").addEventListener("click", function (e) {
        if (e.target === this) closeGradeSheet();
      });

      loadContacts();
    })();
  </script>
</body>
</html>`;

// Health check — pipeline freshness (skips contacts cache, always queries fresh)
async function handleHealth(db: any, t0: number): Promise<Response> {
  const nowMs = Date.now();

  const [lastCallRes, lastSmsRes, lastInteractionRes, pendingRes, lastErrorRes] = await Promise.all([
    db.from("calls_raw")
      .select("event_at_utc")
      .eq("channel", "call")
      .not("event_at_utc", "is", null)
      .order("event_at_utc", { ascending: false })
      .limit(1)
      .single(),
    db.from("sms_messages")
      .select("sent_at")
      .order("sent_at", { ascending: false })
      .limit(1)
      .single(),
    db.from("interactions")
      .select("event_at_utc")
      .not("event_at_utc", "is", null)
      .order("event_at_utc", { ascending: false })
      .limit(1)
      .single(),
    db.from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending"),
    db.from("diagnostic_logs")
      .select("message, function_name, created_at")
      .order("created_at", { ascending: false })
      .limit(1)
      .single(),
  ]);

  const lastCallUtc = lastCallRes?.data?.event_at_utc ?? null;
  const lastSmsUtc = lastSmsRes?.data?.sent_at ?? null;
  const lastInteractionUtc = lastInteractionRes?.data?.event_at_utc ?? null;
  const pendingReviews = pendingRes?.count ?? 0;

  const callStaleMin = lastCallUtc
    ? Math.round((nowMs - new Date(lastCallUtc).getTime()) / 60_000)
    : null;
  const smsStaleMin = lastSmsUtc
    ? Math.round((nowMs - new Date(lastSmsUtc).getTime()) / 60_000)
    : null;

  const lastError = lastErrorRes?.data
    ? {
        function: lastErrorRes.data.function_name,
        message: lastErrorRes.data.message,
        at: lastErrorRes.data.created_at,
      }
    : null;

  const pipelineOk =
    callStaleMin !== null &&
    smsStaleMin !== null &&
    callStaleMin < 120 &&
    smsStaleMin < 120;

  return json({
    ok: true,
    version: FUNCTION_VERSION,
    pipeline: {
      last_call_utc: lastCallUtc,
      call_stale_minutes: callStaleMin,
      last_sms_utc: lastSmsUtc,
      sms_stale_minutes: smsStaleMin,
      last_interaction_utc: lastInteractionUtc,
      pending_reviews: pendingReviews,
      last_error: lastError,
    },
    pipeline_ok: pipelineOk,
    ms: Date.now() - t0,
  });
}

// Main router
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  const t0 = Date.now();
  const url = new URL(req.url);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  try {
    // Health check — fast path, no auth, no cache
    if (url.searchParams.get("mode") === "health") {
      return await handleHealth(db, t0);
    }

    const apiRoute = parseRedlineApiRoute(url);
    if (apiRoute) {
      if (apiRoute.kind === "contacts" && req.method === "GET") {
        return await handleContacts(db, url, t0);
      }
      if (apiRoute.kind === "thread" && req.method === "GET") {
        return await handleThreadApi(db, apiRoute.contactId, url, t0);
      }
      if (apiRoute.kind === "spans" && req.method === "GET") {
        return await handleSpansApi(db, apiRoute.contactId, url, t0);
      }
      if (apiRoute.kind === "verdict" && req.method === "POST") {
        return await handleVerdict(db, req, t0);
      }
      if (apiRoute.kind === "unknown") {
        return json({
          ok: false,
          error_code: "unknown_redline_route",
          error: `Unsupported redline API path: /redline/${apiRoute.path.join("/")}`,
          function_version: FUNCTION_VERSION,
        }, 404);
      }
      return json({
        ok: false,
        error_code: "method_not_allowed",
        error: `Method ${req.method} not allowed for redline API route`,
        function_version: FUNCTION_VERSION,
      }, 405);
    }

    if (req.method === "POST") {
      return await handleGrade(db, req, t0);
    }

    const action = url.searchParams.get("action");
    if (action === "top_candidates") {
      return await handleTopCandidates(db, url, t0);
    }
    if (action === "sanity") {
      return await handleSanity(db, t0);
    }
    if (action === "contacts") {
      return await handleContacts(db, url, t0);
    }
    if (action === "projects") {
      return await handleProjects(db, t0);
    }
    if (action === "reset_clock") {
      return await handleResetClock(db, t0);
    }
    if (action === "get_cutoff") {
      return await handleGetCutoff(db, t0);
    }

    const contactId = url.searchParams.get("contact_id");
    if (contactId) {
      const rawLimit = parseInt(url.searchParams.get("limit") || "20", 10);
      const limit = Math.min(Math.max(isNaN(rawLimit) ? 20 : rawLimit, 1), 200);
      const rawOffset = parseInt(url.searchParams.get("offset") || "0", 10);
      const offset = Math.max(isNaN(rawOffset) ? 0 : rawOffset, 0);
      return await handleThread(db, contactId, limit, offset, t0);
    }

    return new Response(HTML, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8", ...corsHeaders() },
    });
  } catch (err: any) {
    console.error("[redline-thread] Error:", err.message);
    return json(
      { ok: false, error_code: "internal_error", error: err.message, function_version: FUNCTION_VERSION },
      500,
    );
  }
});
