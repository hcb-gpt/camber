/**
 * operator-validation-ui Edge Function v0.1.0
 *
 * Public HTML wrapper for operator attribution validation.
 * - verify_jwt=false (public HTML page)
 * - Uses in-browser Supabase Auth (supabase-js CDN) with ANON key
 * - After auth, calls operator-validation endpoint with user's JWT
 * - Displays spans with evidence, allows CORRECT/INCORRECT/UNSURE verdicts
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const FUNCTION_VERSION = "v0.1.0";

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
  return new Response(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
});

function escapeAttr(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function buildPage(
  supabaseUrl: string,
  anonKey: string,
  version: string,
): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Operator Validation</title>
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"><\/script>
  <style>
    @import url("https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;700&family=IBM+Plex+Mono:wght@400;600&display=swap");

    :root {
      --bg: #f5f7f2; --ink: #11231f; --muted: #44615c;
      --card: #ffffff; --line: #c7d8d2;
      --accent: #0b8f72; --accent-soft: #dff6ef;
      --warn: #bc5f14; --warn-soft: #fdeedc;
      --high: #9f2222; --high-soft: #f9e3e3;
      --correct: #0b8f72; --incorrect: #9f2222; --unsure: #bc5f14;
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
    h1 { margin: 0 0 4px; font-size: clamp(1.5rem, 3vw, 2.4rem); letter-spacing: -0.02em; }
    .meta { margin: 0 0 16px; color: var(--muted); font-size: 0.9rem; }
    .toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-bottom: 16px; }
    .toolbar select, .toolbar button {
      padding: 8px 14px; border: 1px solid var(--line); border-radius: 8px;
      font-family: inherit; font-size: 0.9rem; background: var(--card); cursor: pointer;
    }
    .toolbar button:hover { background: var(--accent-soft); }
    .stats { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 16px; }
    .stat { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 10px 16px; }
    .stat-label { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.07em; color: var(--muted); }
    .stat-value { font-size: 1.4rem; font-weight: 700; margin-top: 2px; }

    .span-card {
      background: var(--card); border: 1px solid var(--line); border-radius: 14px;
      padding: 18px; margin-bottom: 14px; box-shadow: 0 4px 12px rgba(27,51,45,0.04);
    }
    .span-header { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; flex-wrap: wrap; margin-bottom: 10px; }
    .span-project { font-weight: 700; font-size: 1.05rem; }
    .span-ids { font-family: "IBM Plex Mono", monospace; font-size: 0.76rem; color: var(--muted); }
    .span-meta { display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 8px; font-size: 0.85rem; color: var(--muted); }
    .span-meta span { white-space: nowrap; }
    .pill { display: inline-block; border-radius: 999px; padding: 2px 10px; font-size: 0.8rem; font-weight: 600; }
    .pill-assign { color: var(--accent); background: var(--accent-soft); }
    .pill-review { color: var(--warn); background: var(--warn-soft); }
    .pill-none { color: var(--muted); background: #eee; }

    .evidence-section { margin-top: 8px; }
    .evidence-label { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin-bottom: 4px; }
    .reasoning { font-size: 0.88rem; line-height: 1.5; margin-bottom: 8px; padding: 8px 12px; background: #f8faf9; border-radius: 8px; border-left: 3px solid var(--accent); }
    .anchors { display: flex; flex-direction: column; gap: 4px; margin-bottom: 8px; }
    .anchor { font-size: 0.84rem; padding: 6px 10px; background: #f0f6f3; border-radius: 6px; }
    .anchor-type { font-size: 0.72rem; color: var(--muted); text-transform: uppercase; margin-right: 6px; }

    .verdict-bar { display: flex; gap: 8px; align-items: center; margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--line); }
    .verdict-btn {
      padding: 8px 18px; border: 2px solid transparent; border-radius: 8px;
      font-family: inherit; font-size: 0.88rem; font-weight: 600; cursor: pointer;
      transition: all 0.15s;
    }
    .verdict-btn:hover { transform: translateY(-1px); }
    .btn-correct { background: var(--accent-soft); color: var(--correct); border-color: var(--correct); }
    .btn-incorrect { background: var(--high-soft); color: var(--incorrect); border-color: var(--incorrect); }
    .btn-unsure { background: var(--warn-soft); color: var(--unsure); border-color: var(--unsure); }
    .btn-correct.active { background: var(--correct); color: #fff; }
    .btn-incorrect.active { background: var(--incorrect); color: #fff; }
    .btn-unsure.active { background: var(--unsure); color: #fff; }
    .verdict-btn:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }
    .verdict-status { font-size: 0.82rem; color: var(--muted); margin-left: 8px; }
    .verdict-saved { font-size: 0.82rem; color: var(--accent); font-weight: 600; margin-left: 8px; }

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

    .loading { text-align: center; padding: 60px 20px; color: var(--muted); font-size: 1.1rem; }
    .loading::after { content: ""; display: block; width: 32px; height: 32px; margin: 16px auto 0; border: 3px solid var(--line); border-top-color: var(--accent); border-radius: 50%; animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }

    #auth-section, #main-section { display: none; }

    @media (max-width: 760px) {
      .wrap { padding: 14px; }
      .span-header { flex-direction: column; }
      .verdict-bar { flex-wrap: wrap; }
    }
  </style>
</head>
<body>
  <div id="loading-section" class="loading">Checking session...</div>

  <div id="auth-section">
    <div class="auth-container">
      <h2>Operator Validation</h2>
      <p>Sign in with your Camber account to review attributions.</p>
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

  <div id="main-section">
    <main class="wrap">
      <h1>Operator Validation</h1>
      <p class="meta" id="page-meta"></p>
      <div class="toolbar">
        <select id="filter-select">
          <option value="needs_review">Needs Review</option>
          <option value="assigned">Assigned</option>
          <option value="all">All</option>
        </select>
        <select id="limit-select">
          <option value="25">25 spans</option>
          <option value="50" selected>50 spans</option>
          <option value="100">100 spans</option>
          <option value="200">200 spans</option>
        </select>
        <button id="refresh-btn">Refresh</button>
        <button id="signout-btn" style="margin-left:auto;background:none;color:var(--muted);border-color:var(--line);">Sign Out</button>
      </div>
      <div class="stats" id="stats-bar"></div>
      <div id="span-list"></div>
    </main>
  </div>

  <script>
    var SUPABASE_URL = "${escapeAttr(supabaseUrl)}";
    var SUPABASE_ANON_KEY = "${escapeAttr(anonKey)}";
    var API_URL = SUPABASE_URL + "/functions/v1/operator-validation";
    var FUNCTION_VERSION = "${escapeAttr(version)}";

    var sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    var currentToken = null;

    var loadingEl = document.getElementById("loading-section");
    var authEl = document.getElementById("auth-section");
    var mainEl = document.getElementById("main-section");
    var authErrorEl = document.getElementById("auth-error");

    function showSection(name) {
      loadingEl.style.display = name === "loading" ? "block" : "none";
      authEl.style.display = name === "auth" ? "block" : "none";
      mainEl.style.display = name === "main" ? "block" : "none";
    }

    function esc(s) {
      var d = document.createElement("div");
      d.textContent = s;
      return d.innerHTML;
    }

    function createEl(tag, attrs, children) {
      var el = document.createElement(tag);
      if (attrs) Object.keys(attrs).forEach(function(k) {
        if (k === "className") el.className = attrs[k];
        else if (k === "textContent") el.textContent = attrs[k];
        else el.setAttribute(k, attrs[k]);
      });
      if (children) children.forEach(function(c) {
        if (typeof c === "string") { el.appendChild(document.createTextNode(c)); }
        else if (c) { el.appendChild(c); }
      });
      return el;
    }

    async function fetchSpans() {
      var filter = document.getElementById("filter-select").value;
      var limit = document.getElementById("limit-select").value;
      var url = API_URL + "?filter=" + filter + "&limit=" + limit;
      var resp = await fetch(url, {
        headers: currentToken ? { "Authorization": "Bearer " + currentToken } : {}
      });
      if (!resp.ok) throw new Error("API returned " + resp.status);
      return resp.json();
    }

    async function submitVerdict(spanId, verdict, interactionId, projectId) {
      var resp = await fetch(API_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer " + currentToken
        },
        body: JSON.stringify({
          span_id: spanId,
          verdict: verdict,
          interaction_id: interactionId || null,
          project_id: projectId || null,
          notes: "operator-validation-ui/" + FUNCTION_VERSION
        })
      });
      return resp.json();
    }

    function renderStats(data) {
      var bar = document.getElementById("stats-bar");
      bar.replaceChildren();
      var total = data.count || 0;
      var fb = data.feedback_map || {};
      var reviewed = 0; var correct = 0; var incorrect = 0; var unsure = 0;
      Object.keys(fb).forEach(function(k) {
        reviewed++;
        if (fb[k] === "CORRECT") correct++;
        else if (fb[k] === "INCORRECT") incorrect++;
        else unsure++;
      });
      var pairs = [
        ["Spans Loaded", total],
        ["Already Reviewed", reviewed],
        ["Correct", correct],
        ["Incorrect", incorrect],
        ["Unsure", unsure],
        ["Unreviewed", total - reviewed]
      ];
      pairs.forEach(function(p) {
        var card = createEl("div", { className: "stat" }, [
          createEl("div", { className: "stat-label", textContent: p[0] }),
          createEl("div", { className: "stat-value", textContent: String(p[1]) })
        ]);
        bar.appendChild(card);
      });
    }

    function renderSpans(data) {
      var list = document.getElementById("span-list");
      list.replaceChildren();
      var spans = data.spans || [];
      var fb = data.feedback_map || {};

      document.getElementById("page-meta").textContent =
        data.count + " spans | " + FUNCTION_VERSION +
        (data.user ? " | " + data.user.email : "");

      renderStats(data);

      if (spans.length === 0) {
        list.appendChild(createEl("p", { textContent: "No spans found.", className: "meta" }));
        return;
      }

      spans.forEach(function(span) {
        var existingVerdict = fb[span.span_id] || null;
        var card = document.createElement("div");
        card.className = "span-card";

        // Header
        var pillClass = span.decision === "assign" ? "pill-assign" : span.decision === "review" ? "pill-review" : "pill-none";
        var header = createEl("div", { className: "span-header" }, [
          createEl("div", {}, [
            createEl("span", { className: "span-project", textContent: span.assigned_project || "No Project" }),
            createEl("span", { className: "pill " + pillClass, textContent: span.decision || "?", style: "margin-left:10px" })
          ]),
          createEl("div", { className: "span-ids", textContent: span.span_id || "" })
        ]);
        card.appendChild(header);

        // Meta
        var meta = createEl("div", { className: "span-meta" }, [
          createEl("span", { textContent: "Conf: " + (span.confidence != null ? Number(span.confidence).toFixed(2) : "n/a") }),
          createEl("span", { textContent: "Tier: " + (span.evidence_tier != null ? span.evidence_tier : "n/a") }),
          createEl("span", { textContent: "Source: " + (span.attribution_source || "n/a") }),
          createEl("span", { textContent: "Anchors: " + (span.total_anchors || 0) })
        ]);
        card.appendChild(meta);

        // Reasoning
        if (span.reasoning_summary) {
          var evSection = createEl("div", { className: "evidence-section" });
          evSection.appendChild(createEl("div", { className: "evidence-label", textContent: "Reasoning" }));
          evSection.appendChild(createEl("div", { className: "reasoning", textContent: span.reasoning_summary }));
          card.appendChild(evSection);
        }

        // Anchors
        var anchorSection = createEl("div", { className: "evidence-section" });
        var hasAnchors = false;
        for (var i = 1; i <= 3; i++) {
          var text = span["anchor_" + i + "_text"] || span["anchor_" + i + "_quote"];
          var type = span["anchor_" + i + "_type"];
          if (text) {
            if (!hasAnchors) {
              anchorSection.appendChild(createEl("div", { className: "evidence-label", textContent: "Anchors" }));
              hasAnchors = true;
            }
            var anchorsDiv = anchorSection.querySelector(".anchors") || createEl("div", { className: "anchors" });
            if (!anchorsDiv.parentNode) anchorSection.appendChild(anchorsDiv);
            anchorsDiv.appendChild(createEl("div", { className: "anchor" }, [
              type ? createEl("span", { className: "anchor-type", textContent: type }) : null,
              document.createTextNode(text)
            ]));
          }
        }
        if (hasAnchors) card.appendChild(anchorSection);

        // Verdict bar
        var verdictBar = createEl("div", { className: "verdict-bar" });
        var verdicts = ["CORRECT", "INCORRECT", "UNSURE"];
        var btnClasses = { CORRECT: "btn-correct", INCORRECT: "btn-incorrect", UNSURE: "btn-unsure" };

        verdicts.forEach(function(v) {
          var btn = createEl("button", {
            className: "verdict-btn " + btnClasses[v] + (existingVerdict === v ? " active" : ""),
            textContent: v
          });
          if (existingVerdict) {
            btn.disabled = true;
          } else {
            btn.addEventListener("click", async function() {
              verdictBar.querySelectorAll("button").forEach(function(b) { b.disabled = true; });
              var statusEl = verdictBar.querySelector(".verdict-status");
              if (statusEl) statusEl.textContent = "Saving...";
              var result = await submitVerdict(span.span_id, v, span.interaction_id, null);
              if (result.ok) {
                btn.classList.add("active");
                if (statusEl) { statusEl.className = "verdict-saved"; statusEl.textContent = "Saved"; }
              } else {
                if (statusEl) statusEl.textContent = "Error: " + (result.error || "unknown");
                verdictBar.querySelectorAll("button").forEach(function(b) { b.disabled = false; });
              }
            });
          }
          verdictBar.appendChild(btn);
        });

        if (existingVerdict) {
          verdictBar.appendChild(createEl("span", { className: "verdict-saved", textContent: "Previously: " + existingVerdict }));
        } else {
          verdictBar.appendChild(createEl("span", { className: "verdict-status" }));
        }

        card.appendChild(verdictBar);
        list.appendChild(card);
      });
    }

    async function loadAndRender() {
      showSection("loading");
      try {
        var data = await fetchSpans();
        if (!data.ok) throw new Error(data.error || "API error");
        renderSpans(data);
        showSection("main");
      } catch (err) {
        console.error("Load failed:", err);
        showSection("auth");
        authErrorEl.style.display = "block";
        authErrorEl.textContent = "Failed to load: " + err.message;
      }
    }

    async function handleSession(session) {
      if (!session) { showSection("auth"); return; }
      currentToken = session.access_token;
      await loadAndRender();
    }

    document.getElementById("signout-btn").addEventListener("click", async function() {
      await sb.auth.signOut();
      currentToken = null;
      showSection("auth");
    });

    document.getElementById("refresh-btn").addEventListener("click", function() { loadAndRender(); });
    document.getElementById("filter-select").addEventListener("change", function() { loadAndRender(); });
    document.getElementById("limit-select").addEventListener("change", function() { loadAndRender(); });

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

    (async function() {
      var result = await sb.auth.getSession();
      handleSession(result.data.session);
    })();
  <\/script>
</body>
</html>`;
}
