import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "bootstrap-review_v1.1.5";
type ReviewQueueSource = "pipeline" | "redline";

// ─── Helpers ─────────────────────────────────────────────────────────

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, x-source, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

function _escapeHtml(text: string): string {
  if (!text) return "";
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    .test(str);
}

function normalizeReviewQueueSource(
  raw: unknown,
  fallback: ReviewQueueSource = "pipeline",
): ReviewQueueSource {
  const normalized = String(raw || "").trim().toLowerCase();
  if (normalized === "redline") return "redline";
  if (normalized === "pipeline") return "pipeline";
  return fallback;
}

function isMissingReviewQueueSourceColumnError(message: string): boolean {
  return /column .*source.* does not exist/i.test(message);
}

function isMissingColumnError(message: string, column: string): boolean {
  const escapedColumn = column.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`column .*${escapedColumn}.* does not exist`, "i").test(
    message,
  );
}

function isAllowedQueueModule(raw: unknown): boolean {
  const module = String(raw || "").trim().toLowerCase();
  return module === "" || module === "attribution";
}

function normalizeQueueItemForIOS(item: any): any | null {
  const spanId = String(item?.span_id || "").trim();
  if (!isValidUUID(spanId)) return null;
  if (!isAllowedQueueModule(item?.module)) return null;

  const transcriptSegment = typeof item?.transcript_segment === "string"
    ? item.transcript_segment
    : typeof item?.context_payload?.transcript_snippet === "string"
    ? item.context_payload.transcript_snippet
    : "";

  return {
    ...item,
    span_id: spanId,
    transcript_segment: transcriptSegment,
  };
}

async function countPendingQueueItemsForIOS(db: any): Promise<number> {
  const base = db
    .from("review_queue")
    .select("id", { count: "exact", head: true })
    .eq("status", "pending")
    .not("span_id", "is", null);

  const { count, error } = await base.or("module.eq.attribution,module.is.null");
  if (!error) return count || 0;

  if (isMissingColumnError(error.message || "", "module")) {
    const { count: fallbackCount, error: fallbackErr } = await db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending")
      .not("span_id", "is", null);
    if (!fallbackErr) return fallbackCount || 0;
    console.warn(`[bootstrap-review:queue] pending count fallback failed: ${fallbackErr.message}`);
    return 0;
  }

  console.warn(`[bootstrap-review:queue] pending count failed: ${error.message}`);
  return 0;
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

async function fetchReviewProjects(db: any): Promise<any[]> {
  const inactiveStatuses = new Set([
    "archived",
    "closed",
    "completed",
    "done",
    "inactive",
    "on_hold",
    "on hold",
    "paused",
    "prospect",
    "pipeline",
    "cancelled",
    "canceled",
  ]);

  const excludedProjectNames = new Set([
    "Business Development & Networking",
    "Overhead / Internal Operations",
  ]);

  const pickerLabelBySourceName = new Map<string, string>([
    ["Hurley Residence", "Hurley Residence"],
    ["Moss Residence", "Moss Residence"],
    ["Permar Residence", "Permar Home"],
    ["Permar Home", "Permar Home"],
    ["Skelton Residence", "Skelton Residence"],
    ["Winship Residence", "Winship Residence"],
    ["Woodbery Residence", "Woodbery Residence"],
    ["Young Residence", "Young Residence"],
  ]);

  const { data: withStatus, error: withStatusErr } = await db
    .from("projects")
    .select("id, name, status")
    .order("name");

  if (!withStatusErr && withStatus) {
    return withStatus
      .filter((project: any) => {
        const name = String(project?.name || "").trim();
        if (excludedProjectNames.has(name)) return false;
        const status = String(project?.status || "").trim().toLowerCase();
        if (status && inactiveStatuses.has(status)) return false;
        return pickerLabelBySourceName.has(name);
      })
      .map((project: any) => ({
        id: project.id,
        name: pickerLabelBySourceName.get(String(project?.name || "").trim()) || project.name,
      }));
  }

  const { data: fallback, error: fallbackErr } = await db
    .from("projects")
    .select("id, name")
    .order("name");

  if (fallbackErr) return [];
  return fallback || [];
}

async function handleProjects(db: any, t0: number): Promise<Response> {
  const projects = await fetchReviewProjects(db);
  return json({
    ok: true,
    projects,
    count: projects.length,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// ─── Queue endpoint ──────────────────────────────────────────────────

async function handleQueue(
  db: any,
  limit: number,
  t0: number,
): Promise<Response> {
  // Fetch pending span-based review rows directly so filtering happens
  // before LIMIT (avoids empty pages with nonzero pending totals).
  const queueSelect = "id, span_id, interaction_id, context_payload, reasons, reason_codes, module, status, created_at";

  let rqData: any[] | null = null;
  let rqErr: any = null;
  {
    const primary = await db
      .from("review_queue")
      .select(queueSelect)
      .eq("status", "pending")
      .not("span_id", "is", null)
      .or("module.eq.attribution,module.is.null")
      .order("created_at", { ascending: false })
      .limit(limit);
    rqData = primary.data;
    rqErr = primary.error;

    if (rqErr && isMissingColumnError(rqErr.message || "", "module")) {
      const fallback = await db
        .from("review_queue")
        .select(queueSelect)
        .eq("status", "pending")
        .not("span_id", "is", null)
        .order("created_at", { ascending: false })
        .limit(limit);
      rqData = fallback.data;
      rqErr = fallback.error;
    }
  }

  if (rqErr) {
    return json({
      ok: false,
      error_code: "queue_query_failed",
      error: rqErr.message,
    }, 500);
  }

  if (!rqData || rqData.length === 0) {
    const projects = await fetchReviewProjects(db);
    return json({
      ok: true,
      items: [],
      projects,
      total_pending: 0,
      function_version: FUNCTION_VERSION,
      ms: Date.now() - t0,
    });
  }

  // Batch fetch related data
  const spanIds = rqData
    .map((r: any) => r.span_id)
    .filter((id: string) => id);
  const interactionIds = [
    ...new Set(rqData.map((r: any) => r.interaction_id).filter(Boolean)),
  ];

  // Parallel fetches
  const [spansRes, attrsRes, interactionsRes, callsRes] = await Promise.all([
    spanIds.length > 0
      ? db
        .from("conversation_spans")
        .select("id, transcript_segment, interaction_id")
        .in("id", spanIds)
      : Promise.resolve({ data: [], error: null }),
    spanIds.length > 0
      ? db
        .from("span_attributions")
        .select("span_id, confidence, project_id, decision")
        .in("span_id", spanIds)
      : Promise.resolve({ data: [], error: null }),
    interactionIds.length > 0
      ? db
        .from("interactions")
        .select("interaction_id, contact_name, human_summary, event_at_utc")
        .in("interaction_id", interactionIds)
      : Promise.resolve({ data: [], error: null }),
    interactionIds.length > 0
      ? db
        .from("calls_raw")
        .select("interaction_id, transcript")
        .in("interaction_id", interactionIds)
      : Promise.resolve({ data: [], error: null }),
  ]);

  const spanMap = new Map(
    (spansRes.data || []).map((s: any) => [s.id, s]),
  );
  const attrMap = new Map(
    (attrsRes.data || []).map((a: any) => [a.span_id, a]),
  );
  const interactionMap = new Map(
    (interactionsRes.data || []).map((i: any) => [i.interaction_id, i]),
  );
  const callMap = new Map(
    (callsRes.data || []).map((c: any) => [c.interaction_id, c]),
  );

  let items: any[] = rqData.map((rq: any) => {
    const span: any = spanMap.get(rq.span_id) || {};
    const attr: any = attrMap.get(rq.span_id) || {};
    const interaction: any = interactionMap.get(rq.interaction_id) || {};
    const call: any = callMap.get(rq.interaction_id) || {};
    return {
      id: rq.id,
      span_id: rq.span_id,
      interaction_id: rq.interaction_id,
      created_at: rq.created_at || null,
      event_at: interaction.event_at_utc || null,
      context_payload: rq.context_payload,
      reasons: rq.reasons,
      reason_codes: rq.reason_codes,
      transcript_segment: span.transcript_segment || null,
      confidence: attr.confidence || null,
      ai_guess_project_id: attr.project_id || null,
      decision: attr.decision || null,
      full_transcript: call.transcript || null,
      contact_name: interaction.contact_name || null,
      human_summary: interaction.human_summary || null,
    };
  });

  items = items
    .map(normalizeQueueItemForIOS)
    .filter((item: any): item is any => item !== null);

  // Sort by most recent first for feed-style triage.
  items.sort((a: any, b: any) => {
    const aTime = Date.parse(a.event_at || a.created_at || "") || 0;
    const bTime = Date.parse(b.event_at || b.created_at || "") || 0;
    if (aTime !== bTime) return bTime - aTime;
    return String(b.id || "").localeCompare(String(a.id || ""));
  });

  // Get total pending count
  const totalPending = await countPendingQueueItemsForIOS(db);

  // Fetch active projects for attribution picker.
  const projects = await fetchReviewProjects(db);

  return json({
    ok: true,
    items,
    projects,
    total_pending: totalPending || 0,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// ─── Resolve endpoint ────────────────────────────────────────────────

async function handleResolve(
  db: any,
  req: Request,
  t0: number,
): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json(
      { ok: false, error_code: "invalid_json", error: "Invalid JSON body" },
      400,
    );
  }

  const { review_queue_id, project_id, notes, user_id, source } = body;

  if (!review_queue_id || !isValidUUID(review_queue_id)) {
    return json({
      ok: false,
      error_code: "missing_review_queue_id",
      error: "review_queue_id required (uuid)",
    }, 400);
  }
  if (!project_id || !isValidUUID(project_id)) {
    return json({
      ok: false,
      error_code: "missing_project_id",
      error: "project_id required (uuid)",
    }, 400);
  }

  const writeSource = normalizeReviewQueueSource(source, "pipeline");
  await tagReviewQueueSource(db, review_queue_id, writeSource, "bootstrap-review:resolve");

  const { data, error } = await db.rpc("resolve_review_item", {
    p_review_queue_id: review_queue_id,
    p_chosen_project_id: project_id,
    p_notes: notes || null,
    p_user_id: user_id || "chad",
  });

  if (error) {
    console.error("[bootstrap-review] resolve RPC failed:", error.message);
    return json({
      ok: false,
      error_code: "rpc_failed",
      error: error.message,
      review_queue_id,
    }, 500);
  }

  const result = typeof data === "string" ? JSON.parse(data) : data;

  if (!result.ok) {
    let status = 400;
    if (result.error === "review_queue_item_not_found") status = 404;
    if (result.error === "human_lock_conflict") status = 409;
    return json({ ...result, ms: Date.now() - t0 }, status);
  }

  const [projectNameRes, queueContextRes] = await Promise.all([
    db
      .from("projects")
      .select("name")
      .eq("id", project_id)
      .maybeSingle(),
    db
      .from("review_queue")
      .select("interaction_id")
      .eq("id", review_queue_id)
      .maybeSingle(),
  ]);
  const chosenProjectName = projectNameRes.data?.name || null;
  const resolvedInteractionId = queueContextRes.data?.interaction_id || result.interaction_id || null;

  let pendingForInteraction = 0;
  if (resolvedInteractionId) {
    const { count } = await db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending")
      .eq("interaction_id", resolvedInteractionId);
    pendingForInteraction = count || 0;
  }

  const { count: totalPendingAfterResolve } = await db
    .from("review_queue")
    .select("id", { count: "exact", head: true })
    .eq("status", "pending");

  // Sync journal_claims contamination-control (same pattern as review-resolve)
  if (result.span_id && isValidUUID(String(result.span_id))) {
    const { error: claimErr } = await db
      .from("journal_claims")
      .update({
        claim_project_id: project_id,
        claim_project_id_norm: project_id,
        attribution_decision: "assign",
        claim_confirmation_state: "confirmed",
        confirmed_at: new Date().toISOString(),
        confirmed_by: "bootstrap_review",
      })
      .eq("source_span_id", String(result.span_id))
      .eq("active", true);

    if (claimErr) {
      console.error(
        `[bootstrap-review] claim sync warning for span ${result.span_id}: ${claimErr.message}`,
      );
    }
  }

  console.log(
    `[bootstrap-review] Resolved ${review_queue_id}: project=${project_id}, user=${user_id || "chad"}`,
  );

  return json({
    ...result,
    chosen_project_id: project_id,
    chosen_project_name: chosenProjectName,
    interaction_id: resolvedInteractionId,
    pending_remaining_for_interaction: pendingForInteraction,
    total_pending: totalPendingAfterResolve || 0,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// ─── Dismiss endpoint (NONE button — marks review as dismissed) ──────

async function handleDismiss(
  db: any,
  req: Request,
  t0: number,
): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error_code: "invalid_json" }, 400);
  }

  const { review_queue_id, user_id, source } = body;

  if (!review_queue_id || !isValidUUID(review_queue_id)) {
    return json({ ok: false, error_code: "missing_review_queue_id" }, 400);
  }

  const writeSource = normalizeReviewQueueSource(source, "pipeline");
  await tagReviewQueueSource(db, review_queue_id, writeSource, "bootstrap-review:dismiss");

  const { error } = await db
    .from("review_queue")
    .update({
      status: "dismissed",
      resolved_at: new Date().toISOString(),
      resolved_by: user_id || "chad_bootstrap",
      resolution_action: "manual_reject",
    })
    .eq("id", review_queue_id)
    .eq("status", "pending");

  if (error) {
    return json({
      ok: false,
      error_code: "dismiss_failed",
      error: error.message,
    }, 500);
  }

  console.log(
    `[bootstrap-review] Dismissed ${review_queue_id} by ${user_id || "chad_bootstrap"}`,
  );

  return json({
    ok: true,
    dismissed: review_queue_id,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// ─── Undo endpoint ───────────────────────────────────────────────────

async function handleUndo(
  db: any,
  req: Request,
  t0: number,
): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error_code: "invalid_json" }, 400);
  }

  const { review_queue_id, source } = body;

  if (!review_queue_id || !isValidUUID(review_queue_id)) {
    return json({ ok: false, error_code: "missing_review_queue_id" }, 400);
  }

  const writeSource = normalizeReviewQueueSource(source, "pipeline");
  await tagReviewQueueSource(db, review_queue_id, writeSource, "bootstrap-review:undo");

  // Check if item was resolved within last 30 seconds (generous server-side window)
  const { data: item, error: fetchErr } = await db
    .from("review_queue")
    .select("id, status, resolved_at, span_id")
    .eq("id", review_queue_id)
    .single();

  if (fetchErr || !item) {
    return json({ ok: false, error_code: "item_not_found" }, 404);
  }

  if (item.status === "pending") {
    return json({ ok: true, message: "already_pending", ms: Date.now() - t0 });
  }

  if (item.resolved_at) {
    const resolvedMs = new Date(item.resolved_at).getTime();
    const elapsed = Date.now() - resolvedMs;
    if (elapsed > 30000) {
      return json({
        ok: false,
        error_code: "undo_window_expired",
        error: "Undo window has expired (>30s)",
      }, 400);
    }
  }

  // Revert review_queue back to pending
  const { error: revertErr } = await db
    .from("review_queue")
    .update({
      status: "pending",
      resolved_at: null,
      resolved_by: null,
      resolution_action: null,
      resolution_notes: null,
    })
    .eq("id", review_queue_id);

  if (revertErr) {
    return json({
      ok: false,
      error_code: "undo_failed",
      error: revertErr.message,
    }, 500);
  }

  // Revert span_attributions: clear applied_project_id, set needs_review back, revert lock
  if (item.span_id) {
    const { error: attrErr } = await db
      .from("span_attributions")
      .update({
        applied_project_id: null,
        needs_review: true,
        attribution_lock: "ai",
      })
      .eq("span_id", item.span_id)
      .eq("attribution_lock", "human");

    if (attrErr) {
      console.error(
        `[bootstrap-review] undo attribution revert warning: ${attrErr.message}`,
      );
    }
  }

  console.log(`[bootstrap-review] Undone ${review_queue_id}`);

  return json({
    ok: true,
    undone: review_queue_id,
    function_version: FUNCTION_VERSION,
    ms: Date.now() - t0,
  });
}

// ─── HTML UI ─────────────────────────────────────────────────────────
// SECURITY: All user-controlled text is escaped via escapeHtml() before
// DOM insertion. The client-side escapeHtml() creates a text node via
// textContent then reads .innerHTML. The highlightTerms() function
// escapes ALL input first, then applies regex replacement on already-safe
// strings. Event handlers use data-* attributes + event delegation with
// no inline JS containing user data.

const HTML = buildHtmlPage();

function buildHtmlPage(): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Bootstrap Review</title>
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="Bootstrap">
  <meta name="theme-color" content="#0A0A0A">
  <link rel="apple-touch-icon" sizes="180x180" href="data:image/png;base64,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">
  <link rel="manifest" href="data:application/json;base64,${
    btoa(JSON.stringify({
      name: "Bootstrap Review",
      short_name: "Bootstrap",
      start_url: ".",
      display: "standalone",
      background_color: "#0A0A0A",
      theme_color: "#0A0A0A",
      icons: [{
        src:
          "data:image/png;base64,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",
        sizes: "192x192",
        type: "image/png",
      }],
    }))
  }">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600;700&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0A0A0A;
      --surface: #141414;
      --surface-2: #1E1E1E;
      --surface-3: #282828;
      --accent: #00E676;
      --accent-dim: rgba(0, 230, 118, 0.15);
      --accent-glow: rgba(0, 230, 118, 0.25);
      --danger: #FF5252;
      --danger-dim: rgba(255, 82, 82, 0.15);
      --warning: #FFD740;
      --warning-dim: rgba(255, 215, 64, 0.15);
      --text: #FAFAFA;
      --text-muted: #888888;
      --text-dim: #555555;
      --border: #2A2A2A;
      --mono: 'IBM Plex Mono', 'JetBrains Mono', 'SF Mono', monospace;
      --sans: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    }

    * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }

    html, body {
      background: var(--bg);
      color: var(--text);
      font-family: var(--sans);
      font-size: 16px;
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
      min-height: 100dvh;
      overflow: hidden;
      touch-action: manipulation;
    }

    #app {
      display: flex;
      flex-direction: column;
      height: 100dvh;
      max-width: 640px;
      margin: 0 auto;
      position: relative;
    }

    #header {
      flex-shrink: 0;
      background: var(--surface);
      border-bottom: 1px solid var(--border);
      padding: 14px 20px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      z-index: 10;
    }

    #header-left {
      display: flex;
      align-items: center;
      gap: 10px;
    }

    #header-logo {
      width: 28px;
      height: 28px;
      background: var(--accent);
      border-radius: 6px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 16px;
      font-weight: 700;
      color: var(--bg);
      font-family: var(--mono);
    }

    #header-title {
      font-family: var(--mono);
      font-weight: 600;
      font-size: 15px;
      letter-spacing: -0.02em;
      color: var(--text);
    }

    #progress-badge {
      font-family: var(--mono);
      font-size: 13px;
      font-weight: 500;
      color: var(--accent);
      background: var(--accent-dim);
      padding: 4px 10px;
      border-radius: 100px;
      letter-spacing: 0.02em;
    }

    #card-area {
      flex: 1;
      overflow-y: auto;
      padding: 16px 16px 8px;
      position: relative;
    }

    .triage-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 20px;
      animation: cardSlideIn 200ms ease-out;
      transform-origin: center;
    }

    @keyframes cardSlideIn {
      from { opacity: 0; transform: translateY(12px) scale(0.98); }
      to { opacity: 1; transform: translateY(0) scale(1); }
    }

    @keyframes cardSlideOut {
      from { opacity: 1; transform: translateX(0) scale(1); }
      to { opacity: 0; transform: translateX(-40px) scale(0.96); }
    }

    .card-exiting {
      animation: cardSlideOut 180ms ease-in forwards;
    }

    .card-section-label {
      font-family: var(--mono);
      font-size: 10px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--text-dim);
      margin-bottom: 8px;
    }

    .transcript-box {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 14px 16px;
      font-size: 15px;
      line-height: 1.55;
      color: var(--text);
      font-family: var(--sans);
      font-weight: 400;
      max-height: 160px;
      overflow-y: auto;
      margin-bottom: 14px;
    }

    .transcript-box .hl {
      color: var(--accent);
      font-weight: 600;
      background: var(--accent-dim);
      padding: 1px 3px;
      border-radius: 3px;
    }

    .meta-row {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-bottom: 14px;
    }

    .meta-chip {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      font-family: var(--mono);
      font-size: 11px;
      font-weight: 500;
      color: var(--text-muted);
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 4px 8px;
      white-space: nowrap;
    }

    .meta-chip .ci { font-size: 12px; }

    .meta-chip.ai-guess {
      color: var(--warning);
      background: var(--warning-dim);
      border-color: rgba(255, 215, 64, 0.2);
    }

    .meta-chip.conf-hi { color: var(--accent); background: var(--accent-dim); border-color: rgba(0,230,118,0.2); }
    .meta-chip.conf-lo { color: var(--danger); background: var(--danger-dim); border-color: rgba(255,82,82,0.2); }

    .reasons-row {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
      margin-bottom: 14px;
    }

    .reason-tag {
      font-family: var(--mono);
      font-size: 10px;
      font-weight: 500;
      color: var(--text-dim);
      background: var(--surface-2);
      padding: 3px 7px;
      border-radius: 4px;
      letter-spacing: 0.02em;
    }

    .ft-toggle {
      font-family: var(--mono);
      font-size: 11px;
      color: var(--text-dim);
      cursor: pointer;
      padding: 4px 0;
      margin-bottom: 8px;
      user-select: none;
    }
    .ft-toggle:active { color: var(--text-muted); }

    .ft-content {
      display: none;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 12px;
      font-size: 12px;
      color: var(--text-dim);
      line-height: 1.6;
      white-space: pre-wrap;
      max-height: 200px;
      overflow-y: auto;
      margin-bottom: 14px;
    }
    .ft-content.open { display: block; }

    #project-grid-section {
      flex-shrink: 0;
      padding: 4px 16px 8px;
    }

    #project-grid-label {
      font-family: var(--mono);
      font-size: 10px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--text-dim);
      margin-bottom: 6px;
      padding-left: 2px;
    }

    #project-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 6px;
      max-height: 200px;
      overflow-y: auto;
    }

    .pbtn {
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--text);
      font-family: var(--sans);
      font-size: 12px;
      font-weight: 500;
      padding: 10px 6px;
      min-height: 48px;
      cursor: pointer;
      text-align: center;
      transition: background 100ms, border-color 100ms, transform 80ms;
      line-height: 1.2;
      word-break: break-word;
      display: flex;
      align-items: center;
      justify-content: center;
      user-select: none;
      -webkit-user-select: none;
    }

    .pbtn:active {
      transform: scale(0.96);
      background: var(--surface-3);
    }

    .pbtn.suggested {
      border-color: var(--accent);
      box-shadow: 0 0 12px var(--accent-glow), inset 0 0 8px var(--accent-dim);
      color: var(--accent);
      font-weight: 600;
    }

    .pbtn.suggested:active {
      background: var(--accent-dim);
    }

    .pbtn.picked {
      background: var(--accent);
      color: var(--bg);
      font-weight: 700;
      border-color: var(--accent);
      transform: scale(0.96);
    }

    #action-bar {
      flex-shrink: 0;
      background: var(--surface);
      border-top: 1px solid var(--border);
      padding: 10px 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }

    .abtn {
      font-family: var(--mono);
      font-size: 13px;
      font-weight: 600;
      border: none;
      border-radius: 10px;
      padding: 12px 20px;
      cursor: pointer;
      min-height: 48px;
      display: flex;
      align-items: center;
      gap: 6px;
      transition: background 100ms, transform 80ms, opacity 200ms;
      user-select: none;
    }
    .abtn:active { transform: scale(0.96); }

    .undo-btn {
      background: var(--surface-2);
      color: var(--text-muted);
      border: 1px solid var(--border);
      flex: 1;
      opacity: 0;
      pointer-events: none;
    }
    .undo-btn.vis {
      opacity: 1;
      pointer-events: auto;
    }
    .undo-btn:active { background: var(--surface-3); }

    #stats-bar {
      flex-shrink: 0;
      background: var(--bg);
      border-top: 1px solid var(--border);
      padding: 8px 16px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 16px;
      font-family: var(--mono);
      font-size: 11px;
      color: var(--text-dim);
    }

    .si {
      display: flex;
      align-items: center;
      gap: 5px;
    }

    .sd {
      width: 6px;
      height: 6px;
      border-radius: 50%;
    }
    .sd.g { background: var(--accent); }
    .sd.r { background: var(--danger); }
    .sd.a { background: var(--warning); }

    #toast {
      position: fixed;
      bottom: 120px;
      left: 50%;
      transform: translateX(-50%) translateY(20px);
      background: var(--surface-2);
      border: 1px solid var(--accent);
      color: var(--accent);
      font-family: var(--mono);
      font-size: 13px;
      font-weight: 500;
      padding: 10px 20px;
      border-radius: 100px;
      opacity: 0;
      pointer-events: none;
      transition: opacity 200ms, transform 200ms;
      z-index: 50;
      white-space: nowrap;
    }
    #toast.vis {
      opacity: 1;
      transform: translateX(-50%) translateY(0);
      pointer-events: auto;
    }

    #loading-screen {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100dvh;
      gap: 16px;
    }

    .loader {
      width: 36px;
      height: 36px;
      border: 3px solid var(--surface-2);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: spin 0.7s linear infinite;
    }

    @keyframes spin { to { transform: rotate(360deg); } }

    .loader-text {
      font-family: var(--mono);
      font-size: 13px;
      color: var(--text-dim);
    }

    #empty-state {
      display: none;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100%;
      gap: 12px;
      padding: 40px;
      text-align: center;
    }

    #empty-state .e-icon { font-size: 48px; }
    #empty-state .e-title {
      font-family: var(--mono);
      font-size: 18px;
      font-weight: 700;
      color: var(--accent);
    }
    #empty-state .e-sub {
      font-size: 14px;
      color: var(--text-muted);
      line-height: 1.5;
    }

    ::-webkit-scrollbar { width: 4px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: var(--surface-3); border-radius: 2px; }

    @supports (padding-bottom: env(safe-area-inset-bottom)) {
      #stats-bar { padding-bottom: calc(8px + env(safe-area-inset-bottom)); }
    }

    .summary-text {
      font-size: 13px;
      color: var(--text-muted);
      line-height: 1.5;
      margin-bottom: 14px;
    }

    #progress-bar-wrap {
      width: 100%;
      height: 3px;
      background: var(--surface-2);
      position: relative;
    }
    #progress-bar-fill {
      height: 100%;
      background: #30D158;
      transition: width 300ms ease;
      border-radius: 0 2px 2px 0;
    }

    .streak-badge {
      font-family: var(--mono);
      font-size: 11px;
      font-weight: 600;
      color: #FFD740;
      background: rgba(255,215,64,0.15);
      padding: 2px 8px;
      border-radius: 100px;
      margin-left: 8px;
    }

    .direction-row {
      font-family: var(--mono);
      font-size: 12px;
      color: var(--text-muted);
      margin-bottom: 10px;
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .none-btn {
      background: var(--danger-dim);
      color: var(--danger);
      border: 1px solid rgba(255,82,82,0.25);
      flex: 1;
    }
    .none-btn:active { background: rgba(255,82,82,0.25); }

    .skip-btn {
      background: var(--surface-2);
      color: var(--text-muted);
      border: 1px solid var(--border);
      flex: 1;
    }
    .skip-btn:active { background: var(--surface-3); }
  </style>
</head>
<body>
  <div id="app">
    <div id="loading-screen">
      <div class="loader"></div>
      <div class="loader-text">Loading review queue...</div>
    </div>
  </div>

  <div id="toast"></div>

  <script>
    (function() {
      "use strict";

      var BASE = window.location.origin + window.location.pathname;
      if (BASE.endsWith("/")) BASE = BASE.slice(0, -1);

      var S = {
        items: [],
        projects: [],
        pmap: {},
        idx: 0,
        total: 0,
        resolved: 0,
        dismissed: 0,
        skipped: 0,
        streak: 0,
        t0: Date.now(),
        hist: [],
        uTimer: null,
        uCount: 5,
        uTick: null
      };

      function esc(t) {
        if (!t) return "";
        var d = document.createElement("div");
        d.textContent = t;
        return d.innerHTML;
      }

      function hlTerms(text, terms) {
        if (!text || !terms || terms.length === 0) return esc(text);
        var out = esc(text);
        var escRe = /[-\\/\\\\^$*+?.()|[\\]{}]/g;
        for (var i = 0; i < terms.length; i++) {
          var t = terms[i];
          if (!t) continue;
          var safe = t.replace(escRe, "\\\\$&");
          var re = new RegExp("(" + safe + ")", "gi");
          out = out.replace(re, '<span class="hl">$1</span>');
        }
        return out;
      }

      function toast(msg, ms) {
        var el = document.getElementById("toast");
        el.textContent = msg;
        el.classList.add("vis");
        setTimeout(function() { el.classList.remove("vis"); }, ms || 2500);
      }

      async function apiQueue() {
        var r = await fetch(BASE + "?action=queue&limit=50");
        var d = await r.json();
        if (!d.ok) throw new Error(d.error || "Queue fetch failed");
        return d;
      }

      async function apiResolve(qid, pid) {
        var r = await fetch(BASE + "?action=resolve", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ review_queue_id: qid, project_id: pid, user_id: "chad", source: "pipeline" })
        });
        return await r.json();
      }

      async function apiDismiss(qid) {
        var r = await fetch(BASE + "?action=dismiss", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ review_queue_id: qid, user_id: "chad_bootstrap", source: "pipeline" })
        });
        return await r.json();
      }

      async function apiUndo(qid) {
        var r = await fetch(BASE + "?action=undo", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ review_queue_id: qid, source: "pipeline" })
        });
        return await r.json();
      }

      function rate() {
        var mins = (Date.now() - S.t0) / 60000;
        if (mins < 0.1) return "---";
        return ((S.resolved + S.dismissed) / mins).toFixed(1);
      }

      function matchedTerms(item) {
        var terms = [];
        var cp = item.context_payload || {};
        if (cp.provenance && cp.provenance.matched_terms) {
          terms = terms.concat(cp.provenance.matched_terms);
        }
        if (cp.anchors && Array.isArray(cp.anchors)) {
          for (var i = 0; i < cp.anchors.length; i++) {
            if (cp.anchors[i].text) terms.push(cp.anchors[i].text);
          }
        }
        var unique = [];
        for (var j = 0; j < terms.length; j++) {
          if (unique.indexOf(terms[j]) === -1) unique.push(terms[j]);
        }
        return unique;
      }

      function aiGuess(item) {
        var cp = item.context_payload || {};
        var gid = item.ai_guess_project_id || cp.candidate_project_id;
        var conf = item.confidence || cp.candidate_confidence;
        if (!gid) return null;
        return { id: gid, name: S.pmap[gid] || "Unknown", conf: conf };
      }

      function snippet(item) {
        var cp = item.context_payload || {};
        return item.transcript_segment || cp.transcript_snippet || item.human_summary || "";
      }

      function render() {
        var app = document.getElementById("app");
        var item = S.items[S.idx];

        if (!item) {
          renderEmpty(app);
          return;
        }

        var guess = aiGuess(item);
        var terms = matchedTerms(item);
        var snip = snippet(item);
        var done = S.resolved + S.dismissed;
        var tot = S.total + done;
        var pctDone = tot > 0 ? Math.round((done / tot) * 100) : 0;
        var cVal = guess ? guess.conf : null;
        var cPct = cVal ? Math.round(cVal * 100) : null;
        var cCls = cVal ? (cVal >= 0.65 ? "conf-hi" : "conf-lo") : "";

        var h = "";

        h += '<div id="header">';
        h += '<div id="header-left">';
        h += '<div id="header-logo">B</div>';
        h += '<div id="header-title">Bootstrap Review</div>';
        h += '</div>';
        h += '<div id="progress-badge">' + esc(String(done)) + " / " + esc(String(tot));
        if (S.streak >= 5) h += '<span class="streak-badge">' + S.streak + ' streak</span>';
        h += '</div>';
        h += '</div>';

        h += '<div id="progress-bar-wrap"><div id="progress-bar-fill" style="width:' + pctDone + '%"></div></div>';

        h += '<div id="card-area">';
        h += '<div class="triage-card" id="cc">';

        if (item.contact_name) {
          h += '<div class="direction-row">';
          h += '<span>&#x1F4DE;</span> ';
          h += '<span>' + esc(item.contact_name) + ' &#x2192; Zack</span>';
          h += '</div>';
        }

        h += '<div class="card-section-label">Transcript</div>';
        h += '<div class="transcript-box">' + hlTerms(snip, terms) + '</div>';

        h += '<div class="meta-row">';
        if (guess) {
          h += '<div class="meta-chip ai-guess"><span class="ci">&#x1F52E;</span> AI: ' + esc(guess.name) + '</div>';
        }
        if (cPct !== null) {
          h += '<div class="meta-chip ' + cCls + '"><span class="ci">&#x25C9;</span> ' + cPct + '%</div>';
        }
        if (terms.length > 0) {
          h += '<div class="meta-chip"><span class="ci">&#x1F4CE;</span> ' + esc(terms.join(", ")) + '</div>';
        }
        if (item.contact_name) {
          h += '<div class="meta-chip"><span class="ci">&#x1F464;</span> ' + esc(item.contact_name) + '</div>';
        }
        h += '</div>';

        var reasons = item.reason_codes || item.reasons || [];
        if (reasons.length > 0) {
          h += '<div class="reasons-row">';
          for (var ri = 0; ri < reasons.length; ri++) {
            h += '<div class="reason-tag">' + esc(String(reasons[ri])) + '</div>';
          }
          h += '</div>';
        }

        if (item.human_summary && item.human_summary !== snip) {
          h += '<div class="card-section-label">Call Summary</div>';
          h += '<div class="summary-text">' + esc(item.human_summary) + '</div>';
        }

        if (item.full_transcript) {
          h += '<div class="ft-toggle" data-action="toggle-ft">&#x25B6; Show full transcript</div>';
          h += '<div class="ft-content" id="ftb">' + esc(item.full_transcript) + '</div>';
        }

        h += '</div>';
        h += '</div>';

        h += '<div id="project-grid-section">';
        h += '<div id="project-grid-label">Assign to project</div>';
        h += '<div id="project-grid">';
        for (var pi = 0; pi < S.projects.length; pi++) {
          var p = S.projects[pi];
          var isSug = guess && p.id === guess.id;
          var pcls = "pbtn" + (isSug ? " suggested" : "");
          h += '<button class="' + pcls + '" data-action="assign" data-pid="' + esc(p.id) + '">' + esc(p.name) + '</button>';
        }
        h += '</div>';
        h += '</div>';

        h += '<div id="action-bar">';
        h += '<button class="abtn undo-btn' + (S.hist.length > 0 && S.uTimer ? " vis" : "") + '" data-action="undo">';
        h += '&#x21A9; Undo';
        if (S.uTimer) h += ' ' + S.uCount + 's';
        h += '</button>';
        h += '<button class="abtn skip-btn" data-action="skip">SKIP &#x2192;</button>';
        h += '<button class="abtn none-btn" data-action="none">NONE</button>';
        h += '</div>';

        h += '<div id="stats-bar">';
        h += '<div class="si"><span class="sd g"></span> ' + S.resolved + ' resolved</div>';
        h += '<div class="si"><span class="sd r"></span> ' + S.dismissed + ' dismissed</div>';
        h += '<div class="si"><span class="sd a"></span> ' + rate() + '/min</div>';
        h += '</div>';

        app.textContent = "";
        app.insertAdjacentHTML("afterbegin", h);
      }

      function renderEmpty(app) {
        var h = '';
        h += '<div id="header">';
        h += '<div id="header-left">';
        h += '<div id="header-logo">B</div>';
        h += '<div id="header-title">Bootstrap Review</div>';
        h += '</div>';
        h += '<div id="progress-badge">DONE</div>';
        h += '</div>';
        h += '<div id="empty-state" style="display:flex">';
        h += '<div class="e-icon">&#x1F389;</div>';
        h += '<div class="e-title">All caught up!</div>';
        h += '<div class="e-sub">' + S.resolved + ' resolved, ' + S.dismissed + ' dismissed in ' + Math.round((Date.now() - S.t0) / 60000) + ' min</div>';
        h += '<div class="e-sub" style="margin-top:8px">Pull to refresh or come back later.</div>';
        h += '</div>';
        h += '<div id="stats-bar">';
        h += '<div class="si"><span class="sd g"></span> ' + S.resolved + ' resolved</div>';
        h += '<div class="si"><span class="sd r"></span> ' + S.dismissed + ' dismissed</div>';
        h += '<div class="si"><span class="sd a"></span> ' + rate() + '/min</div>';
        h += '</div>';
        app.textContent = "";
        app.insertAdjacentHTML("afterbegin", h);
      }

      async function doAssign(pid) {
        var item = S.items[S.idx];
        if (!item) return;

        var btns = document.querySelectorAll('[data-action="assign"]');
        for (var i = 0; i < btns.length; i++) {
          if (btns[i].dataset.pid === pid) {
            btns[i].classList.add("picked");
          }
          btns[i].style.pointerEvents = "none";
        }

        var card = document.getElementById("cc");
        if (card) {
          setTimeout(function() { card.classList.add("card-exiting"); }, 50);
        }

        var result = await apiResolve(item.id, pid);
        if (!result.ok && result.error_code !== "rpc_failed") {
          toast("Error: " + (result.error || result.error_code), 3000);
          render();
          return;
        }

        S.hist.push({ type: "resolve", qid: item.id, pid: pid, ts: Date.now() });
        S.resolved++;
        S.streak++;

        var pName = S.pmap[pid] || "Project";
        toast("Assigned to " + pName, 1800);

        startUndo();
        S.idx++;
        setTimeout(render, 200);
      }

      function doSkip() {
        var item = S.items[S.idx];
        if (!item) return;

        var card = document.getElementById("cc");
        if (card) card.classList.add("card-exiting");

        // Move item to back of local queue — no API call
        S.items.push(S.items.splice(S.idx, 1)[0]);
        S.skipped++;
        S.streak = 0;
        toast("Skipped — moved to back", 1500);
        setTimeout(render, 200);
      }

      async function doNone() {
        var item = S.items[S.idx];
        if (!item) return;

        var card = document.getElementById("cc");
        if (card) card.classList.add("card-exiting");

        var result = await apiDismiss(item.id);
        if (!result.ok) {
          toast("Dismiss failed", 2000);
          render();
          return;
        }

        S.hist.push({ type: "dismiss", qid: item.id, ts: Date.now() });
        S.dismissed++;
        S.streak = 0;
        startUndo();
        S.idx++;
        toast("Dismissed — no project", 1500);
        setTimeout(render, 200);
      }

      async function doUndo() {
        if (S.hist.length === 0) return;
        clearUndo();
        var last = S.hist.pop();

        var result = await apiUndo(last.qid);
        if (!result.ok && result.error_code !== "undo_window_expired") {
          toast("Undo failed: " + (result.error || result.error_code), 3000);
          return;
        }
        if (result.error_code === "undo_window_expired") {
          toast("Undo window expired", 2500);
          return;
        }

        if (last.type === "resolve") S.resolved = Math.max(0, S.resolved - 1);
        if (last.type === "dismiss") S.dismissed = Math.max(0, S.dismissed - 1);

        S.idx = Math.max(0, S.idx - 1);
        toast("Undone", 1500);
        render();
      }

      function startUndo() {
        clearUndo();
        S.uCount = 5;

        S.uTick = setInterval(function() {
          S.uCount--;
          var btn = document.querySelector('[data-action="undo"]');
          if (btn && S.uCount > 0) {
            btn.textContent = "\\u21A9 Undo " + S.uCount + "s";
          }
          if (S.uCount <= 0) {
            clearUndo();
            render();
          }
        }, 1000);

        S.uTimer = setTimeout(function() {
          clearUndo();
          render();
        }, 5500);
      }

      function clearUndo() {
        if (S.uTimer) { clearTimeout(S.uTimer); S.uTimer = null; }
        if (S.uTick) { clearInterval(S.uTick); S.uTick = null; }
      }

      document.addEventListener("click", function(e) {
        var btn = e.target.closest("[data-action]");
        if (!btn) return;

        var act = btn.dataset.action;

        if (act === "assign") {
          doAssign(btn.dataset.pid);
          return;
        }
        if (act === "skip") {
          doSkip();
          return;
        }
        if (act === "none") {
          doNone();
          return;
        }
        if (act === "undo") {
          doUndo();
          return;
        }
        if (act === "toggle-ft") {
          var body = document.getElementById("ftb");
          if (body) {
            body.classList.toggle("open");
            btn.textContent = body.classList.contains("open")
              ? "\\u25BC Hide full transcript"
              : "\\u25B6 Show full transcript";
          }
          return;
        }
      });

      async function init() {
        try {
          var data = await apiQueue();
          S.items = data.items || [];
          S.projects = data.projects || [];
          S.total = data.total_pending || S.items.length;

          S.pmap = {};
          for (var i = 0; i < S.projects.length; i++) {
            S.pmap[S.projects[i].id] = S.projects[i].name;
          }

          S.t0 = Date.now();
          render();
        } catch (err) {
          var app = document.getElementById("app");
          app.textContent = "Error: " + err.message;
        }
      }

      init();
    })();
  </script>
</body>
</html>`;
}

// ─── Main router ─────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  const t0 = Date.now();
  const url = new URL(req.url);
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const action = url.searchParams.get("action");

    // POST endpoints
    if (req.method === "POST") {
      if (action === "resolve") {
        return await handleResolve(db, req, t0);
      }
      if (action === "dismiss") {
        return await handleDismiss(db, req, t0);
      }
      if (action === "undo") {
        return await handleUndo(db, req, t0);
      }
      return json({ ok: false, error_code: "unknown_action" }, 400);
    }

    // GET endpoints
    if (action === "queue") {
      const rawLimit = parseInt(url.searchParams.get("limit") || "30", 10);
      const limit = Math.min(
        Math.max(isNaN(rawLimit) ? 30 : rawLimit, 1),
        100,
      );
      return await handleQueue(db, limit, t0);
    }
    if (action === "projects") {
      return await handleProjects(db, t0);
    }

    // Default: serve HTML UI
    return new Response(HTML, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8", ...corsHeaders() },
    });
  } catch (err: any) {
    console.error("[bootstrap-review] Error:", err.message);
    return json({
      ok: false,
      error_code: "internal_error",
      error: err.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
});
