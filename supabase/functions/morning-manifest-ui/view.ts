export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [k: string]: JsonValue };
export type JsonObj = { [k: string]: JsonValue };

export type AnchorEntry = {
  quote: string;
  type?: string;
  source?: string;
};

export type CandidateEntry = {
  project_id: string;
  project_name: string;
  score: number;
  reason?: string;
};

export type SpanDetail = {
  span_index: number;
  project_name: string;
  decision: string;
  confidence: number;
  reasoning: string;
  anchors: AnchorEntry[];
  candidates: CandidateEntry[];
};

export type CallAttributionDetail = {
  interaction_id: string;
  contact_name: string;
  call_date: string;
  span_count: number;
  spans: SpanDetail[];
};

export type ReviewQueueSummary = {
  pending_total: number;
  pending_attribution: number;
  pending_coverage_gap: number;
  pending_weak_anchor: number;
  latest_pending_created_at: string | null;
};

export type ReviewQueueReasonDaily = {
  day: string;
  module: string;
  reason_code: string;
  pending_count: number;
  first_seen_at: string;
  last_seen_at: string;
};

export type ReviewQueueTopInteraction = {
  interaction_id: string;
  module: string;
  pending_count: number;
  reason_codes: string[];
  first_seen_at: string;
  last_seen_at: string;
};

export type ManifestResponse = {
  ok: boolean;
  function_version: string;
  generated_at: string;
  ms: number;
  user: {
    id: string;
    email: string | null;
    role: string | null;
  };
  summary: {
    project_row_count: number;
    pending_review_count: number | null;
    review_queue_warning: string | null;
    review_queue_rollup?: ReviewQueueSummary | null;
  };
  manifest: JsonObj[];
  attribution_details?: CallAttributionDetail[];
  review_queue_reason_daily?: ReviewQueueReasonDaily[];
  review_queue_top_interactions?: ReviewQueueTopInteraction[];
};

export function wantsHtmlResponse(req: Request, url: URL): boolean {
  const format = (url.searchParams.get("format") ?? "").trim().toLowerCase();
  if (format === "json") return false;
  if (format === "html" || format === "ui") return true;
  const accept = req.headers.get("accept") ?? "";
  return accept.toLowerCase().includes("text/html");
}

function asNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return 0;
}

function formatInt(value: number): string {
  return Math.round(value).toLocaleString("en-US");
}

function escapeHtml(input: unknown): string {
  return String(input ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function renderAnchorHtml(anchors: AnchorEntry[]): string {
  if (anchors.length === 0) return "";
  const items = anchors.map((a) => {
    const typeLabel = a.type ? ` <span class="anchor-type">${escapeHtml(a.type)}</span>` : "";
    return `<li class="anchor-item">&ldquo;${escapeHtml(a.quote)}&rdquo;${typeLabel}</li>`;
  }).join("");
  return `<ul class="anchor-list">${items}</ul>`;
}

function renderCandidatesHtml(candidates: CandidateEntry[]): string {
  if (candidates.length === 0) return "";
  const rows = candidates.map((c) => {
    const pct = Math.round(c.score * 100);
    const reason = c.reason ? ` &mdash; ${escapeHtml(c.reason)}` : "";
    return `<li class="candidate-item"><strong>${escapeHtml(c.project_name)}</strong> (${pct}%)${reason}</li>`;
  }).join("");
  return `<div class="candidates-section"><span class="detail-label">Candidates:</span><ul class="candidate-list">${rows}</ul></div>`;
}

function decisionPillClass(decision: string): string {
  switch (decision) {
    case "assign":
      return "pill low";
    case "review":
      return "pill med";
    default:
      return "pill none-pill";
  }
}

function renderSpanHtml(span: SpanDetail): string {
  const confPct = Math.round(span.confidence * 100);
  return `
    <div class="span-card">
      <div class="span-header">
        <span class="span-index">Span ${span.span_index}</span>
        <span class="span-project">${escapeHtml(span.project_name)}</span>
        <span class="${decisionPillClass(span.decision)}">${escapeHtml(span.decision)}</span>
      </div>
      <div class="confidence-row">
        <span class="detail-label">Confidence:</span>
        <div class="confidence-bar-track">
          <div class="confidence-bar-fill" style="width:${confPct}%"></div>
        </div>
        <span class="confidence-pct">${confPct}%</span>
      </div>
      ${
    span.reasoning
      ? `<div class="reasoning-row"><span class="detail-label">Reasoning:</span> <span class="reasoning-text">${
        escapeHtml(span.reasoning)
      }</span></div>`
      : ""
  }
      ${renderAnchorHtml(span.anchors)}
      ${renderCandidatesHtml(span.candidates)}
    </div>`;
}

export function renderAttributionDetailHtml(
  details: CallAttributionDetail[] | undefined,
): string {
  if (!details || details.length === 0) {
    return `
      <section class="attribution-section">
        <h2 class="section-title">Recent Attribution Details</h2>
        <p class="empty-state">No recent attribution details available.</p>
      </section>`;
  }

  const cards = details.map((call) => {
    const spansHtml = call.spans.map(renderSpanHtml).join("");
    const callId = escapeHtml(call.interaction_id);
    const shortId = callId.length > 20 ? callId.slice(0, 20) + "&hellip;" : callId;
    return `
      <details class="call-card">
        <summary class="call-summary">
          <div class="call-summary-left">
            <span class="call-contact">${escapeHtml(call.contact_name)}</span>
            <span class="call-date">${escapeHtml(call.call_date)}</span>
          </div>
          <div class="call-summary-right">
            <span class="call-spans-badge">${call.span_count} span${call.span_count !== 1 ? "s" : ""}</span>
            <span class="call-id-mono">${shortId}</span>
          </div>
        </summary>
        <div class="call-detail-body">
          ${spansHtml || `<p class="empty-state">No span attributions found for this call.</p>`}
        </div>
      </details>`;
  }).join("");

  return `
    <section class="attribution-section">
      <h2 class="section-title">Recent Attribution Details</h2>
      ${cards}
    </section>`;
}

export function renderManifestHtml(payload: ManifestResponse, limit: number): string {
  const rows = [...payload.manifest].sort((a, b) => {
    const pendingDelta = asNumber(b.pending_reviews) - asNumber(a.pending_reviews);
    if (pendingDelta !== 0) return pendingDelta;
    const aCalls = asNumber(a.new_calls);
    const bCalls = asNumber(b.new_calls);
    if (bCalls !== aCalls) return bCalls - aCalls;
    return String(a.project_name ?? "").localeCompare(String(b.project_name ?? ""));
  });

  const rowHtml = rows.map((row) => {
    const pendingReviews = asNumber(row.pending_reviews);
    const pendingTone = pendingReviews >= 10 ? "high" : pendingReviews >= 3 ? "med" : "low";
    return `
      <tr>
        <td class="project-cell">
          <div class="project-name">${escapeHtml(row.project_name ?? "Unknown Project")}</div>
          <div class="project-id">${escapeHtml(row.project_id ?? "n/a")}</div>
        </td>
        <td>${formatInt(asNumber(row.new_calls))}</td>
        <td>${formatInt(asNumber(row.new_journal_entries))}</td>
        <td>${formatInt(asNumber(row.new_belief_claims))}</td>
        <td>${formatInt(asNumber(row.new_striking_signals))}</td>
        <td><span class="pill ${pendingTone}">${formatInt(pendingReviews)}</span></td>
        <td>${formatInt(asNumber(row.newly_resolved_reviews))}</td>
      </tr>
    `;
  }).join("");

  const warning = payload.summary.review_queue_warning
    ? `<div class="warning">Review queue warning: ${escapeHtml(payload.summary.review_queue_warning)}</div>`
    : "";

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Morning Manifest Dashboard</title>
    <style>
      @import url("https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;700&family=IBM+Plex+Mono:wght@400;600&display=swap");

      :root {
        --bg: #f5f7f2;
        --ink: #11231f;
        --muted: #44615c;
        --card: #ffffff;
        --line: #c7d8d2;
        --accent: #0b8f72;
        --accent-soft: #dff6ef;
        --warn: #bc5f14;
        --warn-soft: #fdeedc;
        --high: #9f2222;
        --high-soft: #f9e3e3;
      }

      * {
        box-sizing: border-box;
      }

      body {
        margin: 0;
        font-family: "Space Grotesk", "Avenir Next", "Segoe UI", sans-serif;
        color: var(--ink);
        background:
          radial-gradient(circle at 90% -10%, #d8efe8 0%, rgba(216, 239, 232, 0) 48%),
          linear-gradient(160deg, #f7faf6 0%, #edf3ee 100%);
      }

      .wrap {
        max-width: 1200px;
        margin: 0 auto;
        padding: 24px;
      }

      .hero {
        display: grid;
        gap: 12px;
        margin-bottom: 20px;
      }

      h1 {
        margin: 0;
        font-size: clamp(1.7rem, 3.4vw, 2.8rem);
        letter-spacing: -0.02em;
      }

      .meta {
        margin: 0;
        color: var(--muted);
        font-size: 0.95rem;
      }

      .cards {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
        gap: 12px;
        margin-bottom: 16px;
      }

      .card {
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 14px;
        padding: 14px;
        box-shadow: 0 10px 24px rgba(27, 51, 45, 0.06);
      }

      .label {
        color: var(--muted);
        font-size: 0.82rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
      }

      .value {
        margin-top: 6px;
        font-size: 1.8rem;
        line-height: 1;
        font-weight: 700;
      }

      .table-wrap {
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 16px;
        overflow: hidden;
      }

      table {
        width: 100%;
        border-collapse: collapse;
      }

      th,
      td {
        padding: 12px;
        text-align: left;
        border-bottom: 1px solid #e7efeb;
        vertical-align: top;
      }

      th {
        font-size: 0.8rem;
        text-transform: uppercase;
        letter-spacing: 0.07em;
        color: var(--muted);
        background: #f4faf7;
      }

      tr:last-child td {
        border-bottom: none;
      }

      .project-name {
        font-weight: 600;
      }

      .project-id {
        margin-top: 4px;
        font-family: "IBM Plex Mono", ui-monospace, monospace;
        font-size: 0.74rem;
        color: var(--muted);
      }

      .pill {
        display: inline-block;
        border-radius: 999px;
        padding: 3px 10px;
        font-size: 0.82rem;
        font-weight: 600;
      }

      .pill.low {
        color: var(--accent);
        background: var(--accent-soft);
      }

      .pill.med {
        color: var(--warn);
        background: var(--warn-soft);
      }

      .pill.high {
        color: var(--high);
        background: var(--high-soft);
      }

      .warning {
        margin-top: 12px;
        padding: 10px 12px;
        border-radius: 10px;
        border: 1px solid #f3d4af;
        background: #fff5e8;
        color: #7a450f;
        font-size: 0.9rem;
      }

      /* Attribution Detail Section */
      .attribution-section {
        margin-top: 28px;
      }

      .section-title {
        font-size: 1.3rem;
        font-weight: 700;
        margin: 0 0 16px 0;
        letter-spacing: -0.01em;
      }

      .empty-state {
        color: var(--muted);
        font-size: 0.92rem;
        padding: 12px 0;
      }

      .call-card {
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 14px;
        margin-bottom: 10px;
        overflow: hidden;
        box-shadow: 0 4px 12px rgba(27, 51, 45, 0.04);
      }

      .call-card[open] {
        box-shadow: 0 8px 20px rgba(27, 51, 45, 0.08);
      }

      .call-summary {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 14px 18px;
        cursor: pointer;
        user-select: none;
        list-style: none;
      }

      .call-summary::-webkit-details-marker {
        display: none;
      }

      .call-summary::before {
        content: "\u25B6";
        font-size: 0.7rem;
        margin-right: 10px;
        color: var(--muted);
        transition: transform 0.15s ease;
      }

      .call-card[open] > .call-summary::before {
        transform: rotate(90deg);
      }

      .call-summary-left {
        display: flex;
        align-items: center;
        gap: 12px;
      }

      .call-contact {
        font-weight: 600;
        font-size: 0.95rem;
      }

      .call-date {
        color: var(--muted);
        font-size: 0.85rem;
      }

      .call-summary-right {
        display: flex;
        align-items: center;
        gap: 12px;
      }

      .call-spans-badge {
        display: inline-block;
        background: var(--accent-soft);
        color: var(--accent);
        font-size: 0.78rem;
        font-weight: 600;
        padding: 2px 10px;
        border-radius: 999px;
      }

      .call-id-mono {
        font-family: "IBM Plex Mono", ui-monospace, monospace;
        font-size: 0.72rem;
        color: var(--muted);
      }

      .call-detail-body {
        padding: 4px 18px 18px;
      }

      .span-card {
        background: #f8fbf9;
        border: 1px solid #e2ece7;
        border-radius: 10px;
        padding: 12px 14px;
        margin-bottom: 8px;
      }

      .span-header {
        display: flex;
        align-items: center;
        gap: 10px;
        margin-bottom: 8px;
      }

      .span-index {
        font-family: "IBM Plex Mono", ui-monospace, monospace;
        font-size: 0.78rem;
        font-weight: 600;
        color: var(--muted);
      }

      .span-project {
        font-weight: 600;
        font-size: 0.9rem;
      }

      .pill.none-pill {
        color: #5a6b66;
        background: #e8eeeb;
      }

      .confidence-row {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-bottom: 6px;
      }

      .detail-label {
        font-size: 0.78rem;
        text-transform: uppercase;
        letter-spacing: 0.06em;
        color: var(--muted);
        white-space: nowrap;
      }

      .confidence-bar-track {
        flex: 1;
        height: 6px;
        background: #e2ece7;
        border-radius: 3px;
        max-width: 180px;
      }

      .confidence-bar-fill {
        height: 100%;
        background: var(--accent);
        border-radius: 3px;
        transition: width 0.3s ease;
      }

      .confidence-pct {
        font-family: "IBM Plex Mono", ui-monospace, monospace;
        font-size: 0.78rem;
        font-weight: 600;
        min-width: 36px;
      }

      .reasoning-row {
        font-size: 0.88rem;
        line-height: 1.5;
        margin-bottom: 6px;
      }

      .reasoning-text {
        color: var(--ink);
      }

      .anchor-list {
        list-style: none;
        padding: 0;
        margin: 6px 0 4px;
      }

      .anchor-item {
        font-size: 0.84rem;
        color: var(--muted);
        padding: 3px 0;
        border-left: 3px solid var(--accent-soft);
        padding-left: 10px;
        margin-bottom: 4px;
        font-style: italic;
      }

      .anchor-type {
        font-style: normal;
        font-size: 0.72rem;
        background: var(--accent-soft);
        color: var(--accent);
        padding: 1px 6px;
        border-radius: 4px;
        margin-left: 4px;
      }

      .candidates-section {
        margin-top: 6px;
      }

      .candidate-list {
        list-style: none;
        padding: 0;
        margin: 4px 0 0;
      }

      .candidate-item {
        font-size: 0.84rem;
        padding: 2px 0;
      }

      @media (max-width: 760px) {
        .wrap {
          padding: 14px;
        }
        th,
        td {
          padding: 10px 8px;
          font-size: 0.88rem;
        }
        .call-summary {
          flex-direction: column;
          align-items: flex-start;
          gap: 6px;
        }
        .call-summary-right {
          margin-left: 20px;
        }
      }
    </style>
  </head>
  <body>
    <main class="wrap">
      <section class="hero">
        <h1>Morning Manifest Dashboard</h1>
        <p class="meta">Generated at ${escapeHtml(payload.generated_at)} | Showing up to ${
    formatInt(limit)
  } rows | Function ${escapeHtml(payload.function_version)}</p>
      </section>

      <section class="cards">
        <article class="card">
          <div class="label">Projects In Manifest</div>
          <div class="value">${formatInt(payload.summary.project_row_count)}</div>
        </article>
        <article class="card">
          <div class="label">Pending Review Queue</div>
          <div class="value">${formatInt(payload.summary.pending_review_count ?? 0)}</div>
        </article>
        <article class="card">
          <div class="label">Request Runtime</div>
          <div class="value">${formatInt(payload.ms)}ms</div>
        </article>
      </section>

      <section class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Project</th>
              <th>New Calls</th>
              <th>Journal</th>
              <th>Belief Claims</th>
              <th>Strikes</th>
              <th>Pending Reviews</th>
              <th>Resolved Reviews</th>
            </tr>
          </thead>
          <tbody>
            ${rowHtml || `<tr><td colspan="7">No manifest rows returned.</td></tr>`}
          </tbody>
        </table>
      </section>
      ${warning}
      ${renderAttributionDetailHtml(payload.attribution_details)}
    </main>
  </body>
</html>`;
}
