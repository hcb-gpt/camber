/**
 * brief-serve Edge Function v1.3.0
 *
 * Purpose:
 * - Create Zack-facing brief links from live morning-digest payloads.
 * - Capture read/action proof in brief_deliveries + brief_events.
 *
 * Routes:
 * 1) POST /brief-serve                    (X-Edge-Secret required)
 * 2) GET  /brief-serve?id=<uuid>          (authenticated read-proof page)
 * 3) POST /brief-serve?id=<uuid>&action=reviewed                (authenticated action-proof)
 * 4) POST /brief-serve?id=<uuid>&action=complete_scheduler_item (authenticated scheduler completion)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v1.3.0";
const COMPLETE_SCHEDULER_ACTION = "complete_scheduler_item";
const JSON_HEADERS = { "Content-Type": "application/json" };
const HTML_HEADERS = { "Content-Type": "text/html; charset=utf-8" };

type AnyRecord = Record<string, unknown>;

interface BriefDeliveryRow {
  id: string;
  digest_json: AnyRecord;
  read_proof: string | null;
  action_proof: string | null;
  delivered_to: string | null;
  delivered_at: string | null;
}

interface SchedulerRenderContext {
  briefId: string;
  completeActionUrl: string;
  signingSecret: string | null;
}

Deno.serve(async (req: Request) => {
  try {
    const url = new URL(req.url);
    const id = (url.searchParams.get("id") || "").trim();
    const action = (url.searchParams.get("action") || "").trim().toLowerCase();

    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: JSON_HEADERS });
    }

    if (req.method === "POST" && action === COMPLETE_SCHEDULER_ACTION) {
      return await handleCompleteSchedulerItem(req, id);
    }

    if (req.method === "POST" && action === "reviewed") {
      return await handleReviewed(req, id);
    }

    if (req.method === "POST") {
      return await handleCreate(req);
    }

    if (req.method === "GET") {
      return await handleRead(req, id);
    }

    return jsonResponse(405, { ok: false, error: "method_not_allowed", detail: "Use GET or POST" });
  } catch (err) {
    console.error("[brief-serve] fatal:", err);
    return jsonResponse(500, {
      ok: false,
      error: "brief_serve_fatal",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
});

async function handleCreate(req: Request): Promise<Response> {
  const edgeSecret = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET") || "";

  if (!edgeSecret) {
    return jsonResponse(401, { ok: false, error: "missing_edge_secret" });
  }
  if (!expectedSecret || !constantTimeEqual(edgeSecret, expectedSecret)) {
    return jsonResponse(403, { ok: false, error: "invalid_edge_secret" });
  }

  const body = await parseJsonBody(req);
  const db = serviceRoleClient();
  const supabaseUrl = requireEnv("SUPABASE_URL");

  const digest = await fetchMorningDigest(supabaseUrl, edgeSecret);
  if (!digest || typeof digest !== "object" || digest.ok !== true) {
    return jsonResponse(502, {
      ok: false,
      error: "morning_digest_unavailable",
      detail: "morning-digest did not return a valid payload",
    });
  }
  const schedulerActionables = await fetchSchedulerActionables(db);
  const overdueAlerter = await fetchOverdueAlerter(db);
  const digestWithScheduler: AnyRecord = {
    ...digest,
    scheduler_actionables: schedulerActionables,
    overdue_alerter: overdueAlerter,
  };

  const nowIso = new Date().toISOString();
  const id = crypto.randomUUID();
  const recipient = normalizeRecipient(asString(body.recipient) || asString(body.delivered_to) || "zack");
  const deliveredTo = asString(body.delivered_to) || recipient;
  const briefUrl = `${supabaseUrl}/functions/v1/brief-serve?id=${id}`;

  const insertPayload = {
    id,
    brief_date: nowIso.slice(0, 10),
    recipient,
    digest_json: digestWithScheduler,
    brief_url: briefUrl,
    delivered_to: deliveredTo,
    delivered_at: nowIso,
  };

  const { error: insertError } = await db
    .from("brief_deliveries")
    .insert(insertPayload);

  if (insertError) {
    console.error("[brief-serve] insert brief_deliveries failed:", insertError.message);
    return jsonResponse(500, {
      ok: false,
      error: "insert_brief_delivery_failed",
      detail: insertError.message,
    });
  }

  const createdLogged = await logBriefEvent(db, req, id, "created", {
    delivered_to: deliveredTo,
    function_version: FUNCTION_VERSION,
  });
  if (!createdLogged.ok) {
    return jsonResponse(500, {
      ok: false,
      error: "log_created_event_failed",
      detail: createdLogged.error,
    });
  }

  return jsonResponse(200, {
    ok: true,
    id,
    brief_url: briefUrl,
    delivered_to: deliveredTo,
    delivered_at: nowIso,
    function_version: FUNCTION_VERSION,
  });
}

async function handleRead(req: Request, id: string): Promise<Response> {
  if (!isUuid(id)) {
    return htmlResponse(400, renderErrorPage("Invalid brief link", "Missing or invalid brief id."));
  }

  const db = serviceRoleClient();

  const { data, error } = await db
    .from("brief_deliveries")
    .select("id, digest_json, read_proof, action_proof, delivered_to, delivered_at")
    .eq("id", id)
    .maybeSingle();

  if (error) {
    console.error("[brief-serve] read delivery failed:", error.message);
    return htmlResponse(500, renderErrorPage("Brief unavailable", "Could not load this brief right now."));
  }

  if (!data) {
    return htmlResponse(404, renderErrorPage("Brief not found", "This brief link is not valid."));
  }

  const row = data as BriefDeliveryRow;
  if (!row.read_proof) {
    const nowIso = new Date().toISOString();
    const { data: touched, error: touchError } = await db
      .from("brief_deliveries")
      .update({
        read_proof: nowIso,
        read_ip: getClientIp(req),
        read_user_agent: req.headers.get("user-agent") || null,
      })
      .eq("id", id)
      .is("read_proof", null)
      .select("id")
      .maybeSingle();

    if (touchError) {
      console.error("[brief-serve] read proof update failed:", touchError.message);
    } else if (touched) {
      await logBriefEvent(db, req, id, "opened", {
        function_version: FUNCTION_VERSION,
      });
    }
  }

  const page = await renderBriefPage(row, req.url);
  return htmlResponse(200, page);
}

async function handleReviewed(req: Request, id: string): Promise<Response> {
  if (!isUuid(id)) {
    return htmlResponse(400, renderErrorPage("Invalid review action", "Missing or invalid brief id."));
  }

  const db = serviceRoleClient();

  const { data: existing, error: existingError } = await db
    .from("brief_deliveries")
    .select("id, action_proof")
    .eq("id", id)
    .maybeSingle();

  if (existingError) {
    console.error("[brief-serve] lookup before reviewed failed:", existingError.message);
    return htmlResponse(500, renderErrorPage("Action failed", "Could not register review right now."));
  }
  if (!existing) {
    return htmlResponse(404, renderErrorPage("Brief not found", "This brief link is not valid."));
  }

  if (!existing.action_proof) {
    const nowIso = new Date().toISOString();
    const { data: touched, error: touchError } = await db
      .from("brief_deliveries")
      .update({ action_proof: nowIso })
      .eq("id", id)
      .is("action_proof", null)
      .select("id")
      .maybeSingle();

    if (touchError) {
      console.error("[brief-serve] action proof update failed:", touchError.message);
      return htmlResponse(500, renderErrorPage("Action failed", "Could not register review right now."));
    }

    if (touched) {
      await logBriefEvent(db, req, id, "reviewed", {
        function_version: FUNCTION_VERSION,
      });
    }
  }

  return htmlResponse(200, renderThanksPage());
}

async function handleCompleteSchedulerItem(req: Request, id: string): Promise<Response> {
  if (!isUuid(id)) {
    return htmlResponse(400, renderErrorPage("Invalid action", "Missing or invalid brief id."));
  }

  const form = await parseFormBody(req);
  const schedulerItemId = asString(form.scheduler_item_id);
  const actionToken = asString(form.action_token);

  if (!schedulerItemId || !isUuid(schedulerItemId)) {
    return htmlResponse(400, renderErrorPage("Invalid action", "Missing or invalid scheduler item id."));
  }
  if (!actionToken) {
    return htmlResponse(401, renderErrorPage("Action denied", "Missing completion token."));
  }

  const signingSecret = getActionSigningSecret();
  if (!signingSecret) {
    console.error("[brief-serve] scheduler complete unavailable: missing EDGE_SHARED_SECRET");
    return htmlResponse(500, renderErrorPage("Action unavailable", "Completion is temporarily unavailable."));
  }

  const expectedToken = await buildSchedulerActionToken(signingSecret, id, schedulerItemId);
  if (!constantTimeEqual(actionToken, expectedToken)) {
    const db = serviceRoleClient();
    await logBriefEvent(db, req, id, "action_click", {
      action: COMPLETE_SCHEDULER_ACTION,
      scheduler_item_id: schedulerItemId,
      outcome: "rejected_invalid_token",
      function_version: FUNCTION_VERSION,
    });
    return htmlResponse(403, renderErrorPage("Action denied", "This completion link is invalid."));
  }

  const db = serviceRoleClient();

  const { data: delivery, error: deliveryError } = await db
    .from("brief_deliveries")
    .select("id, digest_json, action_proof")
    .eq("id", id)
    .maybeSingle();

  if (deliveryError) {
    console.error("[brief-serve] lookup before scheduler complete failed:", deliveryError.message);
    return htmlResponse(500, renderErrorPage("Action failed", "Could not load brief context right now."));
  }
  if (!delivery) {
    return htmlResponse(404, renderErrorPage("Brief not found", "This brief link is not valid."));
  }

  const digest = toRecord((delivery as AnyRecord).digest_json);
  if (!briefContainsSchedulerItem(digest, schedulerItemId)) {
    await logBriefEvent(db, req, id, "action_click", {
      action: COMPLETE_SCHEDULER_ACTION,
      scheduler_item_id: schedulerItemId,
      outcome: "rejected_not_in_brief_scope",
      function_version: FUNCTION_VERSION,
    });
    return htmlResponse(403, renderErrorPage("Action denied", "That scheduler item is not in this brief."));
  }

  const { data: schedulerItem, error: schedulerLookupError } = await db
    .from("scheduler_items")
    .select("id, status, title")
    .eq("id", schedulerItemId)
    .maybeSingle();

  if (schedulerLookupError) {
    console.error("[brief-serve] scheduler item lookup failed:", schedulerLookupError.message);
    return htmlResponse(500, renderErrorPage("Action failed", "Could not load scheduler item right now."));
  }
  if (!schedulerItem) {
    return htmlResponse(404, renderErrorPage("Action failed", "Scheduler item not found."));
  }

  const schedulerTitle = asString((schedulerItem as AnyRecord).title) || "Scheduler item";
  const currentStatus = asString((schedulerItem as AnyRecord).status) || "pending";
  if (currentStatus === "completed") {
    await logBriefEvent(db, req, id, "action_click", {
      action: COMPLETE_SCHEDULER_ACTION,
      scheduler_item_id: schedulerItemId,
      outcome: "already_completed",
      function_version: FUNCTION_VERSION,
    });
    return htmlResponse(
      200,
      renderSchedulerActionResultPage("Already completed", `${schedulerTitle} was already complete.`),
    );
  }
  if (currentStatus !== "pending") {
    await logBriefEvent(db, req, id, "action_click", {
      action: COMPLETE_SCHEDULER_ACTION,
      scheduler_item_id: schedulerItemId,
      outcome: `rejected_status_${currentStatus}`,
      function_version: FUNCTION_VERSION,
    });
    return htmlResponse(409, renderErrorPage("Action blocked", "This scheduler item is no longer pending."));
  }

  const nowIso = new Date().toISOString();
  const { data: touched, error: updateError } = await db
    .from("scheduler_items")
    .update({
      status: "completed",
      updated_at: nowIso,
    })
    .eq("id", schedulerItemId)
    .eq("status", "pending")
    .select("id")
    .maybeSingle();

  if (updateError) {
    console.error("[brief-serve] scheduler completion update failed:", updateError.message);
    return htmlResponse(500, renderErrorPage("Action failed", "Could not mark this scheduler item complete."));
  }

  let resultTitle = "Marked complete";
  let resultDetail = `${schedulerTitle} is now complete.`;
  let finalOutcome = "completed";

  if (!touched) {
    const { data: latestItem, error: latestError } = await db
      .from("scheduler_items")
      .select("status")
      .eq("id", schedulerItemId)
      .maybeSingle();

    if (latestError) {
      console.error("[brief-serve] scheduler completion race-check failed:", latestError.message);
      return htmlResponse(500, renderErrorPage("Action failed", "Could not verify scheduler item status."));
    }

    const latestStatus = asString((latestItem as AnyRecord).status) || "unknown";
    if (latestStatus !== "completed") {
      await logBriefEvent(db, req, id, "action_click", {
        action: COMPLETE_SCHEDULER_ACTION,
        scheduler_item_id: schedulerItemId,
        outcome: `rejected_status_${latestStatus}`,
        function_version: FUNCTION_VERSION,
      });
      return htmlResponse(409, renderErrorPage("Action blocked", "This scheduler item is no longer pending."));
    }

    resultTitle = "Already completed";
    resultDetail = `${schedulerTitle} was already complete.`;
    finalOutcome = "idempotent_already_completed";
  }

  if (!asString((delivery as AnyRecord).action_proof)) {
    const { error: proofError } = await db
      .from("brief_deliveries")
      .update({ action_proof: nowIso })
      .eq("id", id)
      .is("action_proof", null);
    if (proofError) {
      console.error("[brief-serve] action proof touch after scheduler complete failed:", proofError.message);
    }
  }

  await logBriefEvent(db, req, id, "action_click", {
    action: COMPLETE_SCHEDULER_ACTION,
    scheduler_item_id: schedulerItemId,
    outcome: finalOutcome,
    function_version: FUNCTION_VERSION,
  });

  return htmlResponse(200, renderSchedulerActionResultPage(resultTitle, resultDetail));
}

async function fetchMorningDigest(supabaseUrl: string, edgeSecret: string): Promise<AnyRecord> {
  const response = await fetch(`${supabaseUrl}/functions/v1/morning-digest`, {
    method: "POST",
    headers: {
      "X-Edge-Secret": edgeSecret,
      "Content-Type": "application/json",
    },
    body: "{}",
  });

  const text = await response.text();
  let payload: AnyRecord = {};
  try {
    payload = JSON.parse(text || "{}");
  } catch {
    throw new Error("morning_digest_invalid_json");
  }

  if (!response.ok) {
    throw new Error(`morning_digest_${response.status}: ${truncate(text, 300)}`);
  }

  return payload;
}

async function logBriefEvent(
  db: any,
  req: Request,
  briefId: string,
  eventType: "created" | "opened" | "reviewed" | "action_click",
  metadata: AnyRecord,
): Promise<{ ok: boolean; error?: string }> {
  const { error } = await db.from("brief_events").insert({
    brief_id: briefId,
    event_type: eventType,
    metadata,
    ip_address: getClientIp(req),
    user_agent: req.headers.get("user-agent") || null,
  });

  if (error) {
    console.error(`[brief-serve] log event failed (${eventType}):`, error.message);
    return { ok: false, error: error.message };
  }
  return { ok: true };
}

async function renderBriefPage(row: BriefDeliveryRow, requestUrl: string): Promise<string> {
  const digest = toRecord(row.digest_json);
  const narrative = toRecord(digest.narrative_brief);
  const narrativeDecisions = toStringList(narrative.decisions_needed);
  const narrativeRiskSummary = asString(narrative.risk_summary) || deriveFallbackRiskSummary(digest);
  const openLoops = toProjectBuckets(toRecord(digest.open_loops).by_project);
  const overdueAlerter = toOverdueProjectBuckets(digest.overdue_alerter);
  const schedulerActionables = toSchedulerProjectBuckets(digest.scheduler_actionables);
  const striking = flattenSignalsByProject(toRecord(digest.unresolved_signals).by_project, 5);
  const actionUrl = `${stripQuery(requestUrl)}?id=${encodeURIComponent(row.id)}&action=reviewed`;
  const completeActionUrl = `${stripQuery(requestUrl)}?id=${
    encodeURIComponent(row.id)
  }&action=${COMPLETE_SCHEDULER_ACTION}`;
  const actionSigningSecret = getActionSigningSecret();
  const deliveredTo = escapeHtml(row.delivered_to || "Zack");
  const deliveredAt = row.delivered_at ? new Date(row.delivered_at).toLocaleString() : "Unknown";

  const loopSections = openLoops.length === 0
    ? `<p class="empty">No open loops found in this brief.</p>`
    : openLoops.map((group) => renderProjectLoopGroup(group.project, group.items)).join("\n");

  const overdueSection = overdueAlerter.length === 0
    ? `<p class="empty">No overdue scheduler items in this brief window.</p>`
    : overdueAlerter.map((group) => renderOverdueProjectGroup(group.project, group.items)).join("\n");

  const schedulerSection = schedulerActionables.length === 0
    ? `<p class="empty">No high-confidence scheduler actionables found.</p>`
    : (await Promise.all(
      schedulerActionables.map((group) =>
        renderSchedulerProjectGroup(group.project, group.items, {
          briefId: row.id,
          completeActionUrl,
          signingSecret: actionSigningSecret,
        })
      ),
    )).join("\n");

  const strikingSection = striking.length === 0 ? `<p class="empty">No striking signals found.</p>` : `
      <ul class="signals">
        ${
    striking.map((item) => {
      const quote = escapeHtml(extractSignalQuote(item.signal));
      const project = escapeHtml(item.project);
      return `<li><strong>${project}</strong><blockquote>“${quote}”</blockquote></li>`;
    }).join("\n")
  }
      </ul>
    `;

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover" />
    <title>Camber Brief</title>
    <style>
      :root {
        --bg: #f3f6f4;
        --card: #ffffff;
        --ink: #1f2a1f;
        --muted: #58705f;
        --accent: #1f8f47;
        --accent-dark: #166835;
        --danger-bg: #ffe8e8;
        --danger-ink: #7c1f1f;
        --warn-bg: #fff6da;
        --warn-ink: #7a5a10;
        --border: #dbe5de;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: var(--bg);
        color: var(--ink);
        line-height: 1.4;
      }
      main {
        max-width: 780px;
        margin: 0 auto;
        padding: 16px 14px 42px;
      }
      .header {
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: 14px;
        padding: 16px;
        margin-bottom: 14px;
      }
      h1 {
        margin: 0 0 8px;
        font-size: 1.35rem;
      }
      .meta {
        color: var(--muted);
        font-size: 0.94rem;
      }
      .narrative {
        margin-top: 12px;
        padding: 12px;
        background: #f7faf8;
        border: 1px solid var(--border);
        border-radius: 10px;
      }
      .narrative p { margin: 0 0 8px; }
      .narrative p:last-child { margin-bottom: 0; }
      .narrative-list {
        margin: 0;
        padding-left: 18px;
      }
      .narrative-list li {
        margin-bottom: 6px;
      }
      .card {
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: 14px;
        padding: 14px;
        margin-bottom: 14px;
      }
      h2 {
        margin: 0 0 10px;
        font-size: 1.08rem;
      }
      h3 {
        margin: 12px 0 8px;
        font-size: 1rem;
      }
      .loop-list {
        margin: 0;
        padding-left: 20px;
      }
      .loop-item {
        margin-bottom: 8px;
        padding: 8px 10px;
        border-radius: 10px;
        border: 1px solid transparent;
        list-style: disc;
      }
      .loop-item.blocker {
        background: var(--danger-bg);
        color: var(--danger-ink);
        border-color: #f7c7c7;
      }
      .loop-item.question {
        background: var(--warn-bg);
        color: var(--warn-ink);
        border-color: #efd98c;
      }
      .signals {
        margin: 0;
        padding-left: 16px;
      }
      blockquote {
        margin: 6px 0 12px;
        padding: 8px 10px;
        border-left: 4px solid #b9d5c2;
        background: #f7faf8;
        border-radius: 4px;
        font-size: 0.98rem;
      }
      .review-wrap {
        position: sticky;
        bottom: 10px;
      }
      .review-btn {
        width: 100%;
        border: 0;
        border-radius: 14px;
        padding: 16px 18px;
        font-size: 1.08rem;
        font-weight: 700;
        background: var(--accent);
        color: white;
        cursor: pointer;
        box-shadow: 0 6px 18px rgba(31, 143, 71, 0.28);
      }
      .review-btn:active { background: var(--accent-dark); }
      .empty { color: var(--muted); margin: 0; }
      .card-note {
        margin: 0 0 10px;
        color: var(--muted);
        font-size: 0.92rem;
      }
      .scheduler-list {
        margin: 0;
        padding-left: 20px;
      }
      .overdue-list {
        margin: 0;
        padding-left: 20px;
      }
      .overdue-item {
        list-style: disc;
        margin-bottom: 8px;
      }
      .overdue-meta {
        margin-top: 2px;
        color: var(--danger-ink);
        font-size: 0.9rem;
      }
      .scheduler-item {
        list-style: disc;
        margin-bottom: 8px;
      }
      .scheduler-row {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 10px;
      }
      .scheduler-main {
        flex: 1 1 220px;
        min-width: 0;
      }
      .scheduler-meta {
        margin-top: 2px;
        color: var(--muted);
        font-size: 0.9rem;
      }
      .scheduler-complete-form {
        margin: 2px 0 0;
      }
      .scheduler-complete-btn {
        border: 1px solid #b9d5c2;
        border-radius: 9px;
        padding: 6px 9px;
        background: #f4fbf6;
        color: #21563a;
        font-weight: 600;
        font-size: 0.86rem;
        cursor: pointer;
        white-space: nowrap;
      }
      .scheduler-complete-btn:active {
        background: #e5f4ea;
      }
      .scheduler-complete-disabled {
        color: var(--muted);
        font-size: 0.82rem;
        margin-top: 4px;
      }
      @media (max-width: 480px) {
        h1 { font-size: 1.2rem; }
        .review-btn { font-size: 1rem; padding: 15px; }
        .scheduler-row {
          flex-direction: column;
          align-items: flex-start;
        }
      }
    </style>
  </head>
  <body>
    <main>
      <section class="header">
        <h1>Daily Camber Brief</h1>
        <div class="meta">Prepared for ${deliveredTo} • Delivered ${escapeHtml(deliveredAt)}</div>
        <div class="narrative">
          <p><strong>What changed:</strong> ${
    escapeHtml(asString(narrative.what_changed) || "No summary available.")
  }</p>
          <p><strong>Why it matters:</strong> ${
    escapeHtml(asString(narrative.why_it_matters) || "No summary available.")
  }</p>
          <p><strong>Risk summary:</strong> ${escapeHtml(narrativeRiskSummary)}</p>
          ${
    narrativeDecisions.length > 0
      ? `<p><strong>Decisions needed:</strong></p>
             <ul class="narrative-list">
               ${narrativeDecisions.map((item) => `<li>${escapeHtml(item)}</li>`).join("\n")}
             </ul>`
      : ""
  }
        </div>
      </section>

      <section class="card">
        <h2>Overdue Alerter</h2>
        <p class="card-note">Pending scheduler items already past due.</p>
        ${overdueSection}
      </section>

      <section class="card">
        <h2>Open Loops (Blockers First)</h2>
        ${loopSections}
      </section>

      <section class="card">
        <h2>Scheduler Actionables</h2>
        <p class="card-note">Top high-confidence pending items grouped by highest-risk projects.</p>
        ${schedulerSection}
      </section>

      <section class="card">
        <h2>Top Striking Signals</h2>
        ${strikingSection}
      </section>

      <form method="POST" action="${escapeHtml(actionUrl)}" class="review-wrap">
        <button type="submit" class="review-btn">✅ Reviewed</button>
      </form>
    </main>
  </body>
</html>`;
}

function renderProjectLoopGroup(projectName: string, loops: unknown[]): string {
  const sorted = [...loops].sort((a, b) => classifyLoopSeverity(a) - classifyLoopSeverity(b));
  const items = sorted.map((loop) => {
    const severity = classifyLoopSeverity(loop);
    const cls = severity === 0 ? "blocker" : severity === 1 ? "question" : "normal";
    const row = toRecord(loop);
    const loopType = asString(row.loop_type) || "open_loop";
    const description = asString(row.description) || "No description provided.";
    return `<li class="loop-item ${cls}"><strong>${escapeHtml(loopType)}</strong>: ${escapeHtml(description)}</li>`;
  }).join("\n");

  return `
    <h3>${escapeHtml(projectName)}</h3>
    <ul class="loop-list">
      ${items}
    </ul>
  `;
}

function renderOverdueProjectGroup(projectName: string, items: unknown[]): string {
  const rows = items.map((item) => toRecord(item)).filter((item) => Object.keys(item).length > 0);
  if (rows.length === 0) return "";

  const rendered = rows.map((item) => {
    const title = escapeHtml(asString(item.title) || "Untitled overdue item");
    const daysOverdue = asNumber(item.days_overdue);
    const overdueLabel = daysOverdue !== null ? `${daysOverdue} day${daysOverdue === 1 ? "" : "s"} overdue` : "Overdue";
    const dueLabel = formatDateLabel(asString(item.due_at_utc), "Due");
    return `
      <li class="overdue-item">
        <strong>${title}</strong>
        <div class="overdue-meta">${escapeHtml(overdueLabel)}${dueLabel ? ` • ${escapeHtml(dueLabel)}` : ""}</div>
      </li>
    `;
  }).join("\n");

  return `
    <h3>${escapeHtml(projectName)}</h3>
    <ul class="overdue-list">
      ${rendered}
    </ul>
  `;
}

async function renderSchedulerProjectGroup(
  projectName: string,
  items: unknown[],
  ctx: SchedulerRenderContext,
): Promise<string> {
  const rows = items.map((item) => toRecord(item)).filter((item) => Object.keys(item).length > 0);
  if (rows.length === 0) return "";

  const rendered = await Promise.all(rows.map(async (item) => {
    const title = escapeHtml(asString(item.title) || "Untitled scheduler item");
    const schedulerItemId = asString(item.id);
    const due = formatDateLabel(asString(item.due_at_utc), "Due");
    const created = formatDateLabel(asString(item.created_at), "Created");
    const source = escapeHtml(asString(item.source) || "unknown");
    const assignee = asString(item.assignee);
    const assigneeLabel = assignee ? ` • Assignee: ${escapeHtml(assignee)}` : "";
    const completionAction = await renderSchedulerCompleteAction(ctx, schedulerItemId);
    return `
      <li class="scheduler-item">
        <div class="scheduler-row">
          <div class="scheduler-main">
            <strong>${title}</strong>
            <div class="scheduler-meta">${
      escapeHtml(due || created || "No date")
    } • Source: ${source}${assigneeLabel}</div>
          </div>
          ${completionAction}
        </div>
      </li>
    `;
  })).then((parts) => parts.join("\n"));

  return `
    <h3>${escapeHtml(projectName)}</h3>
    <ul class="scheduler-list">
      ${rendered}
    </ul>
  `;
}

async function renderSchedulerCompleteAction(
  ctx: SchedulerRenderContext,
  schedulerItemId: string | null,
): Promise<string> {
  if (!schedulerItemId || !isUuid(schedulerItemId)) {
    return `<div class="scheduler-complete-disabled">Completion unavailable</div>`;
  }
  if (!ctx.signingSecret) {
    return `<div class="scheduler-complete-disabled">Completion unavailable</div>`;
  }
  const token = await buildSchedulerActionToken(ctx.signingSecret, ctx.briefId, schedulerItemId);
  return `
    <form method="POST" action="${escapeHtml(ctx.completeActionUrl)}" class="scheduler-complete-form">
      <input type="hidden" name="scheduler_item_id" value="${escapeHtml(schedulerItemId)}" />
      <input type="hidden" name="action_token" value="${escapeHtml(token)}" />
      <button type="submit" class="scheduler-complete-btn">Mark complete</button>
    </form>
  `;
}

function renderSchedulerActionResultPage(title: string, detail: string): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>${escapeHtml(title)}</title>
    <style>
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #f3f6f4;
        color: #17301f;
      }
      .card {
        background: #fff;
        border: 1px solid #dbe5de;
        border-radius: 14px;
        padding: 24px 20px;
        width: min(90vw, 460px);
        text-align: center;
      }
      h1 { margin: 0 0 10px; font-size: 1.32rem; }
      p { margin: 0; color: #466050; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>${escapeHtml(title)}</h1>
      <p>${escapeHtml(detail)}</p>
    </div>
  </body>
</html>`;
}

function renderThanksPage(): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>Thanks Zack</title>
    <style>
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #f3f6f4;
        color: #17301f;
      }
      .card {
        background: #fff;
        border: 1px solid #dbe5de;
        border-radius: 14px;
        padding: 24px 20px;
        width: min(90vw, 420px);
        text-align: center;
      }
      h1 { margin: 0 0 10px; font-size: 1.35rem; }
      p { margin: 0; color: #466050; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>Thanks Zack</h1>
      <p>Your review is recorded.</p>
    </div>
  </body>
</html>`;
}

function renderErrorPage(title: string, detail: string): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>${escapeHtml(title)}</title>
    <style>
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #f7f8f8;
        color: #222;
      }
      .card {
        width: min(90vw, 500px);
        background: #fff;
        border: 1px solid #e1e1e1;
        border-radius: 12px;
        padding: 20px;
      }
      h1 { margin: 0 0 8px; font-size: 1.2rem; }
      p { margin: 0; color: #666; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>${escapeHtml(title)}</h1>
      <p>${escapeHtml(detail)}</p>
    </div>
  </body>
</html>`;
}

function toProjectBuckets(input: unknown): Array<{ project: string; items: unknown[] }> {
  const obj = toRecord(input);
  return Object.entries(obj)
    .map(([project, items]) => ({ project, items: Array.isArray(items) ? items : [] }))
    .sort((a, b) => a.project.localeCompare(b.project));
}

function toSchedulerProjectBuckets(input: unknown): Array<{ project: string; items: unknown[] }> {
  if (!Array.isArray(input)) return [];
  return input
    .map((entry) => toRecord(entry))
    .map((entry) => ({
      project: asString(entry.project) || "Unknown Project",
      items: Array.isArray(entry.items) ? entry.items : [],
    }))
    .filter((entry) => entry.items.length > 0)
    .slice(0, 5);
}

function toOverdueProjectBuckets(input: unknown): Array<{ project: string; items: unknown[] }> {
  if (!Array.isArray(input)) return [];
  return input
    .map((entry) => toRecord(entry))
    .map((entry) => ({
      project: asString(entry.project) || "Unknown Project",
      items: Array.isArray(entry.items) ? entry.items : [],
    }))
    .filter((entry) => entry.items.length > 0)
    .slice(0, 5);
}

function toStringList(input: unknown): string[] {
  if (!Array.isArray(input)) return [];
  return input
    .map((item) => asString(item))
    .filter((item): item is string => Boolean(item));
}

function deriveFallbackRiskSummary(digest: AnyRecord): string {
  const openLoopTotal = asNumber(toRecord(digest.open_loops).total_open) || 0;
  const unresolvedTotal = asNumber(toRecord(digest.unresolved_signals).total_striking_signals) || 0;
  const reviewPending = asNumber(toRecord(digest.review_pressure).pending_count) || 0;
  const overdueProjects = toOverdueProjectBuckets(digest.overdue_alerter).length;
  return `Queue ${reviewPending} pending, ${openLoopTotal} open loops, ${unresolvedTotal} striking signals, ${overdueProjects} projects with overdue scheduler work.`;
}

function briefContainsSchedulerItem(digest: AnyRecord, schedulerItemId: string): boolean {
  const schedulerBuckets = toSchedulerProjectBuckets(digest.scheduler_actionables);
  for (const bucket of schedulerBuckets) {
    for (const item of bucket.items) {
      if (asString(toRecord(item).id) === schedulerItemId) return true;
    }
  }
  return false;
}

function flattenSignalsByProject(input: unknown, limit: number): Array<{ project: string; signal: unknown }> {
  const buckets = toProjectBuckets(input);
  const flattened: Array<{ project: string; signal: unknown }> = [];
  for (const bucket of buckets) {
    for (const signal of bucket.items) {
      flattened.push({ project: bucket.project, signal });
      if (flattened.length >= limit) return flattened;
    }
  }
  return flattened;
}

function classifyLoopSeverity(loop: unknown): number {
  const row = toRecord(loop);
  const loopType = `${asString(row.loop_type) || ""} ${asString(row.description) || ""}`.toLowerCase();
  if (loopType.includes("blocker") || loopType.includes("blocked") || loopType.includes("stuck")) return 0;
  if (loopType.includes("question") || loopType.includes("clarif") || loopType.includes("tbd")) return 1;
  return 2;
}

function formatDateLabel(raw: string | null, prefix: string): string | null {
  if (!raw) return null;
  const dt = new Date(raw);
  if (Number.isNaN(dt.getTime())) return null;
  return `${prefix} ${dt.toLocaleDateString()}`;
}

function extractSignalQuote(signal: unknown): string {
  const row = toRecord(signal);
  const direct = pickFirstString(
    row.quote,
    row.text,
    row.snippet,
    row.excerpt,
    row.primary_signal_type,
  );
  if (direct) return direct;

  const nested = row.signals;
  if (Array.isArray(nested)) {
    for (const item of nested) {
      const nestedRow = toRecord(item);
      const value = pickFirstString(
        item,
        nestedRow.quote,
        nestedRow.text,
        nestedRow.snippet,
        nestedRow.signal_text,
        nestedRow.reasoning,
      );
      if (value) return value;
    }
  } else {
    const nestedRow = toRecord(nested);
    const value = pickFirstString(
      nestedRow.quote,
      nestedRow.text,
      nestedRow.snippet,
      nestedRow.signal_text,
      nestedRow.reasoning,
    );
    if (value) return value;
  }

  return "Signal detail unavailable.";
}

async function fetchSchedulerActionables(
  db: any,
  projectLimit = 5,
  itemsPerProject = 5,
): Promise<Array<{ project: string; items: AnyRecord[] }>> {
  const { data: projectRows, error: projectError } = await db
    .from("v_monday_brief_data")
    .select("project_id, project_name, risk_score")
    .order("risk_score", { ascending: false })
    .limit(projectLimit);

  if (projectError) {
    console.error("[brief-serve] scheduler project ranking read failed:", projectError.message);
    return [];
  }

  const rankedProjects = (projectRows || [])
    .map((row: AnyRecord) => ({
      id: asString(row.project_id),
      name: asString(row.project_name) || "Unknown Project",
    }))
    .filter((row: { id: string | null; name: string }) => row.id !== null) as Array<
      { id: string; name: string }
    >;

  if (rankedProjects.length === 0) return [];

  const projectIds = rankedProjects.map((row) => row.id);
  const projectNameById = new Map(rankedProjects.map((row) => [row.id, row.name]));

  const { data: schedulerRows, error: schedulerError } = await db
    .from("scheduler_items")
    .select("id, project_id, title, due_at_utc, created_at, source, assignee, needs_review")
    .in("project_id", projectIds)
    .eq("status", "pending")
    .eq("attribution_status", "resolved")
    .order("due_at_utc", { ascending: true, nullsFirst: false })
    .order("created_at", { ascending: true });

  if (schedulerError) {
    console.error("[brief-serve] scheduler actionables read failed:", schedulerError.message);
    return [];
  }

  const bucket = new Map<string, AnyRecord[]>();
  for (const rowRaw of schedulerRows || []) {
    const row = toRecord(rowRaw);
    const projectId = asString(row.project_id);
    if (!projectId || !projectNameById.has(projectId)) continue;
    if (row.needs_review === true) continue;
    const existing = bucket.get(projectId) || [];
    if (existing.length >= itemsPerProject) continue;
    existing.push({
      id: asString(row.id),
      title: asString(row.title) || "Untitled scheduler item",
      due_at_utc: asString(row.due_at_utc),
      created_at: asString(row.created_at),
      source: asString(row.source),
      assignee: asString(row.assignee),
    });
    bucket.set(projectId, existing);
  }

  return rankedProjects
    .map((project) => ({
      project: project.name,
      items: bucket.get(project.id) || [],
    }))
    .filter((group) => group.items.length > 0);
}

async function fetchOverdueAlerter(
  db: any,
  projectLimit = 5,
  itemsPerProject = 3,
): Promise<Array<{ project: string; items: AnyRecord[] }>> {
  const { data: overdueProjects, error: overdueProjectsError } = await db
    .from("v_scheduler_brief")
    .select("project_id, project_name, overdue")
    .gt("overdue", 0)
    .order("overdue", { ascending: false })
    .limit(projectLimit);

  if (overdueProjectsError) {
    console.error("[brief-serve] overdue alerter project read failed:", overdueProjectsError.message);
    return [];
  }

  const projects = (overdueProjects || [])
    .map((row: AnyRecord) => ({
      id: asString(row.project_id),
      name: asString(row.project_name) || "Unknown Project",
    }))
    .filter((row: { id: string | null; name: string }) => row.id !== null) as Array<
      { id: string; name: string }
    >;

  if (projects.length === 0) return [];

  const projectIds = projects.map((row) => row.id);
  const projectNameById = new Map(projects.map((row) => [row.id, row.name]));
  const nowIso = new Date().toISOString();
  const nowMs = Date.now();

  const { data: overdueRows, error: overdueRowsError } = await db
    .from("scheduler_items")
    .select("id, project_id, title, due_at_utc")
    .in("project_id", projectIds)
    .eq("status", "pending")
    .eq("attribution_status", "resolved")
    .not("due_at_utc", "is", null)
    .lte("due_at_utc", nowIso)
    .order("due_at_utc", { ascending: true });

  if (overdueRowsError) {
    console.error("[brief-serve] overdue alerter item read failed:", overdueRowsError.message);
    return [];
  }

  const bucket = new Map<string, AnyRecord[]>();
  for (const rowRaw of overdueRows || []) {
    const row = toRecord(rowRaw);
    const projectId = asString(row.project_id);
    if (!projectId || !projectNameById.has(projectId)) continue;
    const dueRaw = asString(row.due_at_utc);
    if (!dueRaw) continue;
    const dueMs = new Date(dueRaw).getTime();
    if (Number.isNaN(dueMs)) continue;
    const daysOverdue = Math.max(1, Math.floor((nowMs - dueMs) / 86400000));
    const existing = bucket.get(projectId) || [];
    if (existing.length >= itemsPerProject) continue;
    existing.push({
      id: asString(row.id),
      title: asString(row.title) || "Untitled overdue item",
      due_at_utc: dueRaw,
      days_overdue: daysOverdue,
    });
    bucket.set(projectId, existing);
  }

  return projects
    .map((project) => ({
      project: project.name,
      items: bucket.get(project.id) || [],
    }))
    .filter((group) => group.items.length > 0);
}

function pickFirstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
  }
  return null;
}

function toRecord(value: unknown): AnyRecord {
  if (value && typeof value === "object" && !Array.isArray(value)) return value as AnyRecord;
  return {};
}

function asString(value: unknown): string | null {
  if (typeof value === "string") {
    const s = value.trim();
    return s.length > 0 ? s : null;
  }
  return null;
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function normalizeRecipient(value: string): string {
  const cleaned = value.trim().toLowerCase();
  return cleaned.length > 0 ? cleaned : "zack";
}

function requireEnv(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`missing_env_${key}`);
  return value;
}

function getActionSigningSecret(): string | null {
  const secret = (Deno.env.get("EDGE_SHARED_SECRET") || "").trim();
  return secret.length > 0 ? secret : null;
}

async function buildSchedulerActionToken(
  secret: string,
  briefId: string,
  schedulerItemId: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(secret);
  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const payload = encoder.encode(`${briefId}:${schedulerItemId}:${COMPLETE_SCHEDULER_ACTION}`);
  const signature = await crypto.subtle.sign("HMAC", key, payload);
  return bytesToHex(new Uint8Array(signature));
}

function serviceRoleClient() {
  return createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
  );
}

function getClientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim();
  return req.headers.get("x-real-ip");
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function truncate(value: string, max: number): string {
  if (value.length <= max) return value;
  return `${value.slice(0, max)}...`;
}

function stripQuery(value: string): string {
  const url = new URL(value);
  return `${url.origin}${url.pathname}`;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

async function parseFormBody(req: Request): Promise<AnyRecord> {
  const contentType = (req.headers.get("content-type") || "").toLowerCase();

  if (contentType.includes("application/x-www-form-urlencoded")) {
    const raw = await req.text();
    const params = new URLSearchParams(raw);
    const out: AnyRecord = {};
    for (const [key, value] of params.entries()) out[key] = value;
    return out;
  }

  if (contentType.includes("multipart/form-data")) {
    try {
      const form = await req.formData();
      const out: AnyRecord = {};
      for (const [key, value] of form.entries()) {
        if (typeof value === "string") out[key] = value;
      }
      return out;
    } catch {
      return {};
    }
  }

  if (contentType.includes("application/json")) {
    return await parseJsonBody(req);
  }

  return {};
}

async function parseJsonBody(req: Request): Promise<AnyRecord> {
  const contentType = (req.headers.get("content-type") || "").toLowerCase();
  if (!contentType.includes("application/json")) return {};
  try {
    const payload = await req.json();
    return toRecord(payload);
  } catch {
    return {};
  }
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

function jsonResponse(status: number, body: AnyRecord): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS,
  });
}

function htmlResponse(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: HTML_HEADERS,
  });
}
