/**
 * morning-manifest-site Edge Function v0.1.2
 *
 * Standalone HTML wrapper that serves a browser-friendly morning manifest page.
 * - verify_jwt=false (public HTML page)
 * - Uses in-browser Supabase Auth (supabase-js CDN) with ANON key
 * - After auth, calls morning-manifest-ui endpoint with user's JWT
 * - Renders a clean table of morning manifest items
 *
 * NOTE: Uses "Text/Html" (mixed case) for content-type to bypass Supabase
 * gateway sandbox (sb-gateway-version:1 case-sensitively matches "text/html"
 * and rewrites to text/plain + sandbox CSP). Browsers parse MIME types
 * case-insensitively per RFC 2616 §3.7.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const FUNCTION_VERSION = "v0.1.2";

Deno.serve((_req: Request) => {
  if (_req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  const html = buildPage(supabaseUrl, supabaseAnonKey, FUNCTION_VERSION);
  const headers = new Headers({
    "content-type": "Text/Html; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });

  return new Response(html, { status: 200, headers });
});

function escapeAttr(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function buildPage(supabaseUrl: string, anonKey: string, version: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Morning Manifest</title>
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"><\/script>
  <style>
    @import url("https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;700&family=IBM+Plex+Mono:wght@400;600&display=swap");

    :root {
      --bg: #f5f7f2; --ink: #11231f; --muted: #44615c;
      --card: #ffffff; --line: #c7d8d2;
      --accent: #0b8f72; --accent-soft: #dff6ef;
      --warn: #bc5f14; --warn-soft: #fdeedc;
      --high: #9f2222; --high-soft: #f9e3e3;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Space Grotesk", "Avenir Next", "Segoe UI", sans-serif;
      color: var(--ink);
      background: radial-gradient(circle at 90% -10%, #d8efe8 0%, rgba(216,239,232,0) 48%),
                  linear-gradient(160deg, #f7faf6 0%, #edf3ee 100%);
    }
    .wrap { max-width: 1200px; margin: 0 auto; padding: 24px; }
    .hero { display: grid; gap: 12px; margin-bottom: 20px; }
    h1 { margin: 0; font-size: clamp(1.7rem, 3.4vw, 2.8rem); letter-spacing: -0.02em; }
    .meta { margin: 0; color: var(--muted); font-size: 0.95rem; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; margin-bottom: 16px; }
    .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 14px; box-shadow: 0 10px 24px rgba(27,51,45,0.06); }
    .label { color: var(--muted); font-size: 0.82rem; text-transform: uppercase; letter-spacing: 0.08em; }
    .value { margin-top: 6px; font-size: 1.8rem; line-height: 1; font-weight: 700; }
    .table-wrap { background: var(--card); border: 1px solid var(--line); border-radius: 16px; overflow: hidden; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 12px; text-align: left; border-bottom: 1px solid #e7efeb; vertical-align: top; }
    th { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.07em; color: var(--muted); background: #f4faf7; }
    tr:last-child td { border-bottom: none; }
    .project-name { font-weight: 600; }
    .project-id { margin-top: 4px; font-family: "IBM Plex Mono", ui-monospace, monospace; font-size: 0.74rem; color: var(--muted); }
    .pill { display: inline-block; border-radius: 999px; padding: 3px 10px; font-size: 0.82rem; font-weight: 600; }
    .pill.low { color: var(--accent); background: var(--accent-soft); }
    .pill.med { color: var(--warn); background: var(--warn-soft); }
    .pill.high { color: var(--high); background: var(--high-soft); }
    .warning { margin-top: 12px; padding: 10px 12px; border-radius: 10px; border: 1px solid #f3d4af; background: #fff5e8; color: #7a450f; font-size: 0.9rem; }

    /* Auth form */
    .auth-container { max-width: 420px; margin: 80px auto; padding: 32px; background: var(--card); border: 1px solid var(--line); border-radius: 16px; box-shadow: 0 10px 24px rgba(27,51,45,0.06); }
    .auth-container h2 { margin: 0 0 4px; font-size: 1.4rem; }
    .auth-container p { margin: 0 0 20px; color: var(--muted); font-size: 0.9rem; }
    .auth-container label { display: block; margin-bottom: 4px; font-size: 0.85rem; font-weight: 500; color: var(--muted); }
    .auth-container input { width: 100%; padding: 10px 12px; margin-bottom: 14px; border: 1px solid var(--line); border-radius: 8px; font-size: 0.95rem; font-family: inherit; }
    .auth-container button {
      width: 100%; padding: 12px; border: none; border-radius: 8px;
      background: var(--accent); color: #fff; font-size: 1rem; font-weight: 600;
      font-family: inherit; cursor: pointer;
    }
    .auth-container button:hover { opacity: 0.9; }
    .auth-error { margin-top: 12px; padding: 10px 12px; border-radius: 8px; background: var(--high-soft); color: var(--high); font-size: 0.88rem; display: none; }

    /* Loading spinner */
    .loading { text-align: center; padding: 60px 20px; color: var(--muted); font-size: 1.1rem; }
    .loading::after { content: ""; display: block; width: 32px; height: 32px; margin: 16px auto 0; border: 3px solid var(--line); border-top-color: var(--accent); border-radius: 50%; animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }

    #auth-section, #manifest-section { display: none; }

    @media (max-width: 760px) {
      .wrap { padding: 14px; }
      th, td { padding: 10px 8px; font-size: 0.88rem; }
    }
  </style>
</head>
<body>
  <div id="loading-section" class="loading">Checking session...</div>

  <div id="auth-section">
    <div class="auth-container">
      <h2>Morning Manifest</h2>
      <p>Sign in with your Camber account to view the manifest.</p>
      <form id="login-form">
        <label for="email">Email</label>
        <input type="email" id="email" name="email" required autocomplete="email" />
        <label for="password">Password</label>
        <input type="password" id="password" name="password" required autocomplete="current-password" />
        <button type="submit">Sign In</button>
      </form>
      <div id="auth-error" class="auth-error"></div>
    </div>
  </div>

  <div id="manifest-section">
    <main class="wrap">
      <section class="hero">
        <h1>Morning Manifest</h1>
        <p class="meta" id="manifest-meta"></p>
      </section>
      <section class="cards" id="summary-cards"></section>
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
          <tbody id="manifest-tbody"></tbody>
        </table>
      </section>
      <div id="manifest-warning"></div>
      <p style="margin-top:16px;text-align:right;">
        <button id="signout-btn" style="background:none;border:1px solid var(--line);border-radius:8px;padding:8px 16px;cursor:pointer;font-family:inherit;color:var(--muted);">Sign Out</button>
      </p>
    </main>
  </div>

  <script>
    // All dynamic values are sanitized via textContent or the esc() function
    // before DOM insertion. Data originates from our own authenticated API.
    var SUPABASE_URL = "${escapeAttr(supabaseUrl)}";
    var SUPABASE_ANON_KEY = "${escapeAttr(anonKey)}";
    var MANIFEST_UI_URL = SUPABASE_URL + "/functions/v1/morning-manifest-ui";
    var FUNCTION_VERSION = "${escapeAttr(version)}";

    var sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

    var loadingEl = document.getElementById("loading-section");
    var authEl = document.getElementById("auth-section");
    var manifestEl = document.getElementById("manifest-section");
    var authErrorEl = document.getElementById("auth-error");

    function showSection(name) {
      loadingEl.style.display = name === "loading" ? "block" : "none";
      authEl.style.display = name === "auth" ? "block" : "none";
      manifestEl.style.display = name === "manifest" ? "block" : "none";
    }

    function fmtInt(n) {
      var v = typeof n === "number" ? n : Number(n);
      if (!isFinite(v)) v = 0;
      return Math.round(v).toLocaleString("en-US");
    }

    function pillClass(n) {
      if (n >= 10) return "high";
      if (n >= 3) return "med";
      return "low";
    }

    function createTextEl(tag, text, className) {
      var el = document.createElement(tag);
      el.textContent = text;
      if (className) el.className = className;
      return el;
    }

    function createCell(text) {
      var td = document.createElement("td");
      td.textContent = text;
      return td;
    }

    function createProjectCell(name, id) {
      var td = document.createElement("td");
      var nameDiv = document.createElement("div");
      nameDiv.className = "project-name";
      nameDiv.textContent = name || "Unknown Project";
      var idDiv = document.createElement("div");
      idDiv.className = "project-id";
      idDiv.textContent = id || "n/a";
      td.appendChild(nameDiv);
      td.appendChild(idDiv);
      return td;
    }

    function createPillCell(value) {
      var td = document.createElement("td");
      var span = document.createElement("span");
      span.className = "pill " + pillClass(value);
      span.textContent = fmtInt(value);
      td.appendChild(span);
      return td;
    }

    function createSummaryCard(label, value) {
      var article = document.createElement("article");
      article.className = "card";
      var labelDiv = document.createElement("div");
      labelDiv.className = "label";
      labelDiv.textContent = label;
      var valueDiv = document.createElement("div");
      valueDiv.className = "value";
      valueDiv.textContent = value;
      article.appendChild(labelDiv);
      article.appendChild(valueDiv);
      return article;
    }

    async function loadManifest(token) {
      var resp = await fetch(MANIFEST_UI_URL + "?format=json&limit=100", {
        headers: { "Authorization": "Bearer " + token }
      });
      if (!resp.ok) {
        throw new Error("Manifest API returned " + resp.status);
      }
      return resp.json();
    }

    function renderManifest(data) {
      document.getElementById("manifest-meta").textContent =
        "Generated at " + (data.generated_at || "unknown") +
        " | " + (data.summary.project_row_count || 0) + " projects" +
        " | " + data.ms + "ms | " + FUNCTION_VERSION;

      var cardsEl = document.getElementById("summary-cards");
      cardsEl.replaceChildren(
        createSummaryCard("Projects In Manifest", fmtInt(data.summary.project_row_count)),
        createSummaryCard("Pending Review Queue", fmtInt(data.summary.pending_review_count || 0)),
        createSummaryCard("Request Runtime", fmtInt(data.ms) + "ms")
      );

      var rows = (data.manifest || []).slice().sort(function(a, b) {
        var pd = (Number(b.pending_reviews) || 0) - (Number(a.pending_reviews) || 0);
        if (pd !== 0) return pd;
        var cd = (Number(b.new_calls) || 0) - (Number(a.new_calls) || 0);
        if (cd !== 0) return cd;
        return String(a.project_name || "").localeCompare(String(b.project_name || ""));
      });

      var tbody = document.getElementById("manifest-tbody");
      tbody.replaceChildren();

      if (rows.length === 0) {
        var emptyRow = document.createElement("tr");
        var emptyCell = document.createElement("td");
        emptyCell.setAttribute("colspan", "7");
        emptyCell.textContent = "No manifest rows returned.";
        emptyRow.appendChild(emptyCell);
        tbody.appendChild(emptyRow);
      } else {
        rows.forEach(function(row) {
          var tr = document.createElement("tr");
          tr.appendChild(createProjectCell(row.project_name, row.project_id));
          tr.appendChild(createCell(fmtInt(row.new_calls)));
          tr.appendChild(createCell(fmtInt(row.new_journal_entries)));
          tr.appendChild(createCell(fmtInt(row.new_belief_claims)));
          tr.appendChild(createCell(fmtInt(row.new_striking_signals)));
          tr.appendChild(createPillCell(Number(row.pending_reviews) || 0));
          tr.appendChild(createCell(fmtInt(row.newly_resolved_reviews)));
          tbody.appendChild(tr);
        });
      }

      var warningEl = document.getElementById("manifest-warning");
      warningEl.replaceChildren();
      if (data.summary.review_queue_warning) {
        var warnDiv = document.createElement("div");
        warnDiv.className = "warning";
        warnDiv.textContent = "Review queue warning: " + data.summary.review_queue_warning;
        warningEl.appendChild(warnDiv);
      }

      showSection("manifest");
    }

    async function handleSession(session) {
      if (!session) {
        showSection("auth");
        return;
      }
      showSection("loading");
      try {
        var data = await loadManifest(session.access_token);
        if (!data.ok) throw new Error(data.error || "API error");
        renderManifest(data);
      } catch (err) {
        console.error("Failed to load manifest:", err);
        showSection("auth");
        authErrorEl.style.display = "block";
        authErrorEl.textContent = "Failed to load manifest: " + err.message;
      }
    }

    async function signOut() {
      await sb.auth.signOut();
      showSection("auth");
    }

    document.getElementById("signout-btn").addEventListener("click", signOut);

    document.getElementById("login-form").addEventListener("submit", async function(e) {
      e.preventDefault();
      authErrorEl.style.display = "none";
      var email = document.getElementById("email").value;
      var password = document.getElementById("password").value;
      var result = await sb.auth.signInWithPassword({ email: email, password: password });
      if (result.error) {
        authErrorEl.style.display = "block";
        authErrorEl.textContent = result.error.message;
        return;
      }
      handleSession(result.data.session);
    });

    // Check existing session on load
    (async function() {
      var result = await sb.auth.getSession();
      handleSession(result.data.session);
    })();
  <\/script>
</body>
</html>`;
}
