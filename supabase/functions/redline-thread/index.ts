import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "redline-thread_v2.0.1";
const OWNER_SMS_USER_IDS = ["+17066889158", "usr_4PCSTDQ8N161KAC4GG7AF9CR94"];
const OUTBOUND_INFERENCE_WINDOW_MS = 30 * 60 * 1000;
const OUTBOUND_INFERENCE_MAX_GAP_MS = 60 * 1000;

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
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

async function inferMissingOutboundSms(
  db: any,
  inboundMs: number[],
  existingSmsIds: Set<string>,
): Promise<any[]> {
  if (inboundMs.length === 0) return [];

  const minInboundMs = Math.min(...inboundMs);
  const maxInboundMs = Math.max(...inboundMs);
  const lowerBound = new Date(minInboundMs - OUTBOUND_INFERENCE_WINDOW_MS).toISOString();
  const upperBound = new Date(maxInboundMs + OUTBOUND_INFERENCE_WINDOW_MS).toISOString();

  const { data, error } = await db
    .from("sms_messages")
    .select("id, sent_at, content, direction, contact_name, sender_user_id")
    .eq("direction", "outbound")
    .in("sender_user_id", OWNER_SMS_USER_IDS)
    .gte("sent_at", lowerBound)
    .lte("sent_at", upperBound)
    .order("sent_at", { ascending: false });

  if (error) {
    console.warn("outbound inference query failed:", error.message);
    return [];
  }

  return (data || [])
    .filter((row: any) => !!row.id && !existingSmsIds.has(row.id))
    .filter((row: any) => isLikelyOwnerOutboundCandidate(row))
    .filter((row: any) => shouldAssignOutboundToInboundWindow(row.sent_at, inboundMs));
}

// contacts endpoint
async function handleContacts(db: any, t0: number): Promise<Response> {
  const { data, error } = await db
    .from("redline_contacts")
    .select(
      "contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type",
    )
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
      last_summary: row.last_snippet || null,
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

  return json({ ok: true, contacts, function_version: FUNCTION_VERSION, ms: Date.now() - t0 });
}

// thread endpoint
async function handleThread(
  db: any,
  contactId: string,
  limit: number,
  offset: number,
  t0: number,
): Promise<Response> {
  const { data: contact, error: contactErr } = await db
    .from("contacts")
    .select("id, name, phone")
    .eq("id", contactId)
    .single();

  if (contactErr || !contact) {
    return json({ ok: false, error_code: "contact_not_found", error: contactErr?.message || "not found" }, 404);
  }

  let allInteractions: any[] = [];
  let interactionsFrom = 0;
  const queryPageSize = 1000;
  while (true) {
    const interactionsTo = interactionsFrom + queryPageSize - 1;
    const { data: page, error: intErr } = await db
      .from("interactions")
      .select("id, interaction_id, event_at_utc, human_summary, contact_name")
      .eq("contact_id", contactId)
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
  }

  let allSmsMessages: any[] = [];
  let smsFrom = 0;
  while (true) {
    const smsTo = smsFrom + queryPageSize - 1;
    const { data: page, error: smsErr } = await db
      .from("sms_messages")
      .select("id, sent_at, content, direction, contact_name, sender_user_id")
      .eq("contact_phone", contact.phone)
      .order("sent_at", { ascending: false })
      .range(smsFrom, smsTo);

    if (smsErr) {
      return json({ ok: false, error_code: "sms_query_failed", error: smsErr.message }, 500);
    }

    if (!page || page.length === 0) break;
    allSmsMessages = allSmsMessages.concat(page);
    if (page.length < queryPageSize) break;
    smsFrom += queryPageSize;
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

  const totalCount = timeline.length;
  const pagedTimeline = timeline.slice(offset, offset + limit);

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
  const pagedSmsMessages = smsMessages.filter((s: any) => pagedSmsIds.has(s.id));

  let callsRaw: any[] = [];
  if (interactionIds.length > 0) {
    const { data, error } = await db
      .from("calls_raw")
      .select("interaction_id, direction, transcript")
      .in("interaction_id", interactionIds);

    if (error) {
      return json({ ok: false, error_code: "calls_raw_query_failed", error: error.message }, 500);
    }
    callsRaw = data || [];
  }

  const directionMap = new Map((callsRaw || []).map((c: any) => [c.interaction_id, c.direction]));
  const transcriptMap = new Map((callsRaw || []).map((c: any) => [c.interaction_id, c.transcript]));

  let spans: any[] = [];
  if (interactionIds.length > 0) {
    const { data, error } = await db
      .from("conversation_spans")
      .select("id, interaction_id, span_index, transcript_segment, word_count")
      .in("interaction_id", interactionIds)
      .eq("is_superseded", false)
      .order("span_index", { ascending: true });

    if (error) {
      return json({ ok: false, error_code: "spans_query_failed", error: error.message }, 500);
    }
    spans = data || [];
  }

  const spansPerInteraction = groupBy(spans || [], (s: any) => s.interaction_id);

  let callClaims: any[] = [];
  if (interactionIds.length > 0) {
    const { data: claimData, error: claimsErr } = await db
      .from("journal_claims")
      .select("id, call_id, source_span_id, claim_type, claim_text, speaker_label")
      .in("call_id", interactionIds);

    if (claimsErr) {
      return json({ ok: false, error_code: "claims_query_failed", error: claimsErr.message }, 500);
    }
    callClaims = claimData || [];
  }

  const allClaimIds = callClaims.map((c: any) => c.id);
  const claimsPerCall = groupBy(callClaims, (c: any) => c.call_id);

  let grades: any[] = [];
  if (allClaimIds.length > 0) {
    const { data: gradeData, error: gradesErr } = await db
      .from("claim_grades")
      .select("claim_id, grade, correction_text, graded_by")
      .in("claim_id", allClaimIds);

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

    const interactionClaims = (claimsPerCall.get(i.interaction_id) || []).map((c: any) => {
      const g = gradeMap.get(c.id);
      return {
        claim_id: c.id,
        claim_type: c.claim_type,
        claim_text: c.claim_text,
        grade: g?.grade || null,
        correction_text: g?.correction_text || null,
        graded_by: g?.graded_by || null,
      };
    });

    return {
      type: "call",
      interaction_id: i.interaction_id,
      event_at: i.event_at_utc,
      direction: directionMap.get(i.interaction_id) || null,
      summary: i.human_summary,
      contact_name: i.contact_name || contact.name,
      raw_transcript: rawTranscript,
      participants,
      spans: dedupedSpans.map((s: any) => ({
        span_id: s.id,
        span_index: s.span_index,
        transcript_segment: s.transcript_segment,
        word_count: s.word_count,
        claims: interactionClaims.filter((c: any) =>
          callClaims.find((cc: any) => cc.id === c.claim_id && cc.source_span_id === s.id)
        ),
      })),
      claims: interactionClaims,
    };
  });

  const smsEntries = pagedSmsMessages.map((s: any) => ({
    type: "sms",
    sms_id: s.id,
    event_at: s.sent_at,
    direction: s.direction,
    content: s.content,
    sender_name: s.direction === "outbound" ? "Zack" : (s.contact_name || contact.name),
  }));

  const thread = [...callEntries, ...smsEntries].sort(
    (a, b) => new Date(a.event_at).getTime() - new Date(b.event_at).getTime(),
  );

  return json({
    ok: true,
    contact: { id: contact.id, name: contact.name, phone: contact.phone },
    thread,
    pagination: { limit, offset, total: totalCount },
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

// Main router
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  const t0 = Date.now();
  const url = new URL(req.url);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  try {
    if (req.method === "POST") {
      return await handleGrade(db, req, t0);
    }

    const action = url.searchParams.get("action");
    if (action === "contacts") {
      return await handleContacts(db, t0);
    }

    const contactId = url.searchParams.get("contact_id");
    if (contactId) {
      const rawLimit = parseInt(url.searchParams.get("limit") || "50", 10);
      const limit = Math.min(Math.max(isNaN(rawLimit) ? 50 : rawLimit, 1), 200);
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
