import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { computeTruthGraph, type TruthGraphHydration, type TruthGraphRepairAction } from "./truth_graph.ts";
import { requireEdgeSecret } from "../_shared/auth.ts";

const FUNCTION_VERSION = "redline-thread_v3.4.0";
/**
 * v3.2.1 - Fix typo interactionClaims -> _interactionClaims
 * v3.1.2 - iOS Contract Fix (P0 Unbrick)
 * - Map DB 'id' to 'span_id' and 'claim_id' for iOS compatibility
 * - Closes visibility gap for beside_threads
 * v3.3.0 - Contacts payload: add last_interaction_id instrumentation + keep beside_thread rows
 * v3.4.0 - Truth Graph endpoint + idempotent repair hooks (truth-forcing surface)
 */
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
  | { kind: "unknown"; base: string; path: string[] };

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}

function noStoreHeaders(): Record<string, string> {
  return {
    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
    "Pragma": "no-cache",
    "Expires": "0",
  };
}

function json(data: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
      ...noStoreHeaders(),
      ...extraHeaders,
    },
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

function isDuplicateKeyError(err: any): boolean {
  const msg = String(err?.message || "").toLowerCase();
  const code = String(err?.code || "");
  return code === "23505" || msg.includes("duplicate") || msg.includes("23505");
}

async function fetchJsonWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<{ ok: boolean; status: number; text: string; json: any | null }> {
  const controller = new AbortController();
  const id = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const resp = await fetch(url, { ...init, signal: controller.signal });
    const text = await resp.text().catch(() => "");
    let json: any | null = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    return { ok: resp.ok, status: resp.status, text, json };
  } finally {
    clearTimeout(id);
  }
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

// ============================================================
// Truth Graph endpoint (v0)
// GET /functions/v1/redline-thread?action=truth_graph&interaction_id=<id>
// ============================================================
async function handleTruthGraph(db: any, url: URL, t0: number): Promise<Response> {
  const interactionId = String(url.searchParams.get("interaction_id") || "").trim();
  if (!interactionId) {
    return json({
      ok: false,
      error_code: "missing_interaction_id",
      error: "interaction_id required",
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    }, 400);
  }

  const stageMs: Record<string, number> = {};
  const timeDb = async (stage: string, fn: () => Promise<any>): Promise<any> => {
    const start = performance.now();
    const result = await fn();
    stageMs[stage] = (stageMs[stage] || 0) + (performance.now() - start);
    return result;
  };

  const warnings: string[] = [];

  const { data: interactionRow, error: interactionErr } = await timeDb(
    "db_interactions",
    () => db.from("interactions").select("interaction_id, channel").eq("interaction_id", interactionId).maybeSingle(),
  );
  if (interactionErr) warnings.push(`interactions_lookup_failed:${interactionErr.message}`);

  const channel = String(interactionRow?.channel || "").trim().toLowerCase();
  const looksLikeSms = interactionId.startsWith("sms_thread_") || interactionId.startsWith("sms_thread__") ||
    channel === "sms" || channel === "text" || channel === "sms_thread";

  const [callsRawRes, spansRes, evidenceRes, claimsRes, reviewRes] = await Promise.all([
    looksLikeSms
      ? Promise.resolve({ data: [], error: null })
      : timeDb("db_calls_raw", () =>
        db.from("calls_raw").select("interaction_id").eq("interaction_id", interactionId).limit(1)),
    timeDb("db_conversation_spans", () =>
      db.from("conversation_spans")
        .select("id")
        .eq("interaction_id", interactionId)
        .eq("is_superseded", false)
        .order("span_index", { ascending: true })
        .limit(50)),
    looksLikeSms
      ? Promise.resolve({ data: [], error: null })
      : timeDb("db_evidence_events", () =>
        db.from("evidence_events")
          .select("evidence_event_id")
          .eq("source_type", "call")
          .eq("source_id", interactionId)
          .limit(1)),
    looksLikeSms
      ? Promise.resolve({ data: [], error: null })
      : timeDb("db_journal_claims", () =>
        db.from("journal_claims")
          .select("id")
          .eq("call_id", interactionId)
          .limit(1)),
    timeDb("db_review_queue", () =>
      db.from("review_queue")
        .select("id")
        .eq("interaction_id", interactionId)
        .eq("status", "pending")
        .limit(1)),
  ]);

  if (callsRawRes?.error) warnings.push(`calls_raw_query_failed:${callsRawRes.error.message}`);
  if (spansRes?.error) warnings.push(`conversation_spans_query_failed:${spansRes.error.message}`);
  if (evidenceRes?.error) warnings.push(`evidence_events_query_failed:${evidenceRes.error.message}`);
  if (claimsRes?.error) warnings.push(`journal_claims_query_failed:${claimsRes.error.message}`);
  if (reviewRes?.error) warnings.push(`review_queue_query_failed:${reviewRes.error.message}`);

  const spanIds: string[] = Array.isArray(spansRes?.data)
    ? spansRes.data.map((row: any) => String(row?.id || "")).filter((id: string) => id.length > 0)
    : [];

  let hasAttributions = false;
  if (spanIds.length > 0) {
    const { data: attrRows, error: attrErr } = await timeDb(
      "db_span_attributions",
      () => db.from("span_attributions").select("span_id").in("span_id", spanIds).limit(1),
    );
    if (attrErr) warnings.push(`span_attributions_query_failed:${attrErr.message}`);
    hasAttributions = Array.isArray(attrRows) && attrRows.length > 0;
  }

  const hydration: TruthGraphHydration = {
    calls_raw: Array.isArray(callsRawRes?.data) && callsRawRes.data.length > 0,
    interactions: Boolean(interactionRow?.interaction_id),
    conversation_spans: spanIds.length > 0,
    evidence_events: Array.isArray(evidenceRes?.data) && evidenceRes.data.length > 0,
    span_attributions: hasAttributions,
    journal_claims: Array.isArray(claimsRes?.data) && claimsRes.data.length > 0,
    review_queue: Array.isArray(reviewRes?.data) && reviewRes.data.length > 0,
  };

  const computed = computeTruthGraph(interactionId, hydration, {
    interaction_channel: interactionRow?.channel ?? null,
  });

  const totalMs = Date.now() - t0;
  const serverTiming = buildServerTimingHeader(stageMs, totalMs);

  return json(
    {
      ok: true,
      interaction_id: interactionId,
      hydration,
      lane: computed.lane,
      suggested_repairs: computed.suggested_repairs,
      warnings: [...warnings, ...computed.warnings].filter(Boolean),
      function_version: FUNCTION_VERSION,
      ms: totalMs,
    },
    200,
    serverTiming ? { "Server-Timing": serverTiming } : {},
  );
}

// ============================================================
// Repair hooks (v0)
// POST /functions/v1/redline-thread?action=repair
// Body: { interaction_id, repair_action, idempotency_key, requested_by? }
// ============================================================
async function handleRepair(db: any, req: Request, t0: number): Promise<Response> {
  const authResult = requireEdgeSecret(req, ["redline_ios"]);
  if (!authResult.ok) {
    return json({
      ok: false,
      error_code: "unauthorized",
      error: "Missing or invalid X-Edge-Secret",
      function_version: FUNCTION_VERSION,
    }, 401);
  }
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({
      ok: false,
      error_code: "invalid_json",
      error: "Invalid JSON body",
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    }, 400);
  }

  const interactionId = String(body?.interaction_id || "").trim();
  const repairAction = String(body?.repair_action || "").trim() as TruthGraphRepairAction;
  const idempotencyKey = String(body?.idempotency_key || "").trim();
  const requestedBy = String(body?.requested_by || "").trim() || "redline_ios";

  const allowedActions: TruthGraphRepairAction[] = ["repair_process_call", "repair_ai_router"];

  if (!interactionId) {
    return json({ ok: false, error_code: "missing_interaction_id", function_version: FUNCTION_VERSION }, 400);
  }
  if (!repairAction || !allowedActions.includes(repairAction)) {
    return json({
      ok: false,
      error_code: "invalid_repair_action",
      valid: allowedActions,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    }, 400);
  }
  if (!idempotencyKey) {
    return json({ ok: false, error_code: "missing_idempotency_key", function_version: FUNCTION_VERSION }, 400);
  }

  const startedAt = new Date().toISOString();

  const { data: eventRow, error: eventErr } = await db
    .from("redline_repair_events")
    .insert({
      interaction_id: interactionId,
      repair_action: repairAction,
      idempotency_key: idempotencyKey,
      requested_by: requestedBy,
      status: "started",
      started_at_utc: startedAt,
      function_version: FUNCTION_VERSION,
    })
    .select("id, status, started_at_utc, completed_at_utc")
    .single();

  if (eventErr) {
    if (isDuplicateKeyError(eventErr)) {
      const { data: existing, error: existingErr } = await db
        .from("redline_repair_events")
        .select("id, status, started_at_utc, completed_at_utc")
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();
      if (existingErr) {
        return json({
          ok: false,
          error_code: "idempotency_lookup_failed",
          error: existingErr.message,
          function_version: FUNCTION_VERSION,
          ms: Date.now() - t0,
        }, 500);
      }

      return json({
        ok: existing?.status === "succeeded" || existing?.status === "started",
        idempotent_replay: true,
        request_id: existing?.id || null,
        status: existing?.status || null,
        started_at_utc: existing?.started_at_utc || null,
        completed_at_utc: existing?.completed_at_utc || null,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }, 200);
    }

    return json({
      ok: false,
      error_code: "repair_event_insert_failed",
      error: eventErr.message,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    }, 500);
  }

  const requestId = String(eventRow?.id || "");
  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim();
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  const edgeSecret = String(Deno.env.get("EDGE_SHARED_SECRET") || "").trim();

  if (!supabaseUrl || !serviceRoleKey || !edgeSecret) {
    const detail = {
      missing: {
        SUPABASE_URL: !supabaseUrl,
        SUPABASE_SERVICE_ROLE_KEY: !serviceRoleKey,
        EDGE_SHARED_SECRET: !edgeSecret,
      },
    };
    await db.from("redline_repair_events").update({
      status: "failed",
      completed_at_utc: new Date().toISOString(),
      detail,
      error_code: "server_misconfigured",
    }).eq("id", requestId);
    return json({
      ok: false,
      error_code: "server_misconfigured",
      detail,
      request_id: requestId,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    }, 500);
  }

  let ok = false;
  let repairDetail: any = null;
  let errorCode: string | null = null;

  try {
    if (repairAction === "repair_process_call") {
      const { error: deleteErr } = await db.from("idempotency_keys").delete().eq("key", interactionId);
      if (deleteErr) {
        repairDetail = { ...(repairDetail || {}), idempotency_key_delete_error: deleteErr.message };
      }

      const { data: callRow, error: callErr } = await db
        .from("calls_raw")
        .select(
          "interaction_id, direction, transcript, event_at_utc, owner_phone, other_party_phone, recording_url, is_shadow",
        )
        .eq("interaction_id", interactionId)
        .maybeSingle();

      if (callErr) {
        errorCode = "calls_raw_lookup_failed";
        repairDetail = { error: callErr.message };
      } else if (!callRow) {
        errorCode = "calls_raw_not_found";
        repairDetail = { hint: "calls_raw row required to reconstruct process-call payload" };
      } else {
        const payload = {
          interaction_id: interactionId,
          call_id: interactionId,
          event_at_utc: callRow.event_at_utc || null,
          call_start_utc: callRow.event_at_utc || null,
          direction: callRow.direction || null,
          transcript: callRow.transcript || null,
          from_phone: callRow.owner_phone || null,
          to_phone: callRow.other_party_phone || null,
          owner_phone: callRow.owner_phone || null,
          other_party_phone: callRow.other_party_phone || null,
          recording_url: callRow.recording_url || null,
          source: "redline_repair",
          is_shadow: Boolean(callRow.is_shadow),
          _redline_repair_meta: {
            requested_by: requestedBy,
            idempotency_key: idempotencyKey,
            requested_at_utc: startedAt,
          },
        };

        const processUrl = `${supabaseUrl}/functions/v1/process-call`;
        const processResp = await fetchJsonWithTimeout(
          processUrl,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${serviceRoleKey}`,
              apikey: serviceRoleKey,
              "X-Edge-Secret": edgeSecret,
            },
            body: JSON.stringify(payload),
          },
          25_000,
        );

        ok = processResp.ok;
        repairDetail = {
          called: "process-call",
          http_status: processResp.status,
          body: processResp.json ?? processResp.text.slice(0, 1200),
        };
        if (!ok) errorCode = `process_call_http_${processResp.status}`;
      }
    }

    if (repairAction === "repair_ai_router") {
      const reseedUrl = `${supabaseUrl}/functions/v1/admin-reseed`;
      const reseedResp = await fetchJsonWithTimeout(
        reseedUrl,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${serviceRoleKey}`,
            apikey: serviceRoleKey,
            "X-Edge-Secret": edgeSecret,
            "X-Source": "system",
          },
          body: JSON.stringify({
            interaction_id: interactionId,
            reason: "redline_repair_ai_router",
            idempotency_key: idempotencyKey,
            mode: "resegment_and_reroute",
            requested_by: requestedBy,
            force: false,
          }),
        },
        30_000,
      );

      ok = reseedResp.ok;
      repairDetail = {
        called: "admin-reseed",
        http_status: reseedResp.status,
        body: reseedResp.json ?? reseedResp.text.slice(0, 1200),
      };
      if (!ok) errorCode = `admin_reseed_http_${reseedResp.status}`;
    }
  } catch (err: any) {
    ok = false;
    errorCode = "repair_exception";
    repairDetail = { error: err?.message || String(err) };
  }

  const completedAt = new Date().toISOString();
  await db.from("redline_repair_events").update({
    status: ok ? "succeeded" : "failed",
    completed_at_utc: completedAt,
    detail: repairDetail,
    error_code: errorCode,
  }).eq("id", requestId);

  return json({
    ok,
    request_id: requestId,
    interaction_id: interactionId,
    repair_action: repairAction,
    status: ok ? "succeeded" : "failed",
    started_at_utc: eventRow?.started_at_utc || startedAt,
    completed_at_utc: completedAt,
    error_code: ok ? null : errorCode,
    detail: repairDetail,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  }, ok ? 200 : 502);
}

async function fetchReviewQueueMetaByIds(
  reviewQueueIds: string[],
): Promise<Map<string, { module: string | null; reason_codes: string[] | null; reasons: string[] | null }>> {
  const out = new Map<string, { module: string | null; reason_codes: string[] | null; reasons: string[] | null }>();
  const uniqueIds = [...new Set(reviewQueueIds.filter((id) => id.length > 0))];
  if (uniqueIds.length === 0) return out;

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supabaseUrl || !serviceRoleKey) return out;

  const chunkSize = 100;
  for (let start = 0; start < uniqueIds.length; start += chunkSize) {
    const chunk = uniqueIds.slice(start, start + chunkSize);
    const inClause = `(${chunk.join(",")})`;
    const endpoint = `${supabaseUrl}/rest/v1/review_queue?select=id,module,reason_codes,reasons&id=in.${
      encodeURIComponent(inClause)
    }`;
    const resp = await fetch(endpoint, {
      method: "GET",
      headers: {
        "apikey": serviceRoleKey,
        "Authorization": `Bearer ${serviceRoleKey}`,
        "Accept": "application/json",
      },
    });
    if (!resp.ok) continue;
    const rows = await resp.json();
    if (!Array.isArray(rows)) continue;
    for (const row of rows) {
      const id = String(row?.id || "");
      if (!id) continue;
      const reasonCodes = Array.isArray(row?.reason_codes) ? row.reason_codes.filter(Boolean) : null;
      const reasons = Array.isArray(row?.reasons) ? row.reasons.filter(Boolean) : null;
      out.set(id, {
        module: String(row?.module || "").trim() || null,
        reason_codes: reasonCodes && reasonCodes.length > 0 ? reasonCodes : null,
        reasons: reasons && reasons.length > 0 ? reasons : null,
      });
    }
  }

  return out;
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

function _deduplicateSpans(spans: any[]): any[] {
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

function _extractParticipants(transcript: string | null): string[] {
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
  const value = (type: string): number => Number(parts.find((part) => part.type === type)?.value || "0");

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
  const base = parts[redlineIndex];
  if (tail.length === 0) {
    if (base === "redline-thread") return { kind: "contacts" };
    return { kind: "unknown", base, path: tail };
  }
  if (tail[0] === "contacts" && tail.length === 1) return { kind: "contacts" };
  if (tail[0] === "thread" && tail.length >= 2) return { kind: "thread", contactId: decodeURIComponent(tail[1]) };
  if (tail[0] === "spans" && tail.length >= 2) return { kind: "spans", contactId: decodeURIComponent(tail[1]) };
  if (tail[0] === "verdict" && tail.length === 1) return { kind: "verdict" };
  return { kind: "unknown", base, path: tail };
}

// Parse synthetic SMS-only contact keys like "sms:7065551234" → digits, or null
function parseSmsOnlyContactDigits(contactId: string): string | null {
  if (!contactId) return null;
  const match = contactId.match(/^sms:(\d{7,15})$/);
  return match ? match[1] : null;
}

// Generate a deterministic UUID from a phone string so iOS can decode contact.id
function deterministicUUID(input: string): string {
  let hash = 0;
  for (let i = 0; i < input.length; i++) {
    hash = ((hash << 5) - hash + input.charCodeAt(i)) | 0;
  }
  const hex = Math.abs(hash).toString(16).padStart(8, "0");
  const padded = (hex + hex + hex + hex).slice(0, 32);
  return [
    padded.slice(0, 8),
    padded.slice(8, 12),
    "4" + padded.slice(13, 16),
    "8" + padded.slice(17, 20),
    padded.slice(20, 32),
  ].join("-");
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
  const stageMs: Record<string, number> = {};
  const timeDb = async (stage: string, fn: () => Promise<any>): Promise<any> => {
    const start = performance.now();
    const result = await fn();
    stageMs[stage] = (stageMs[stage] || 0) + (performance.now() - start);
    return result;
  };
  const computeStart = performance.now();

  const { resetApplied, cutoff } = await maybeAutoResetGradingCutoff(db);
  if (resetApplied) {
    contactsCache = null;
  }

  const forceRefresh = isTruthy(url.searchParams.get("refresh"));
  if (!forceRefresh && contactsCache && contactsCache.expiresAt > Date.now()) {
    return json({
      ok: true,
      contacts: contactsCache.contacts,
      filtered_count: 0,
      cached: true,
      source: "memory_cache",
      grading_cutoff: cutoff,
      auto_reset_applied: resetApplied,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const selectColumns =
    "contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type, source";

  const contactsSource = "redline_contacts_unified_matview";
  const { data, error } = await timeDb("db_contacts", () =>
    db
      .from(contactsSource)
      .select(selectColumns)
      .order("last_activity", { ascending: false, nullsFirst: false }));

  if (error) {
    return json({ ok: false, error_code: "contacts_query_failed", error: error.message }, 500);
  }

  const mapped = (data || [])
    .filter((row: any) => row.contact_id != null)
    .map((row: any) => ({
      contact_id: row.contact_id,
      contact_key: row.contact_id ?? `sms:${(row.contact_phone || "").replace(/\D/g, "").slice(-10)}`,
      name: row.contact_name,
      phone: row.contact_phone,
      call_count: Number(row.call_count ?? 0),
      sms_count: Number(row.sms_count ?? 0),
      claim_count: Number(row.claim_count ?? 0),
      ungraded_count: Number(row.ungraded_count ?? 0),
      last_activity: row.last_activity || "",
      last_summary: deriveContactLastSummary(row) || "",
      last_direction: row.last_direction || "",
      last_interaction_type: row.last_interaction_type || "",
      last_interaction_id: "",
      source: String(row.source || "").trim() || "contacts",
    }));

  // Filter ghost rows: contact exists but has zero activity (no calls, no SMS, no last_activity)
  const liveRows = mapped.filter((row: any) =>
    row.call_count + row.sms_count > 0 ||
    (row.last_activity != null && row.last_activity !== "")
  );

  // Instrumentation: attach `last_interaction_id` from SSOT (redline_thread) so operators can
  // correlate list previews to the exact latest thread event.
  const phones = [...new Set(liveRows.map((row: any) => String(row.phone || "").trim()).filter((p: string) => p))];
  const latestByPhone = new Map<string, any>();
  if (phones.length > 0) {
    const { data: latestRows, error: latestErr } = await timeDb(
      "db_latest_thread_event",
      () => db.rpc("redline_latest_thread_event_by_phone_v1", { phone_list: phones }),
    );
    if (latestErr) {
      console.warn(`[contacts] latest thread event RPC failed: ${latestErr.message}`);
    } else if (Array.isArray(latestRows)) {
      for (const row of latestRows) {
        const phone = String(row?.contact_phone || "").trim();
        if (!phone) continue;
        latestByPhone.set(phone, row);
      }
    }
  }

  const liveRowsWithIds = liveRows.map((row: any) => {
    const phone = String(row.phone || "").trim();
    const latest = phone ? latestByPhone.get(phone) : null;
    const lastInteractionId = latest?.interaction_id != null ? String(latest.interaction_id) : "";

    const latestEventAt = latest?.event_at_utc != null ? String(latest.event_at_utc) : "";
    const latestDirection = latest?.direction != null ? String(latest.direction) : "";
    const latestTypeRaw = latest?.interaction_type != null ? String(latest.interaction_type) : "";
    const latestType = latestTypeRaw === "sms_thread" ? "sms" : latestTypeRaw;

    const latestSummaryRaw = latest?.summary != null ? String(latest.summary).trim() : "";
    const latestSummary = latestSummaryRaw.length > 0 ? latestSummaryRaw.slice(0, 80) : "";
    return {
      ...row,
      last_interaction_id: lastInteractionId,
      last_activity: latestEventAt || row.last_activity,
      last_summary: latestSummary || row.last_summary,
      last_direction: latestDirection || row.last_direction,
      last_interaction_type: latestType || row.last_interaction_type,
    };
  });

  // Validate contact_ids still exist in the contacts table (matview can lag deletes)
  const candidateIds = liveRowsWithIds
    .filter((r: any) => String(r.source || "") === "contacts")
    .map((r: any) => r.contact_id)
    .filter(Boolean);
  let validIdSet: Set<string> | null = null;
  if (candidateIds.length > 0) {
    const { data: validRows, error: validErr } = await db
      .from("contacts")
      .select("id")
      .in("id", candidateIds);
    if (!validErr && validRows) {
      validIdSet = new Set(validRows.map((r: any) => r.id));
    } else {
      console.warn(`[contacts] Contact validation query failed, skipping orphan filter: ${validErr?.message}`);
    }
  }

  const contacts = liveRowsWithIds
    .filter((row: any) =>
      String(row.source || "") !== "contacts" || validIdSet === null || validIdSet.has(row.contact_id)
    )
    .sort((a: any, b: any) => {
      const aTime = Date.parse(a.last_activity || "") || 0;
      const bTime = Date.parse(b.last_activity || "") || 0;
      if (aTime !== bTime) return bTime - aTime;
      return String(a.name || "").localeCompare(String(b.name || ""));
    });

  const filteredEmpty = mapped.length - liveRows.length;
  const filteredOrphan = validIdSet ? liveRowsWithIds.length - contacts.length : 0;
  const filteredCount = filteredEmpty + filteredOrphan;
  if (filteredEmpty > 0 || filteredOrphan > 0) {
    console.log(
      `[contacts] Filtered ${filteredCount} rows (${filteredEmpty} empty, ${filteredOrphan} orphaned)`,
    );
  }

  contactsCache = {
    expiresAt: Date.now() + CONTACTS_CACHE_TTL_MS,
    contacts,
  };

  const totalMs = Date.now() - t0;
  const dbMs = Object.entries(stageMs)
    .filter(([stage]) => stage.startsWith("db_"))
    .reduce((sum, [, ms]) => sum + ms, 0);
  const computeMs = Math.max(0, performance.now() - computeStart - dbMs);
  const serverTiming = buildServerTimingHeader({ db_ms: dbMs, compute_ms: computeMs, ...stageMs }, totalMs);

  return json(
    {
      ok: true,
      contacts,
      filtered_count: filteredCount,
      cached: false,
      source: contactsSource,
      grading_cutoff: cutoff,
      auto_reset_applied: resetApplied,
      function_version: FUNCTION_VERSION,
      ms: totalMs,
    },
    200,
    serverTiming ? { "Server-Timing": serverTiming } : {},
  );
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

async function handleTriageQueue(db: any, url: URL, t0: number): Promise<Response> {
  const stageMs: Record<string, number> = {};
  const timeDb = async (stage: string, fn: () => Promise<any>): Promise<any> => {
    const start = performance.now();
    const result = await fn();
    stageMs[stage] = (stageMs[stage] || 0) + (performance.now() - start);
    return result;
  };
  const computeStart = performance.now();

  const rawLimit = parseInt(url.searchParams.get("limit") || "100", 10);
  const limit = Math.min(Math.max(Number.isNaN(rawLimit) ? 100 : rawLimit, 1), 300);

  const [{ data: pendingRows, error: pendingErr }, { count: totalPending, error: totalErr }] = await timeDb(
    "db_pending_queue",
    () =>
      Promise.all([
        db
          .from("review_queue")
          .select("id, span_id, interaction_id, created_at, module, reason_codes, reasons")
          .eq("status", "pending")
          .order("created_at", { ascending: true, nullsFirst: false })
          .limit(limit),
        db
          .from("review_queue")
          .select("id", { count: "exact", head: true })
          .eq("status", "pending"),
      ]),
  );

  if (pendingErr) {
    return json({ ok: false, error_code: "triage_queue_query_failed", error: pendingErr.message }, 500);
  }
  if (totalErr) {
    return json({ ok: false, error_code: "triage_queue_total_failed", error: totalErr.message }, 500);
  }

  const queueRows = pendingRows || [];
  if (queueRows.length === 0) {
    return json({
      ok: true,
      items: [],
      count: 0,
      total_pending: totalPending ?? 0,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const spanIds: string[] = Array.from(
    new Set(
      queueRows
        .map((row: any) => String(row?.span_id || ""))
        .filter((value: string) => value.length > 0),
    ),
  ) as string[];
  const interactionIdsFromQueue: string[] = Array.from(
    new Set(
      queueRows
        .map((row: any) => String(row?.interaction_id || ""))
        .filter((value: string) => value.length > 0),
    ),
  ) as string[];

  const { data: spanRows, error: spanErr } = await timeDb("db_spans", () =>
    batchIn<any>(
      spanIds,
      (chunk: string[]) =>
        db
          .from("conversation_spans")
          .select("id, interaction_id, span_index, transcript_segment")
          .in("id", chunk),
    ));
  if (spanErr) {
    return json({ ok: false, error_code: "triage_spans_query_failed", error: spanErr.message }, 500);
  }
  const spanById = new Map(
    (spanRows || []).map((row: any) => [String(row?.id || ""), row]),
  );

  const interactionIds: string[] = [
    ...new Set([
      ...interactionIdsFromQueue,
      ...((spanRows || []).map((row: any) => String(row?.interaction_id || "")).filter(Boolean)),
    ]),
  ];

  const { data: interactionRows, error: interactionErr } = await timeDb("db_interactions", () =>
    batchIn<any>(
      interactionIds,
      (chunk: string[]) =>
        db
          .from("interactions")
          .select("interaction_id, contact_id, contact_name, event_at_utc, channel")
          .in("interaction_id", chunk),
    ));
  if (interactionErr) {
    return json({ ok: false, error_code: "triage_interactions_query_failed", error: interactionErr.message }, 500);
  }
  const interactionById = new Map(
    (interactionRows || []).map((row: any) => [String(row?.interaction_id || ""), row]),
  );

  const { data: attributionRows, error: attributionErr } = await timeDb("db_attributions", () =>
    batchIn<any>(
      spanIds,
      (chunk: string[]) =>
        db
          .from("span_attributions")
          .select("span_id, project_id, applied_project_id, confidence, attributed_at")
          .in("span_id", chunk)
          .order("attributed_at", { ascending: false }),
    ));
  if (attributionErr) {
    return json({ ok: false, error_code: "triage_attributions_query_failed", error: attributionErr.message }, 500);
  }
  const attributionBySpan = new Map<string, any>();
  for (const row of attributionRows || []) {
    const spanId = String(row?.span_id || "");
    if (!spanId || attributionBySpan.has(spanId)) continue;
    attributionBySpan.set(spanId, row);
  }

  const projectIds = [
    ...new Set(
      (attributionRows || [])
        .map((row: any) => String(row?.applied_project_id || row?.project_id || ""))
        .filter(Boolean),
    ),
  ];
  const { data: projectRows, error: projectErr } = await timeDb("db_projects", () =>
    batchIn<any>(
      projectIds,
      (chunk: string[]) =>
        db
          .from("projects")
          .select("id, name")
          .in("id", chunk),
    ));
  if (projectErr) {
    return json({ ok: false, error_code: "triage_projects_query_failed", error: projectErr.message }, 500);
  }
  const projectNameById = new Map(
    (projectRows || []).map((row: any) => [String(row?.id || ""), String(row?.name || "")]),
  );
  const reviewQueueMetaById = await fetchReviewQueueMetaByIds(
    queueRows.map((row: any) => String(row?.id || "")).filter(Boolean),
  );

  const items = queueRows.map((row: any) => {
    const spanId = String(row?.span_id || "");
    const span = spanById.get(spanId);
    const interactionId = String(row?.interaction_id || span?.interaction_id || "");
    const interaction = interactionById.get(interactionId);
    const attr = attributionBySpan.get(spanId);
    const suggestedProjectId = String(attr?.applied_project_id || attr?.project_id || "").trim() || null;
    const confidence = Number(attr?.confidence);
    const transcriptSnippet = String(span?.transcript_segment || "").trim();

    const meta = reviewQueueMetaById.get(String(row?.id || ""));
    const reasonCodes = Array.isArray(row?.reason_codes) && row.reason_codes.length > 0
      ? row.reason_codes.filter(Boolean)
      : (meta?.reason_codes || []);
    const reasons = Array.isArray(row?.reasons) && row.reasons.length > 0
      ? row.reasons.filter(Boolean)
      : (meta?.reasons || []);
    const moduleName = String(row?.module || "").trim() || meta?.module || null;
    const firstReason = String(reasonCodes[0] || reasons[0] || "").trim();

    return {
      review_queue_id: row.id,
      span_id: spanId || null,
      interaction_id: interactionId || null,
      reason: firstReason || null,
      reason_codes: reasonCodes.length > 0 ? reasonCodes : null,
      reasons: reasons.length > 0 ? reasons : null,
      module: moduleName,
      created_at: row?.created_at || null,
      contact_id: interaction?.contact_id || null,
      contact_name: interaction?.contact_name || "Unknown contact",
      channel: interaction?.channel || null,
      transcript_snippet: transcriptSnippet || null,
      suggested_project_id: suggestedProjectId,
      suggested_project_name: suggestedProjectId ? (projectNameById.get(suggestedProjectId) || null) : null,
      confidence: Number.isFinite(confidence) ? confidence : null,
    };
  });

  const totalMs = Date.now() - t0;
  const dbMs = Object.entries(stageMs)
    .filter(([stage]) => stage.startsWith("db_"))
    .reduce((sum, [, ms]) => sum + ms, 0);
  const computeMs = Math.max(0, performance.now() - computeStart - dbMs);
  const serverTiming = buildServerTimingHeader({ db_ms: dbMs, compute_ms: computeMs, ...stageMs }, totalMs);

  return json(
    {
      ok: true,
      items,
      count: items.length,
      total_pending: totalPending ?? items.length,
      function_version: FUNCTION_VERSION,
      ms: totalMs,
    },
    200,
    serverTiming ? { "Server-Timing": serverTiming } : {},
  );
}

async function handleUndoVerdict(db: any, req: Request, t0: number): Promise<Response> {
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
  if (!reviewQueueId || !isValidUUID(reviewQueueId)) {
    return json(
      { ok: false, error_code: "missing_review_queue_id", error: "review_queue_id required (uuid)" },
      400,
    );
  }

  const { data: row, error: rowErr } = await db
    .from("review_queue")
    .select("id, status")
    .eq("id", reviewQueueId)
    .maybeSingle();

  if (rowErr) {
    return json({ ok: false, error_code: "undo_lookup_failed", error: rowErr.message }, 500);
  }
  if (!row) {
    return json({ ok: false, error_code: "review_queue_not_found" }, 404);
  }
  if (row.status === "pending") {
    return json({
      ok: true,
      review_queue_id: reviewQueueId,
      status: "pending",
      already_pending: true,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const { error: undoErr } = await db
    .from("review_queue")
    .update({
      status: "pending",
      resolved_at: null,
      resolved_by: null,
    })
    .eq("id", reviewQueueId);

  if (undoErr) {
    return json({ ok: false, error_code: "undo_update_failed", error: undoErr.message }, 500);
  }

  return json({
    ok: true,
    review_queue_id: reviewQueueId,
    status: "pending",
    undone: true,
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
      .not("interaction_id", "like", "cll_VP_BYPASS_TEST_%")
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

  const { data: contactRow, error: contactErr } = await timeDb("db_contact", () =>
    db
      .from("redline_contacts_unified_matview")
      .select("contact_id, contact_name, contact_phone")
      .eq("contact_id", contactId)
      .single());

  let resolvedContact = contactRow;
  const smsOnlyDigits = parseSmsOnlyContactDigits(contactId);

  // SMS-only contact fallback: look up name/phone from sms_messages
  if (!resolvedContact && smsOnlyDigits) {
    const smsPhoneVariants = buildPhoneVariants(smsOnlyDigits);
    let lookupQuery = db
      .from("sms_messages")
      .select("contact_name, contact_phone")
      .not("contact_phone", "is", null)
      .order("sent_at", { ascending: false, nullsFirst: false })
      .limit(1);
    if (smsPhoneVariants.length === 1) {
      lookupQuery = lookupQuery.eq("contact_phone", smsPhoneVariants[0]);
    } else if (smsPhoneVariants.length > 1) {
      lookupQuery = lookupQuery.in("contact_phone", smsPhoneVariants);
    }
    const { data: smsRows } = await timeDb(
      "db_sms_contact_fallback",
      () => lookupQuery,
    );
    if (smsRows && smsRows.length > 0) {
      const latest = smsRows[0];
      resolvedContact = {
        contact_id: deterministicUUID("sms:" + smsOnlyDigits),
        contact_name: String(latest?.contact_name || "").trim() || smsOnlyDigits,
        contact_phone: String(latest?.contact_phone || "").trim() || smsOnlyDigits,
      };
    }
  }

  if (!resolvedContact) {
    return json(
      { ok: false, error_code: "contact_not_found", error: contactErr?.message || "not found" },
      404,
    );
  }
  // Re-bind contact to the resolved value; ensure phone is never null (iOS non-optional)
  const contact = {
    ...resolvedContact,
    contact_phone: resolvedContact.contact_phone || "",
  };
  const contactPhoneVariants = buildPhoneVariants(contact.contact_phone);

  const scanWindow = Math.min(Math.max(offset + limit + 20, 40), 120);
  const queryPageSize = 40;

  // Parallel 1: Get interactions and probe for SMS
  const [interactionsRes, inboundProbeRes] = await Promise.all([
    timeDb("db_interactions_all", async () => {
      let results: any[] = [];
      let from = 0;
      while (results.length < scanWindow) {
        const to = from + queryPageSize - 1;
        const { data, error } = await db
          .from("interactions")
          .select("id, interaction_id, event_at_utc, human_summary, contact_name, is_shadow")
          .eq("contact_id", contactId)
          .or("channel.eq.call,channel.eq.phone,channel.is.null")
          .or("is_shadow.is.false,is_shadow.is.null")
          .not("interaction_id", "like", "cll_SHADOW_%")
          .not("interaction_id", "like", "cll_VP_BYPASS_TEST_%")
          .not("event_at_utc", "is", null)
          .order("event_at_utc", { ascending: false })
          .range(from, to);
        if (error) throw error;
        if (!data || data.length === 0) break;
        results = results.concat(data);
        if (data.length < queryPageSize) break;
        from += queryPageSize;
      }
      return results.slice(0, scanWindow);
    }),
    timeDb("db_sms_inbound_probe", () => {
      let query = db.from("sms_messages").select("id").eq("direction", "inbound").limit(1);
      if (contactPhoneVariants.length === 1) query = query.eq("contact_phone", contactPhoneVariants[0]);
      else if (contactPhoneVariants.length > 1) query = query.in("contact_phone", contactPhoneVariants);
      else query = query.eq("contact_phone", "__no_match__");
      return query;
    }),
  ]);

  const allInteractions = interactionsRes;
  const hasInboundSms = (inboundProbeRes.data || []).length > 0;

  // Parallel 2: Get SMS messages (if needed)
  let allSmsMessages: any[] = [];
  if (hasInboundSms) {
    allSmsMessages = await timeDb("db_sms_messages_all", async () => {
      let results: any[] = [];
      let from = 0;
      while (results.length < scanWindow) {
        const to = from + queryPageSize - 1;
        let query = db
          .from("sms_messages")
          .select("id, sent_at, content, direction, contact_name, contact_phone, sender_user_id")
          .order("sent_at", { ascending: false })
          .range(from, to);
        if (contactPhoneVariants.length === 1) query = query.eq("contact_phone", contactPhoneVariants[0]);
        else if (contactPhoneVariants.length > 1) query = query.in("contact_phone", contactPhoneVariants);
        else query = query.eq("contact_phone", "__no_match__");
        const { data, error } = await query;
        if (error) throw error;
        if (!data || data.length === 0) break;
        results = results.concat(data);
        if (data.length < queryPageSize) break;
        from += queryPageSize;
      }
      return results.slice(0, scanWindow);
    });
  }

  // Interleave and page
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
        smsMessages.sort((a: any, b: any) => (Date.parse(b.sent_at) || 0) - (Date.parse(a.sent_at) || 0));
      }
    }
  }

  const timeline = [
    ...allInteractions.map((i: any) => ({ kind: "call", key: i.interaction_id, event_at: i.event_at_utc })),
    ...smsMessages.filter((s: any) => !!s.sent_at).map((s: any) => ({ kind: "sms", key: s.id, event_at: s.sent_at })),
  ].sort((a: any, b: any) => (Date.parse(b.event_at) || 0) - (Date.parse(a.event_at) || 0));

  const pagedTimeline = timeline.slice(offset, offset + limit);
  if (pagedTimeline.length === 0) {
    return json({
      ok: true,
      contact: { id: contact.contact_id, name: contact.contact_name, phone: contact.contact_phone || "" },
      thread: [],
      pagination: { limit, offset, total: timeline.length },
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const pagedCallIds = Array.from(new Set(pagedTimeline.filter((e: any) => e.kind === "call").map((e: any) => e.key)));
  const pagedSmsMessages = smsMessages.filter((s: any) =>
    pagedTimeline.some((e) => e.kind === "sms" && e.key === s.id)
  );

  // Parallel 3: Fetch all details for paged items
  const [callsRawRes, spansRes, claimsRes, pendingSmsRes] = await Promise.all([
    pagedCallIds.length > 0
      ? timeDb(
        "db_calls_raw",
        () => db.from("calls_raw").select("interaction_id, direction, transcript").in("interaction_id", pagedCallIds),
      )
      : { data: [] },
    pagedCallIds.length > 0
      ? timeDb(
        "db_conversation_spans",
        () =>
          batchIn<any>(pagedCallIds, (chunk) =>
            db.from("conversation_spans").select("id, interaction_id, span_index, transcript_segment, word_count").in(
              "interaction_id",
              chunk,
            ).eq("is_superseded", false)),
      )
      : { data: [] },
    pagedCallIds.length > 0
      ? timeDb(
        "db_journal_claims",
        () =>
          batchIn<any>(pagedCallIds, (chunk) =>
            db.from("journal_claims").select("id, call_id, source_span_id, claim_type, claim_text, speaker_label").in(
              "call_id",
              chunk,
            )),
      )
      : { data: [] },
    pagedSmsMessages.length > 0
      ? timeDb("db_pending_sms_reviews", () => {
        const keys = [...new Set(pagedSmsMessages.flatMap((s) => deriveSmsInteractionKeys(s, contact.contact_phone)))];
        return db.from("review_queue").select("id, interaction_id, created_at").eq("status", "pending").in(
          "interaction_id",
          keys,
        );
      })
      : { data: [] },
  ]);

  const spanIds = (spansRes.data || []).map((s: any) => s.id);
  const claimIds = (claimsRes.data || []).map((c: any) => c.id);

  // Parallel 4: Fetch deep details
  const [attrRes, pendingSpansRes, gradesRes] = await Promise.all([
    spanIds.length > 0
      ? timeDb(
        "db_span_attributions",
        () =>
          batchIn<any>(spanIds, (chunk) =>
            db.from("span_attributions").select("span_id, project_id, applied_project_id, confidence").in(
              "span_id",
              chunk,
            )),
      )
      : { data: [] },
    spanIds.length > 0
      ? timeDb(
        "db_pending_span_reviews",
        () =>
          batchIn<any>(spanIds, (chunk) =>
            db.from("review_queue").select("id, span_id, interaction_id, created_at").eq("status", "pending").in(
              "span_id",
              chunk,
            )),
      )
      : { data: [] },
    claimIds.length > 0
      ? timeDb(
        "db_claim_grades",
        () =>
          batchIn<any>(claimIds, (chunk) =>
            db.from("claim_grades").select("claim_id, grade, correction_text, graded_by").in("claim_id", chunk)),
      )
      : { data: [] },
  ]);

  // Map everything back
  const directionMap = new Map((callsRawRes.data || []).map((c: any) => [c.interaction_id, c.direction]));
  const _transcriptMap = new Map((callsRawRes.data || []).map((c: any) => [c.interaction_id, c.transcript]));
  const spansPerInteraction = groupBy(spansRes.data || [], (s: any) => s.interaction_id);
  const attrBySpan = new Map((attrRes.data || []).map((a: any) => [a.span_id, a]));
  const pendingBySpan = new Map((pendingSpansRes.data || []).map((p: any) => [p.span_id, p]));
  const gradeByClaim = new Map((gradesRes.data || []).map((g: any) => [g.claim_id, g]));
  const claimsByCall = groupBy(claimsRes.data || [], (c: any) => c.call_id);
  const pendingSmsByInteraction = new Map((pendingSmsRes.data || []).map((p: any) => [p.interaction_id, p]));

  // Project names fetch
  const projectIds = [
    ...new Set((attrRes.data || []).map((a: any) => a.applied_project_id || a.project_id).filter(Boolean)),
  ];
  const projectNamesRes = projectIds.length > 0
    ? await timeDb("db_projects", () => db.from("projects").select("id, name").in("id", projectIds))
    : { data: [] };
  const projectNameById = new Map((projectNamesRes.data || []).map((p: any) => [p.id, p.name]));

  const callEntries = allInteractions.filter((i: any) => pagedCallIds.includes(i.interaction_id)).map((i: any) => {
    const interactionClaims = (claimsByCall.get(i.interaction_id) || []).map((c: any) => {
      const g = gradeByClaim.get(c.id);
      return {
        ...c,
        claim_id: c.id,
        grade: g?.grade,
        correction_text: g?.correction_text,
        graded_by: g?.graded_by,
      };
    });
    return {
      type: "call",
      interaction_id: i.interaction_id,
      event_at: i.event_at_utc,
      direction: directionMap.get(i.interaction_id),
      summary: i.human_summary,
      contact_name: i.contact_name || contact.contact_name,
      spans: (spansPerInteraction.get(i.interaction_id) || []).map((s: any) => {
        const attr = attrBySpan.get(s.id);
        return {
          ...s,
          span_id: s.id,
          review_queue_id: pendingBySpan.get(s.id)?.id,
          project_name: projectNameById.get(attr?.applied_project_id || attr?.project_id),
          confidence: attr?.confidence,
        };
      }),
      claims: interactionClaims,
    };
  });

  const smsEntries = pagedSmsMessages.map((s: any) => {
    const reviewQueueId = deriveSmsInteractionKeys(s, contact.contact_phone).map((k) => pendingSmsByInteraction.get(k))
      .find((p) => !!p)?.id;
    return {
      type: "sms",
      sms_id: s.id,
      event_at: s.sent_at,
      direction: s.direction,
      content: s.content,
      review_queue_id: reviewQueueId,
      needs_attribution: !!reviewQueueId,
    };
  });

  const thread = [...callEntries, ...smsEntries].sort((a, b) =>
    new Date(a.event_at).getTime() - new Date(b.event_at).getTime()
  );

  const totalMs = Date.now() - t0;
  const dbMs = Object.entries(stageMs).filter(([s]) => s.startsWith("db_")).reduce((sum, [, ms]) => sum + ms, 0);
  const computeMs = Math.max(0, performance.now() - computeStart - dbMs);
  const serverTiming = buildServerTimingHeader({ db_ms: dbMs, compute_ms: computeMs, ...stageMs }, totalMs);

  return json(
    {
      ok: true,
      contact: { id: contact.contact_id, name: contact.contact_name, phone: contact.contact_phone || "" },
      thread,
      pagination: { limit, offset, total: timeline.length },
      function_version: FUNCTION_VERSION,
      ms: totalMs,
    },
    200,
    { "Server-Timing": serverTiming },
  );
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
    .from("redline_contacts_unified_matview")
    .select("contact_id, contact_name, contact_phone")
    .eq("contact_id", contactId)
    .maybeSingle();

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
      .not("interaction_id", "like", "cll_VP_BYPASS_TEST_%")
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
      contact: { id: contact.contact_id, name: contact.contact_name, phone: contact.contact_phone || "" },
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

  const projectIds = [
    ...new Set(
      (spanAttributions || [])
        .map((row: any) => String(row?.applied_project_id || row?.project_id || ""))
        .filter((value: string) => value.length > 0),
    ),
  ];
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
      contact_id: contact.contact_id,
      contact_name: interaction?.contact_name || contact.contact_name,
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
    contact: { id: contact.contact_id, name: contact.contact_name, phone: contact.contact_phone || "" },
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
    const status = resolved?.error === "review_queue_item_not_found"
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
const _ICON_180 =
  "iVBORw0KGgoAAAANSUhEUgAAALQAAAC0CAYAAAA9zQYyAAAHN0lEQVR4nO3d32tk5R3H8c+ZmcxkJpmdTEhMd7Puxeq67I2CRUQsiFTx1uJCKVIvLLrYXvRG7EVB8Mc/oMVSXV2oiOKqvagWlhYRUdtSSr3o0tZa67a4m6zZZDI7M2cyk5xzeiErpTWa5JnNec73vF+Qyzl5MnnzcObMeZ4TSEoEGFFIewDAKBE0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKQQNUwgaphA0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKaW0B+CDQNI3JiZ0Vbm8629ILGmQJBrEsZajSAsbG/rXcKh+kuzySGwIJOX+nXtsbk7faTTSHsbnIkn/HA71hzDUW72e3gtDrRP4luQ+6IKk04cOqRwEaQ9lU8tRpJPttk60WmpFUdrD8Vrug64XCnr/6qvTHsaWdONYTy0v67lWS3Hag/FU7j8U+jsv/7/JQkE/mp3VS1deqbkSH3++SO6DzqKvV6t67cABXVOppD0U7xB0Rn2tVNLz+/frwNhY2kPxCkFn2EyxqGfn51Ut8G+8hHci4w6Wy3p4djbtYXiDoA042mjouvHxtIfhBYI2IJD04MxM2sPwAkEbcVOtpsNc9SBoS+7asyftIaSOoEcgljRMkm39XA63TU5eluNmCV83OfpNt6sfLixsO9JiEKhZKOjI+LhuqdV0V6OhuuPltwNjY9pXKuncxobTcbKMGdrR78JwRzNulCS6EEV6p9fT40tLuv3jj/X7MHQez7U5v9pB0I5GdfJwIYp07Nw5nRkOnY5zKOcfDAnaI7041lMrK07H2Jvzm5YI2jO/7nadbg2dIWj4pBfHTqcdVY8XKuwGgvaQy6qU8ZzfqJTvv95TYbzzk468/0Pz/vfDGIKGKQQNUwgaphA0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKQQNUwgaphA0TCFomELQMIWgYQpBwxSChikEDVMIGqYQNEwhaJhC0DCFoGEKQcMUgoYpBA1TCBqmEDRMIWiYQtAwhaBhCkHDFIKGKQQNUwgaphA0TCFomELQMOU/hcvt+Vd481YAAAAASUVORK5CYII=";

const _ICON_192 =
  "iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAYAAABS3GwHAAAHp0lEQVR4nO3dT4ic9R3H8c8zf5edfWZ3JtkYs1C3CsWCQm7ioR70YhOoSm0pRGoVNNaTNw+9KD2UIkhDD7ZJwHqQCiIWPYSqQS9KaUshVPqHRoxsYsi6M7OTmdmZzD4zTw9eHJxsdn1+w/Pn+37d99kvO/vmeZ55fs/zeJJCAUbl4h4AiBMBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwLRC3AMk1a2lko76vpYLBXkxzTAKQ/XDUP3xWOtBoMtBoPPDoS5tb8c0UfZ4ksK4h0iabxWLOrO6qrIX17/+zjZHI/2t39f7vZ7e7XbVGo3iHim1CGCKJ2o1Pbu8HPcYuzIMQ53pdHSq1dJ/rl2Le5zU4Rxgin2F9BwZljxPD1SreuuWW/TCwYOq5fNxj5QqBDBFMg98dpaT9FC1qjOrq7qnUol7nNQggIzZn8/r1MqKHllainuUVCCADMpLeu7AAf2sVot7lMQjgAz7xfKy7vf9uMdINALIMF/Sr266SSvFYtyjJBYBZJyfy+mXBw7IPUaCAACShAAAhAQAAISEAACSEgAAkJAAAICEBAAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQ==";

const _ICON_512 =
  "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAXbUlEQVR4nO3de4yld13H8e+ZM2dmzs7s7Ozvfda2DoEAobTgqCJAgwq9qCRSsFIoBaVuTHwhuEKibap8lapS1EaldakqggNyTMBCKQWKrFwELimVSeQkmGJhJQ12cNhdh7t3zs7O3C9nTg9eHJxsdn1+w/Pn+37d99kvO/vmeZ55fs/zeJJCAUbl4h4AiBMBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwDQCgGkEANMIAKYRAEwjAJhGADCNAGAaAcA0AoBpBADTCACmEQBMIwCYRgAwjQBgGgHANAKAaQQA0wgAphEATCMAmEYAMI0AYBoBwLRC3AMk1a2lko76vpYLBXkxzTAKQ/XDUP3xWOtBoMtBoPPDoS5tb8c0UfZ4ksK4h0iabxWLOrO6qrIX17/+zjZHI/2t39f7vZ7e7XbVGo3iHim1CGCKJ2o1Pbu8HPcYuzIMQ53pdHSq1dJ/rl2Le5zU4Rxgin2F9BwZljxPD1SreuuWW/TCwYOq5fNxj5QqBDBFMg98dpaT9FC1qjOrq7qnUol7nNQggIzZn8/r1MqKHllainuUVCCADMpLeu7AAf2sVot7lMQjgAz7xfKy7vf9uMdINALIMF/Sr266SSvFYtyjJBYBZJyfy+mXBw7IPUaCAACShAAAhAQAAISEAACSEgAAkJAAAICEBAAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQAASEgAAEBCAgAAEhIAAJCQAACAhAQAACQkAAEhIAABAQgIAABISAACQkAAAgIQEAAAkJAAAICEBAAAJCQ==";

// HTML UI — Modern multi-view PWA (Contacts, Thread, Triage)
const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover" />
  <title>Redline</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #000000;
      --surface: #121212;
      --surface-2: #1c1c1e;
      --text: #ffffff;
      --muted: #8e8e93;
      --border: #2c2c2e;
      --accent: #0a84ff;
      --danger: #ff453a;
      --success: #32d74b;
      --warning: #ffd60a;
      --radius: 12px;
      --safe-top: env(safe-area-inset-top);
      --safe-bottom: env(safe-area-inset-bottom);
    }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.4;
      overflow-x: hidden;
    }
    #app {
      display: flex;
      flex-direction: column;
      min-height: 100dvh;
      padding-top: var(--safe-top);
      padding-bottom: var(--safe-bottom);
    }
    
    /* Navigation Bar */
    header {
      position: sticky;
      top: 0;
      z-index: 100;
      background: rgba(0, 0, 0, 0.8);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      border-bottom: 0.5px solid var(--border);
      padding: 12px 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      min-height: 54px;
    }
    .nav-left, .nav-right { flex: 1; display: flex; align-items: center; }
    .nav-right { justify-content: flex-end; }
    .nav-center { flex: 2; text-align: center; font-weight: 700; font-size: 17px; }
    
    .btn-nav {
      background: none;
      border: none;
      color: var(--accent);
      font-size: 17px;
      padding: 0;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 4px;
    }
    .btn-nav:disabled { color: var(--muted); opacity: 0.5; }

    /* Views */
    .view { display: none; flex: 1; flex-direction: column; }
    .view.active { display: flex; }

    /* Contact List */
    .list-container { flex: 1; }
    .list-row {
      display: flex;
      padding: 12px 16px;
      border-bottom: 0.5px solid var(--border);
      cursor: pointer;
      text-decoration: none;
      color: inherit;
      position: relative;
    }
    .list-row:active { background: var(--surface-2); }
    .avatar {
      width: 48px;
      height: 48px;
      border-radius: 50%;
      background: #333;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: 600;
      font-size: 18px;
      margin-right: 12px;
      flex-shrink: 0;
    }
    .content-wrap { flex: 1; min-width: 0; }
    .row-top { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 2px; }
    .contact-name { font-weight: 600; font-size: 16px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .row-time { font-size: 14px; color: var(--muted); margin-left: 8px; flex-shrink: 0; }
    .row-preview {
      font-size: 14px;
      color: var(--muted);
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      overflow: hidden;
      line-height: 1.3;
    }
    .unread-dot {
      width: 10px;
      height: 10px;
      background: var(--accent);
      border-radius: 50%;
      position: absolute;
      left: 4px;
      top: 31px;
    }

    /* Thread View */
    .message-list { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
    .bubble {
      max-width: 85%;
      padding: 10px 14px;
      border-radius: 18px;
      font-size: 16px;
      position: relative;
      word-wrap: break-word;
    }
    .bubble.inbound {
      align-self: flex-start;
      background: var(--surface-2);
      border-bottom-left-radius: 4px;
    }
    .bubble.outbound {
      align-self: flex-end;
      background: var(--accent);
      color: white;
      border-bottom-right-radius: 4px;
    }
    .bubble.call {
      align-self: center;
      background: transparent;
      border: 1px solid var(--border);
      color: var(--muted);
      font-size: 13px;
      text-align: center;
      border-radius: 10px;
      max-width: 90%;
    }
    .bubble-meta { font-size: 11px; margin-top: 4px; opacity: 0.7; }
    
    /* Triage View (Existing logic preservation) */
    #triage-card {
      margin: 16px;
      background: var(--surface-2);
      border-radius: var(--radius);
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    #triage-snippet {
      background: rgba(0,0,0,0.2);
      border-radius: 8px;
      padding: 12px;
      font-size: 15px;
      min-height: 120px;
      white-space: pre-wrap;
    }
    .triage-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
    .btn-triage {
      padding: 12px;
      border-radius: 10px;
      border: none;
      font-weight: 600;
      font-size: 15px;
      cursor: pointer;
    }
    .btn-accept { background: var(--success); color: black; }
    .btn-reject { background: var(--danger); color: white; }
    .btn-skip { background: var(--muted); color: white; }
    .btn-undo { background: var(--warning); color: black; }

    /* Utilities */
    .loading { padding: 40px; text-align: center; color: var(--muted); }
    .empty { padding: 40px; text-align: center; color: var(--muted); }
    #toast {
      position: fixed;
      left: 50%;
      bottom: calc(20px + var(--safe-bottom));
      transform: translateX(-50%);
      background: rgba(30, 30, 30, 0.95);
      padding: 10px 20px;
      border-radius: 20px;
      font-size: 14px;
      z-index: 1000;
      display: none;
    }
  </style>
</head>
<body>
  <div id="app">
    <header>
      <div class="nav-left">
        <button id="btn-back" class="btn-nav" style="display:none">Back</button>
        <button id="btn-refresh" class="btn-nav">Refresh</button>
      </div>
      <div class="nav-center" id="nav-title">Redline</div>
      <div class="nav-right">
        <button id="btn-triage-toggle" class="btn-nav">Triage</button>
      </div>
    </header>

    <div id="view-contacts" class="view active">
      <div id="contact-list" class="list-container">
        <div class="loading">Loading contacts…</div>
      </div>
    </div>

    <div id="view-thread" class="view">
      <div id="message-list" class="message-list">
        <div class="loading">Loading thread…</div>
      </div>
    </div>

    <div id="view-triage" class="view">
      <div id="triage-card">
        <div style="display:flex; justify-content:space-between; font-size:13px; color:var(--muted)">
          <span id="triage-pos">0 / 0</span>
          <span id="triage-contact">Loading…</span>
        </div>
        <div id="triage-snippet"></div>
        <div id="triage-chips" style="display:flex; flex-wrap:wrap; gap:6px"></div>
        <div class="triage-actions">
          <button id="triage-accept" class="btn-triage btn-accept">Accept (A)</button>
          <button id="triage-reject" class="btn-triage btn-reject">Reject (X)</button>
          <button id="triage-skip" class="btn-triage btn-muted" style="grid-column: span 2">Skip (Space)</button>
          <button id="triage-undo" class="btn-triage btn-warning" style="grid-column: span 2">Undo (U)</button>
        </div>
      </div>
      <div id="triage-empty" class="empty" style="display:none">No pending items.</div>
    </div>
  </div>

  <div id="toast"></div>

  <script>
    (function() {
      const BASE = window.location.origin + window.location.pathname;
      const S = {
        view: 'contacts',
        contacts: [],
        items: [],
        idx: 0,
        currentThread: null,
        busy: false,
        lastAction: null
      };

      function toast(msg) {
        const el = document.getElementById('toast');
        el.textContent = msg;
        el.style.display = 'block';
        clearTimeout(toast._t);
        toast._t = setTimeout(() => el.style.display = 'none', 2000);
      }

      function relTime(dateStr) {
        if (!dateStr) return '';
        const date = new Date(dateStr);
        const now = new Date();
        const diff = (now - date) / 1000;
        if (diff < 60) return 'now';
        if (diff < 3600) return Math.floor(diff / 60) + 'm';
        if (diff < 86400) return Math.floor(diff / 3600) + 'h';
        if (diff < 604800) return Math.floor(diff / 86400) + 'd';
        return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
      }

      function showView(viewName) {
        S.view = viewName;
        document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
        document.getElementById('view-' + viewName).classList.add('active');
        
        const back = document.getElementById('btn-back');
        const refresh = document.getElementById('btn-refresh');
        const triage = document.getElementById('btn-triage-toggle');
        const title = document.getElementById('nav-title');

        if (viewName === 'contacts') {
          back.style.display = 'none';
          refresh.style.display = 'block';
          triage.style.display = 'block';
          triage.textContent = 'Triage';
          title.textContent = 'Redline';
          loadContacts();
        } else if (viewName === 'thread') {
          back.style.display = 'block';
          refresh.style.display = 'none';
          triage.style.display = 'none';
          title.textContent = S.currentThread?.name || 'Thread';
        } else if (viewName === 'triage') {
          back.style.display = 'block';
          refresh.style.display = 'none';
          triage.style.display = 'none';
          title.textContent = 'Triage';
          loadTriage();
        }
      }

      async function loadContacts() {
        const listEl = document.getElementById('contact-list');
        const res = await fetch(BASE + '?action=contacts&refresh=1');
        const data = await res.json();
        if (!data.ok) return toast('Failed to load contacts');
        S.contacts = data.contacts;
        
        if (S.contacts.length === 0) {
          listEl.innerHTML = '<div class="empty">No active contacts.</div>';
          return;
        }

        listEl.innerHTML = S.contacts.map(c => \`
          <div class="list-row" onclick="window.app.openThread('\${c.contact_id}', '\${c.name}')">
            \${c.ungraded_count > 0 ? '<div class="unread-dot"></div>' : ''}
            <div class="avatar">\${(c.name || 'U')[0]}</div>
            <div class="content-wrap">
              <div class="row-top">
                <div class="contact-name">\${c.name || c.phone || 'Unknown'}</div>
                <div class="row-time">\${relTime(c.last_activity)}</div>
              </div>
              <div class="row-preview">\${c.last_summary || 'No messages'}</div>
            </div>
          </div>
        \`).join('');
      }

      async function loadThread(contactId) {
        const listEl = document.getElementById('message-list');
        listEl.innerHTML = '<div class="loading">Loading messages…</div>';
        const res = await fetch(BASE + '?contact_id=' + contactId + '&limit=100');
        const data = await res.json();
        if (!data.ok) return toast('Failed to load thread');
        
        listEl.innerHTML = data.thread.map(m => {
          if (m.type === 'call') {
            return \`<div class="bubble call">
              Call \${m.direction === 'inbound' ? 'from' : 'to'} \${m.contact_name}<br/>
              \${m.summary || 'No summary'}<br/>
              <span class="bubble-meta">\${relTime(m.event_at)}</span>
            </div>\`;
          }
          const cls = m.direction === 'inbound' ? 'inbound' : 'outbound';
          return \`<div class="bubble \${cls}">
            \${m.content}
            <div class="bubble-meta">\${relTime(m.event_at)}</div>
          </div>\`;
        }).join('');
        
        window.scrollTo(0, document.body.scrollHeight);
      }

      async function loadTriage() {
        if (S.items.length > 0) return renderTriage();
        const res = await fetch(BASE + "?action=triage_queue&limit=200");
        const data = await res.json();
        if (!data.ok) return toast('Triage load failed');
        S.items = data.items || [];
        S.idx = 0;
        renderTriage();
      }

      function renderTriage() {
        const card = document.getElementById('triage-card');
        const empty = document.getElementById('triage-empty');
        const item = S.items[S.idx];

        if (!item) {
          card.style.display = 'none';
          empty.style.display = 'block';
          return;
        }
        card.style.display = 'flex';
        empty.style.display = 'none';

        document.getElementById('triage-pos').textContent = (S.idx + 1) + ' / ' + S.items.length;
        document.getElementById('triage-contact').textContent = item.contact_name;
        document.getElementById('triage-snippet').textContent = item.transcript_snippet || '(No transcript)';
        
        const chips = document.getElementById('triage-chips');
        chips.innerHTML = \`<span style="background:var(--surface); padding:4px 8px; border-radius:6px; font-size:11px">Suggested: \${item.suggested_project_name || 'None'}</span>\`;
        
        document.getElementById('triage-accept').disabled = !item.suggested_project_id;
      }

      async function triageAction(verdict) {
        const item = S.items[S.idx];
        if (!item || S.busy) return;
        S.busy = true;
        
        const body = { review_queue_id: item.review_queue_id, verdict, user_id: 'chad', source: 'redline' };
        if (verdict === 'assign') body.project_id = item.suggested_project_id;
        
        const res = await fetch(BASE + '/redline/verdict', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body)
        });
        const data = await res.json();
        S.busy = false;
        if (!data.ok) return toast('Action failed');
        
        S.lastAction = { kind: verdict, item: S.items.splice(S.idx, 1)[0] };
        if (S.idx >= S.items.length) S.idx = Math.max(0, S.items.length - 1);
        renderTriage();
        toast(verdict.toUpperCase());
      }

      // Public API for HTML
      window.app = {
        openThread: (id, name) => {
          S.currentThread = { id, name };
          showView('thread');
          loadThread(id);
        }
      };

      document.getElementById('btn-back').onclick = () => showView('contacts');
      document.getElementById('btn-refresh').onclick = () => loadContacts();
      document.getElementById('btn-triage-toggle').onclick = () => showView('triage');
      
      document.getElementById('triage-accept').onclick = () => triageAction('assign');
      document.getElementById('triage-reject').onclick = () => triageAction('dismiss');
      document.getElementById('triage-skip').onclick = () => {
        const item = S.items.splice(S.idx, 1)[0];
        S.items.push(item);
        if (S.idx >= S.items.length) S.idx = 0;
        renderTriage();
      };
      document.getElementById('triage-undo').onclick = async () => {
        if (!S.lastAction || S.busy) return;
        S.busy = true;
        const res = await fetch(BASE + '?action=undo_verdict', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ review_queue_id: S.lastAction.item.review_queue_id })
        });
        const data = await res.json();
        S.busy = false;
        if (!data.ok) return toast('Undo failed');
        S.items.splice(S.idx, 0, S.lastAction.item);
        S.lastAction = null;
        renderTriage();
        toast('UNDONE');
      };

      document.addEventListener('keydown', (e) => {
        if (S.view !== 'triage') return;
        if (e.key === 'a') document.getElementById('triage-accept').click();
        if (e.key === 'x') document.getElementById('triage-reject').click();
        if (e.key === 'u') document.getElementById('triage-undo').click();
        if (e.code === 'Space') document.getElementById('triage-skip').click();
      });

      showView('contacts');
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

  const callStaleMin = lastCallUtc ? Math.round((nowMs - new Date(lastCallUtc).getTime()) / 60_000) : null;
  const smsStaleMin = lastSmsUtc ? Math.round((nowMs - new Date(lastSmsUtc).getTime()) / 60_000) : null;

  const lastError = lastErrorRes?.data
    ? {
      function: lastErrorRes.data.function_name,
      message: lastErrorRes.data.message,
      at: lastErrorRes.data.created_at,
    }
    : null;

  const pipelineOk = callStaleMin !== null &&
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
    return new Response(null, { status: 204, headers: { ...corsHeaders(), ...noStoreHeaders() } });
  }

  const t0 = Date.now();
  const url = new URL(req.url);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  try {
    // Health check — fast path, no auth, no cache
    if (url.searchParams.get("mode") === "health") {
      return await handleHealth(db, t0);
    }

    const expectedEdgeSecret = Deno.env.get("EDGE_SHARED_SECRET");
    if (!expectedEdgeSecret) {
      return json({ ok: false, error_code: "server_misconfigured", error: "EDGE_SHARED_SECRET not set" }, 500);
    }
    const providedSecret = req.headers.get("X-Edge-Secret");
    if (!providedSecret || providedSecret !== expectedEdgeSecret) {
      return json({ ok: false, error_code: "missing_auth", error: "Valid X-Edge-Secret required" }, 401);
    }

    const action = url.searchParams.get("action");

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
          error: `Unsupported redline API path: /${apiRoute.base}/${apiRoute.path.join("/")}`,
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

    if (action === "undo_verdict" && req.method === "POST") {
      return await handleUndoVerdict(db, req, t0);
    }
    if (action === "repair" && req.method === "POST") {
      return await handleRepair(db, req, t0);
    }
    if (req.method === "POST") {
      return await handleGrade(db, req, t0);
    }
    if (action === "triage_queue") {
      return await handleTriageQueue(db, url, t0);
    }
    if (action === "top_candidates") {
      return await handleTopCandidates(db, url, t0);
    }
    if (action === "sanity") {
      return await handleSanity(db, t0);
    }
    if (action === "contacts") {
      return await handleContacts(db, url, t0);
    }
    if (action === "truth_graph") {
      return await handleTruthGraph(db, url, t0);
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

    const contactId = url.searchParams.get("contact_id") || url.searchParams.get("contact_key");
    if (contactId) {
      const rawLimit = parseInt(url.searchParams.get("limit") || "20", 10);
      const limit = Math.min(Math.max(isNaN(rawLimit) ? 20 : rawLimit, 1), 200);
      const rawOffset = parseInt(url.searchParams.get("offset") || "0", 10);
      const offset = Math.max(isNaN(rawOffset) ? 0 : rawOffset, 0);
      return await handleThread(db, contactId, limit, offset, t0);
    }

    return new Response(HTML, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8", ...corsHeaders(), ...noStoreHeaders() },
    });
  } catch (err: any) {
    console.error("[redline-thread] Error:", err.message);
    return json(
      { ok: false, error_code: "internal_error", error: err.message, function_version: FUNCTION_VERSION },
      500,
    );
  }
});
