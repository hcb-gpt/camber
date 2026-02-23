export type JsonValue = string | number | boolean | null | JsonValue[] | { [k: string]: JsonValue };
export type JsonObj = { [k: string]: JsonValue };

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
  };
  manifest: JsonObj[];
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

      @media (max-width: 760px) {
        .wrap {
          padding: 14px;
        }
        th,
        td {
          padding: 10px 8px;
          font-size: 0.88rem;
        }
      }
    </style>
  </head>
  <body>
    <main class="wrap">
      <section class="hero">
        <h1>Morning Manifest Dashboard</h1>
        <p class="meta">Generated at ${escapeHtml(payload.generated_at)} | Showing up to ${formatInt(limit)} rows | Function ${escapeHtml(payload.function_version)}</p>
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
    </main>
  </body>
</html>`;
}
