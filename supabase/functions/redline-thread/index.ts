import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "redline-thread_v1.0.0";

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

// ─── Contacts endpoint ──────────────────────────────────────────────
async function handleContacts(db: any, t0: number): Promise<Response> {
  const { data, error: err } = await db.from("contacts").select("id, name, phone");
  if (err) return json({ ok: false, error_code: "contacts_query_failed", error: err.message }, 500);

  const { data: counts, error: countErr } = await db
    .from("interactions")
    .select("contact_id, event_at_utc")
    .not("contact_id", "is", null)
    .not("event_at_utc", "is", null);
  if (countErr) return json({ ok: false, error_code: "counts_query_failed", error: countErr.message }, 500);

  const { data: smsRows, error: smsErr } = await db.from("sms_messages").select("contact_phone");
  if (smsErr) return json({ ok: false, error_code: "sms_counts_failed", error: smsErr.message }, 500);

  const callCountMap = new Map<string, { count: number; last: string }>();
  for (const row of counts || []) {
    const existing = callCountMap.get(row.contact_id);
    if (!existing) {
      callCountMap.set(row.contact_id, { count: 1, last: row.event_at_utc });
    } else {
      existing.count++;
      if (row.event_at_utc > existing.last) existing.last = row.event_at_utc;
    }
  }

  const smsCountMap = new Map<string, number>();
  for (const row of smsRows || []) {
    smsCountMap.set(row.contact_phone, (smsCountMap.get(row.contact_phone) || 0) + 1);
  }

  const result = (data || [])
    .map((c: any) => {
      const stats = callCountMap.get(c.id) || { count: 0, last: null };
      return {
        contact_id: c.id,
        name: c.name,
        phone: c.phone,
        call_count: stats.count,
        sms_count: smsCountMap.get(c.phone) || 0,
        last_activity: stats.last,
      };
    })
    .filter((c: any) => c.call_count > 0 || c.sms_count > 0)
    .sort((a: any, b: any) => {
      if (!a.last_activity) return 1;
      if (!b.last_activity) return -1;
      return b.last_activity.localeCompare(a.last_activity);
    });

  return json({ ok: true, contacts: result, function_version: FUNCTION_VERSION, ms: Date.now() - t0 });
}

// ─── Thread endpoint ────────────────────────────────────────────────
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

  const { count: totalCount } = await db
    .from("interactions")
    .select("id", { count: "exact", head: true })
    .eq("contact_id", contactId)
    .not("event_at_utc", "is", null);

  const { data: interactions, error: intErr } = await db
    .from("interactions")
    .select("id, interaction_id, event_at_utc, human_summary, contact_name")
    .eq("contact_id", contactId)
    .not("event_at_utc", "is", null)
    .order("event_at_utc", { ascending: true })
    .range(offset, offset + limit - 1);

  if (intErr) return json({ ok: false, error_code: "interactions_query_failed", error: intErr.message }, 500);
  if (!interactions || interactions.length === 0) {
    return json({
      ok: true,
      contact: { id: contact.id, name: contact.name, phone: contact.phone },
      thread: [],
      pagination: { limit, offset, total: totalCount || 0 },
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  const interactionIds = interactions.map((i: any) => i.interaction_id);

  const { data: callsRaw } = await db
    .from("calls_raw")
    .select("interaction_id, direction")
    .in("interaction_id", interactionIds);

  const directionMap = new Map((callsRaw || []).map((c: any) => [c.interaction_id, c.direction]));

  const { data: spans } = await db
    .from("conversation_spans")
    .select("id, interaction_id, span_index, transcript_segment, word_count")
    .in("interaction_id", interactionIds)
    .eq("is_superseded", false)
    .order("span_index", { ascending: true });

  const spanIds = (spans || []).map((s: any) => s.id);
  const spansPerInteraction = groupBy(spans || [], (s: any) => s.interaction_id);

  let claims: any[] = [];
  if (spanIds.length > 0) {
    const { data: claimData } = await db
      .from("journal_claims")
      .select("id, source_span_id, claim_type, claim_text, speaker_label")
      .in("source_span_id", spanIds);
    claims = claimData || [];
  }

  const claimIds = claims.map((c: any) => c.id);
  const claimsPerSpan = groupBy(claims, (c: any) => c.source_span_id);

  let grades: any[] = [];
  if (claimIds.length > 0) {
    const { data: gradeData } = await db
      .from("claim_grades")
      .select("claim_id, grade, correction_text, graded_by")
      .in("claim_id", claimIds);
    grades = gradeData || [];
  }

  const gradeMap = new Map((grades || []).map((g: any) => [g.claim_id, g]));

  const { data: smsMessages } = await db
    .from("sms_messages")
    .select("id, sent_at, content, direction, contact_name")
    .eq("contact_phone", contact.phone)
    .order("sent_at", { ascending: true });

  // ─── Assemble thread ───
  const callEntries = interactions.map((i: any) => ({
    type: "call",
    interaction_id: i.interaction_id,
    event_at: i.event_at_utc,
    direction: directionMap.get(i.interaction_id) || null,
    summary: i.human_summary,
    spans: (spansPerInteraction.get(i.interaction_id) || []).map((s: any) => ({
      span_id: s.id,
      span_index: s.span_index,
      transcript_segment: s.transcript_segment,
      word_count: s.word_count,
      claims: (claimsPerSpan.get(s.id) || []).map((c: any) => {
        const g = gradeMap.get(c.id);
        return {
          claim_id: c.id,
          claim_type: c.claim_type,
          claim_text: c.claim_text,
          grade: g?.grade || null,
          correction_text: g?.correction_text || null,
          graded_by: g?.graded_by || null,
        };
      }),
    })),
  }));

  const smsEntries = (smsMessages || []).map((s: any) => ({
    type: "sms",
    sms_id: s.id,
    event_at: s.sent_at,
    direction: s.direction,
    content: s.content,
  }));

  const thread = [...callEntries, ...smsEntries].sort(
    (a, b) => new Date(a.event_at).getTime() - new Date(b.event_at).getTime(),
  );

  return json({
    ok: true,
    contact: { id: contact.id, name: contact.name, phone: contact.phone },
    thread,
    pagination: { limit, offset, total: totalCount || 0 },
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// ─── Grade endpoint ─────────────────────────────────────────────────
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

// ─── HTML UI ────────────────────────────────────────────────────────
// All user-controlled text is escaped via escapeHtml() before DOM insertion.
// Event handlers use data-* attributes + event delegation (no inline JS with user data).
const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Redline</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #000; color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      font-size: 16px; -webkit-font-smoothing: antialiased;
      min-height: 100dvh;
    }
    #top-bar {
      position: sticky; top: 0; z-index: 10;
      background: rgba(28,28,30,0.92);
      backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
      padding: 12px 16px; border-bottom: 0.5px solid #38383A;
      display: flex; align-items: center; gap: 12px;
    }
    #top-bar h1 { font-size: 17px; font-weight: 600; flex: 1; }
    #contact-select {
      background: #2C2C2E; color: #fff; border: none; border-radius: 8px;
      padding: 8px 12px; font-size: 15px; max-width: 200px;
    }
    #thread-container { max-width: 800px; margin: 0 auto; padding: 8px 16px 120px; }
    .time-label { text-align: center; color: #8E8E93; font-size: 12px; font-weight: 500; padding: 20px 0 6px; }
    .call-card { background: #1C1C1E; border-radius: 16px; padding: 14px 16px; margin: 10px 0; }
    .call-header { display: flex; align-items: center; gap: 10px; }
    .call-icon {
      width: 36px; height: 36px; border-radius: 50%; background: #30D158;
      display: flex; align-items: center; justify-content: center; font-size: 18px; flex-shrink: 0;
    }
    .call-icon.outbound { background: #007AFF; }
    .call-meta { flex: 1; }
    .call-meta .title { font-size: 15px; font-weight: 600; }
    .call-meta .subtitle { font-size: 13px; color: #8E8E93; margin-top: 2px; }
    .call-summary { color: #EBEBF5; font-size: 14px; line-height: 1.5; margin: 10px 0; padding: 0 2px; }
    .claims-section { margin-top: 10px; }
    .claims-header { font-size: 13px; font-weight: 600; color: #8E8E93; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 6px; }
    .claim-item {
      padding: 10px 12px; margin: 4px 0; border-radius: 10px; background: #2C2C2E;
      font-size: 14px; line-height: 1.4; cursor: pointer; position: relative;
      transition: background 0.15s; display: flex; align-items: flex-start; gap: 8px;
    }
    .claim-item:active { background: #3A3A3C; }
    .claim-bullet { flex-shrink: 0; width: 6px; height: 6px; border-radius: 50%; background: #8E8E93; margin-top: 7px; }
    .claim-text { flex: 1; }
    .claim-badge { flex-shrink: 0; font-size: 14px; margin-left: 4px; }
    .claim-item.graded-confirm .claim-bullet { background: #30D158; }
    .claim-item.graded-reject .claim-bullet { background: #FF453A; }
    .claim-item.graded-correct .claim-bullet { background: #FF9F0A; }
    .claim-type-tag {
      display: inline-block; font-size: 11px; font-weight: 600; color: #8E8E93;
      background: #3A3A3C; padding: 2px 6px; border-radius: 4px; margin-right: 6px;
    }
    .transcript-toggle { display: inline-block; margin-top: 10px; font-size: 13px; color: #007AFF; cursor: pointer; padding: 6px 0; }
    .transcript-toggle:active { opacity: 0.6; }
    .transcript-content {
      display: none; margin-top: 8px; padding: 12px; background: #2C2C2E; border-radius: 10px;
      font-size: 13px; color: #EBEBF599; line-height: 1.6; white-space: pre-wrap; max-height: 400px; overflow-y: auto;
    }
    .transcript-content.open { display: block; }
    .sms-row { display: flex; margin: 6px 0; }
    .sms-row.inbound { justify-content: flex-start; }
    .sms-row.outbound { justify-content: flex-end; }
    .sms-bubble { max-width: 75%; padding: 10px 14px; border-radius: 18px; font-size: 15px; line-height: 1.4; }
    .sms-row.inbound .sms-bubble { background: #2C2C2E; border-bottom-left-radius: 4px; }
    .sms-row.outbound .sms-bubble { background: #007AFF; border-bottom-right-radius: 4px; }
    .sms-time { font-size: 11px; color: #8E8E93; margin-top: 2px; padding: 0 4px; }
    .sms-row.outbound .sms-time { text-align: right; }
    #grade-overlay {
      display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.6);
      backdrop-filter: blur(4px); z-index: 100; justify-content: center; align-items: flex-end; padding: 0 16px 32px;
    }
    #grade-overlay.open { display: flex; }
    #grade-sheet { background: #2C2C2E; border-radius: 14px; padding: 20px; width: 100%; max-width: 360px; }
    #grade-sheet h3 { font-size: 15px; font-weight: 600; margin-bottom: 4px; }
    #grade-claim-preview { font-size: 13px; color: #8E8E93; margin-bottom: 16px; line-height: 1.4; max-height: 80px; overflow-y: auto; }
    .grade-btn {
      display: block; width: 100%; padding: 14px; margin: 6px 0; border: none; border-radius: 12px;
      font-size: 16px; font-weight: 600; cursor: pointer; text-align: center;
    }
    .grade-btn:active { opacity: 0.7; }
    .grade-btn.confirm { background: #30D158; color: #000; }
    .grade-btn.reject { background: #FF453A; color: #fff; }
    .grade-btn.correct-btn { background: #FF9F0A; color: #000; }
    .grade-btn.cancel { background: #3A3A3C; color: #fff; margin-top: 12px; }
    #correction-area { display: none; margin-top: 10px; }
    #correction-area textarea {
      width: 100%; min-height: 80px; padding: 10px; background: #1C1C1E; color: #fff;
      border: 1px solid #48484A; border-radius: 10px; font-size: 15px; resize: vertical;
    }
    #correction-area .grade-btn { margin-top: 8px; }
    .loading { text-align: center; padding: 40px; color: #8E8E93; font-size: 15px; }
    .spinner {
      display: inline-block; width: 24px; height: 24px;
      border: 2px solid #3A3A3C; border-top-color: #007AFF;
      border-radius: 50%; animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .stats-bar { display: flex; gap: 16px; padding: 8px 0 4px; font-size: 13px; color: #8E8E93; flex-wrap: wrap; }
    .stat-item { display: flex; align-items: center; gap: 4px; }
    .stat-dot { width: 8px; height: 8px; border-radius: 50%; }
    .stat-dot.green { background: #30D158; }
    .stat-dot.red { background: #FF453A; }
    .stat-dot.yellow { background: #FF9F0A; }
    .stat-dot.gray { background: #8E8E93; }
  </style>
</head>
<body>
  <div id="top-bar">
    <h1>Redline</h1>
    <select id="contact-select"><option value="">Loading...</option></select>
  </div>
  <div id="thread-container">
    <div class="loading"><div class="spinner"></div><div style="margin-top:12px">Loading contacts...</div></div>
  </div>

  <div id="grade-overlay">
    <div id="grade-sheet">
      <h3>Grade Claim</h3>
      <div id="grade-claim-preview"></div>
      <button class="grade-btn confirm" data-action="grade-confirm">Confirm</button>
      <button class="grade-btn reject" data-action="grade-reject">Reject</button>
      <button class="grade-btn correct-btn" data-action="grade-show-correct">Correct</button>
      <div id="correction-area">
        <textarea id="correction-text" placeholder="Enter correction..."></textarea>
        <button class="grade-btn confirm" data-action="grade-submit-correct">Submit Correction</button>
      </div>
      <button class="grade-btn cancel" data-action="grade-cancel">Cancel</button>
    </div>
  </div>

  <script>
    (function() {
      "use strict";
      var BASE_URL = window.location.origin + window.location.pathname;
      var currentClaimId = null;

      function escapeHtml(text) {
        if (!text) return "";
        var div = document.createElement("div");
        div.textContent = text;
        return div.innerHTML;
      }

      // ── Contacts ──
      async function loadContacts() {
        try {
          var res = await fetch(BASE_URL + "?action=contacts");
          var data = await res.json();
          if (!data.ok) throw new Error(data.error || "Failed to load contacts");
          var select = document.getElementById("contact-select");
          select.innerHTML = "";
          data.contacts.forEach(function(c) {
            var opt = document.createElement("option");
            opt.value = c.contact_id;
            opt.textContent = c.name + " (" + c.call_count + " calls)";
            select.appendChild(opt);
          });
          var defaultId = new URLSearchParams(window.location.search).get("contact_id");
          if (!defaultId && data.contacts.length > 0) defaultId = data.contacts[0].contact_id;
          if (defaultId) {
            select.value = defaultId;
            loadThread(defaultId);
          }
        } catch (e) {
          document.getElementById("thread-container").textContent = "Error: " + e.message;
        }
      }

      // ── Thread ──
      async function loadThread(contactId) {
        var container = document.getElementById("thread-container");
        container.innerHTML = '<div class="loading"><div class="spinner"></div><div style="margin-top:12px">Loading thread...</div></div>';
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
        container.innerHTML = "";
        if (!data.thread || data.thread.length === 0) {
          container.textContent = "No messages found";
          return;
        }

        var gradeStats = { confirm: 0, reject: 0, correct: 0, ungraded: 0 };
        data.thread.forEach(function(item) {
          if (item.type !== "call") return;
          (item.spans || []).forEach(function(span) {
            (span.claims || []).forEach(function(claim) {
              if (claim.grade) gradeStats[claim.grade] = (gradeStats[claim.grade] || 0) + 1;
              else gradeStats.ungraded++;
            });
          });
        });

        // Stats bar
        var totalClaims = gradeStats.confirm + gradeStats.reject + gradeStats.correct + gradeStats.ungraded;
        if (totalClaims > 0) {
          var statsDiv = document.createElement("div");
          statsDiv.className = "stats-bar";
          statsDiv.innerHTML =
            '<div class="stat-item"><span class="stat-dot green"></span>' + gradeStats.confirm + ' confirmed</div>' +
            '<div class="stat-item"><span class="stat-dot red"></span>' + gradeStats.reject + ' rejected</div>' +
            '<div class="stat-item"><span class="stat-dot yellow"></span>' + gradeStats.correct + ' corrected</div>' +
            '<div class="stat-item"><span class="stat-dot gray"></span>' + gradeStats.ungraded + ' ungraded</div>';
          container.appendChild(statsDiv);
        }

        var infoDiv = document.createElement("div");
        infoDiv.style.cssText = "font-size:13px;color:#8E8E93;padding:4px 0 8px";
        infoDiv.textContent = data.contact.name + " \\u00b7 " + data.pagination.total + " calls";
        container.appendChild(infoDiv);

        var lastDate = "";
        data.thread.forEach(function(item) {
          var eventDate = new Date(item.event_at);
          var dateStr = eventDate.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
          if (dateStr !== lastDate) {
            var label = document.createElement("div");
            label.className = "time-label";
            label.textContent = dateStr;
            container.appendChild(label);
            lastDate = dateStr;
          }
          if (item.type === "call") container.appendChild(buildCallCard(item));
          else if (item.type === "sms") container.appendChild(buildSmsBubble(item));
        });

        window.scrollTo(0, document.body.scrollHeight);
      }

      function buildCallCard(item) {
        var card = document.createElement("div");
        card.className = "call-card";

        var time = new Date(item.event_at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
        var dir = item.direction || "unknown";

        // Header
        var header = document.createElement("div");
        header.className = "call-header";
        var icon = document.createElement("div");
        icon.className = dir === "outbound" ? "call-icon outbound" : "call-icon";
        icon.textContent = dir === "outbound" ? "\\u2197" : "\\u2199";
        var meta = document.createElement("div");
        meta.className = "call-meta";
        var titleEl = document.createElement("div");
        titleEl.className = "title";
        titleEl.textContent = "Phone Call";
        var subtitle = document.createElement("div");
        subtitle.className = "subtitle";
        subtitle.textContent = time + " \\u00b7 " + dir;
        meta.appendChild(titleEl);
        meta.appendChild(subtitle);
        header.appendChild(icon);
        header.appendChild(meta);
        card.appendChild(header);

        // Summary
        if (item.summary) {
          var summary = document.createElement("div");
          summary.className = "call-summary";
          summary.textContent = item.summary;
          card.appendChild(summary);
        }

        // Claims (flattened across spans)
        var allClaims = [];
        (item.spans || []).forEach(function(span) {
          (span.claims || []).forEach(function(claim) { allClaims.push(claim); });
        });

        if (allClaims.length > 0) {
          var section = document.createElement("div");
          section.className = "claims-section";
          var hdr = document.createElement("div");
          hdr.className = "claims-header";
          hdr.textContent = "Claims (" + allClaims.length + ")";
          section.appendChild(hdr);

          allClaims.forEach(function(claim) {
            var el = document.createElement("div");
            el.className = "claim-item" + (claim.grade ? " graded-" + claim.grade : "");
            el.setAttribute("data-claim-id", claim.claim_id);
            el.setAttribute("data-claim-text", claim.claim_text || "");

            var bullet = document.createElement("div");
            bullet.className = "claim-bullet";
            el.appendChild(bullet);

            var textEl = document.createElement("div");
            textEl.className = "claim-text";
            if (claim.claim_type) {
              var tag = document.createElement("span");
              tag.className = "claim-type-tag";
              tag.textContent = claim.claim_type;
              textEl.appendChild(tag);
            }
            textEl.appendChild(document.createTextNode(claim.claim_text || ""));
            el.appendChild(textEl);

            if (claim.grade) {
              var badge = document.createElement("span");
              badge.className = "claim-badge";
              badge.textContent = claim.grade === "confirm" ? "\\u2705" : claim.grade === "reject" ? "\\u274C" : "\\u270F\\uFE0F";
              el.appendChild(badge);
            }

            section.appendChild(el);
          });
          card.appendChild(section);
        }

        // Transcript toggle
        var hasTranscript = (item.spans || []).some(function(s) { return s.transcript_segment; });
        if (hasTranscript) {
          var toggle = document.createElement("span");
          toggle.className = "transcript-toggle";
          toggle.textContent = "Show Transcript";
          toggle.setAttribute("data-action", "toggle-transcript");
          card.appendChild(toggle);

          var tcontent = document.createElement("div");
          tcontent.className = "transcript-content";
          (item.spans || []).forEach(function(span) {
            if (span.transcript_segment) {
              tcontent.appendChild(document.createTextNode(span.transcript_segment + "\\n\\n"));
            }
          });
          card.appendChild(tcontent);
        }

        return card;
      }

      function buildSmsBubble(item) {
        var dir = item.direction || "inbound";
        var time = new Date(item.event_at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
        var row = document.createElement("div");
        row.className = "sms-row " + dir;
        var wrapper = document.createElement("div");
        var bubble = document.createElement("div");
        bubble.className = "sms-bubble";
        bubble.textContent = item.content || "";
        var timeEl = document.createElement("div");
        timeEl.className = "sms-time";
        timeEl.textContent = time;
        wrapper.appendChild(bubble);
        wrapper.appendChild(timeEl);
        row.appendChild(wrapper);
        return row;
      }

      // ── Grading (event delegation) ──
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
            body: JSON.stringify({
              claim_id: currentClaimId,
              grade: grade,
              correction_text: correctionText,
              graded_by: "chad"
            })
          });
          var data = await res.json();
          if (!data.ok) throw new Error(data.error || "Failed to save grade");
          closeGradeSheet();
          var contactId = document.getElementById("contact-select").value;
          if (contactId) loadThread(contactId);
        } catch (e) {
          alert("Grade failed: " + e.message);
        }
      }

      // ── Event delegation ──
      document.addEventListener("click", function(e) {
        var claimItem = e.target.closest(".claim-item");
        if (claimItem) {
          openGradeSheet(claimItem.dataset.claimId, claimItem.dataset.claimText);
          return;
        }

        var action = e.target.dataset.action;
        if (action === "toggle-transcript") {
          var content = e.target.nextElementSibling;
          if (content) {
            content.classList.toggle("open");
            e.target.textContent = content.classList.contains("open") ? "Hide Transcript" : "Show Transcript";
          }
          return;
        }
        if (action === "grade-confirm") { submitGrade("confirm"); return; }
        if (action === "grade-reject") { submitGrade("reject"); return; }
        if (action === "grade-show-correct") {
          document.getElementById("correction-area").style.display = "block";
          return;
        }
        if (action === "grade-submit-correct") { submitGrade("correct"); return; }
        if (action === "grade-cancel") { closeGradeSheet(); return; }
      });

      document.getElementById("grade-overlay").addEventListener("click", function(e) {
        if (e.target === this) closeGradeSheet();
      });

      document.getElementById("contact-select").addEventListener("change", function() {
        if (this.value) loadThread(this.value);
      });

      // ── Init ──
      loadContacts();
    })();
  </script>
</body>
</html>`;

// ─── Main router ────────────────────────────────────────────────────
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
      const limit = Math.min(Math.max(parseInt(url.searchParams.get("limit") || "50", 10), 1), 200);
      const offset = Math.max(parseInt(url.searchParams.get("offset") || "0", 10), 0);
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
