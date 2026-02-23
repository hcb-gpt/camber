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
    @import url("https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;700&family=DM+Mono:wght@400;500&display=swap");

    :root {
      --bg: #0d1017; --bg2: #131820; --card: #171d27;
      --ink: #d4dae3; --bright: #edf0f5; --muted: #6b7689;
      --line: #252d3a; --line2: #1e2532;
      --accent: #22c55e; --accent-soft: rgba(34,197,94,0.12);
      --warn: #f59e0b; --warn-soft: rgba(245,158,11,0.12);
      --high: #ef4444; --high-soft: rgba(239,68,68,0.12);
      --blue: #3b82f6; --blue-soft: rgba(59,130,246,0.12);
    }
    * { box-sizing: border-box; margin: 0; }
    body {
      font-family: "DM Sans", system-ui, sans-serif;
      color: var(--ink); background: var(--bg);
      min-height: 100vh;
    }
    .wrap { max-width: 960px; margin: 0 auto; padding: 24px 20px; }
    h1 { font-size: 1.5rem; font-weight: 700; color: var(--bright); letter-spacing: -0.02em; }
    .subtitle { color: var(--muted); font-size: 0.85rem; margin-top: 4px; }

    .toolbar {
      display: flex; gap: 8px; align-items: center; flex-wrap: wrap;
      margin: 16px 0; padding: 12px 14px;
      background: var(--bg2); border: 1px solid var(--line); border-radius: 10px;
    }
    .toolbar select, .toolbar button {
      padding: 7px 12px; border: 1px solid var(--line); border-radius: 6px;
      font-family: inherit; font-size: 0.84rem; background: var(--card);
      color: var(--ink); cursor: pointer;
    }
    .toolbar select:focus, .toolbar button:focus { outline: 1px solid var(--accent); }
    .toolbar button:hover { border-color: var(--accent); color: var(--accent); }
    .toolbar .spacer { flex: 1; }

    .stats {
      display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
      gap: 8px; margin-bottom: 16px;
    }
    .stat {
      background: var(--card); border: 1px solid var(--line); border-radius: 8px;
      padding: 10px 12px; text-align: center;
    }
    .stat-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); }
    .stat-value { font-size: 1.3rem; font-weight: 700; color: var(--bright); margin-top: 2px; }
    .stat-value.green { color: var(--accent); }
    .stat-value.red { color: var(--high); }
    .stat-value.amber { color: var(--warn); }

    .span-card {
      background: var(--card); border: 1px solid var(--line); border-radius: 10px;
      padding: 16px; margin-bottom: 10px;
      transition: border-color 0.15s;
    }
    .span-card:hover { border-color: #344054; }
    .span-card.has-verdict { opacity: 0.7; }
    .span-card.has-verdict:hover { opacity: 1; }

    .card-top { display: flex; justify-content: space-between; align-items: flex-start; gap: 8px; }
    .card-project { font-weight: 700; color: var(--bright); font-size: 0.95rem; }
    .card-ids {
      font-family: "DM Mono", monospace; font-size: 0.72rem; color: var(--muted);
      display: flex; gap: 10px; flex-wrap: wrap; margin-top: 4px;
    }

    .pill {
      display: inline-block; border-radius: 4px; padding: 2px 8px;
      font-size: 0.74rem; font-weight: 500; font-family: "DM Mono", monospace;
    }
    .pill-assign { color: var(--accent); background: var(--accent-soft); }
    .pill-review { color: var(--warn); background: var(--warn-soft); }
    .pill-none { color: var(--muted); background: rgba(107,118,137,0.12); }

    .card-meta {
      display: flex; gap: 14px; flex-wrap: wrap;
      margin: 8px 0; font-size: 0.8rem; color: var(--muted);
      font-family: "DM Mono", monospace;
    }
    .conf-high { color: var(--accent); }
    .conf-med { color: var(--warn); }
    .conf-low { color: var(--high); }

    .reasoning {
      font-size: 0.84rem; line-height: 1.55; margin: 8px 0;
      padding: 10px 12px; background: var(--bg2); border-radius: 6px;
      border-left: 3px solid var(--blue); color: var(--ink);
    }
    .section-label {
      font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.08em;
      color: var(--muted); margin: 10px 0 4px;
    }
    .anchors { display: flex; flex-direction: column; gap: 4px; }
    .anchor {
      font-size: 0.82rem; padding: 6px 10px;
      background: var(--bg2); border-radius: 4px; color: var(--ink);
    }
    .anchor-type {
      font-family: "DM Mono", monospace; font-size: 0.68rem;
      color: var(--blue); margin-right: 6px; text-transform: uppercase;
    }

    .verdict-bar {
      display: flex; gap: 6px; align-items: center; flex-wrap: wrap;
      margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--line2);
    }
    .verdict-btn {
      padding: 6px 16px; border: 1.5px solid transparent; border-radius: 6px;
      font-family: "DM Mono", monospace; font-size: 0.8rem; font-weight: 500;
      cursor: pointer; transition: all 0.12s; background: transparent;
    }
    .verdict-btn:hover:not(:disabled) { transform: translateY(-1px); }
    .btn-correct { color: var(--accent); border-color: var(--accent); }
    .btn-correct:hover:not(:disabled) { background: var(--accent-soft); }
    .btn-correct.active { background: var(--accent); color: #000; }
    .btn-incorrect { color: var(--high); border-color: var(--high); }
    .btn-incorrect:hover:not(:disabled) { background: var(--high-soft); }
    .btn-incorrect.active { background: var(--high); color: #fff; }
    .btn-unsure { color: var(--warn); border-color: var(--warn); }
    .btn-unsure:hover:not(:disabled) { background: var(--warn-soft); }
    .btn-unsure.active { background: var(--warn); color: #000; }
    .verdict-btn:disabled { opacity: 0.4; cursor: default; transform: none; }

    .verdict-msg { font-size: 0.78rem; margin-left: 6px; font-family: "DM Mono", monospace; }
    .verdict-msg.ok { color: var(--accent); }
    .verdict-msg.err { color: var(--high); }
    .verdict-msg.prior { color: var(--muted); }

    .notes-row {
      display: flex; gap: 6px; margin-top: 6px; align-items: center;
    }
    .notes-input {
      flex: 1; padding: 6px 10px; border: 1px solid var(--line); border-radius: 6px;
      background: var(--bg2); color: var(--ink); font-family: "DM Mono", monospace;
      font-size: 0.8rem;
    }
    .notes-input::placeholder { color: var(--muted); }

    /* Auth */
    .auth-wrap {
      max-width: 380px; margin: 80px auto; padding: 28px;
      background: var(--card); border: 1px solid var(--line); border-radius: 10px;
    }
    .auth-wrap h2 { font-size: 1.3rem; color: var(--bright); margin-bottom: 4px; }
    .auth-wrap .desc { color: var(--muted); font-size: 0.85rem; margin-bottom: 20px; }
    .auth-wrap label { display: block; font-size: 0.8rem; color: var(--muted); margin-bottom: 4px; }
    .auth-wrap input {
      width: 100%; padding: 10px 12px; margin-bottom: 12px;
      border: 1px solid var(--line); border-radius: 6px; font-size: 0.92rem;
      font-family: inherit; background: var(--bg2); color: var(--ink);
    }
    .auth-wrap input:focus { outline: 1px solid var(--accent); }
    .auth-wrap button {
      width: 100%; padding: 11px; border: none; border-radius: 6px;
      background: var(--accent); color: #000; font-size: 0.95rem; font-weight: 600;
      font-family: inherit; cursor: pointer;
    }
    .auth-wrap button:hover { opacity: 0.9; }
    .auth-error {
      margin-top: 10px; padding: 8px 10px; border-radius: 6px;
      background: var(--high-soft); color: var(--high); font-size: 0.84rem; display: none;
    }

    .loading {
      text-align: center; padding: 80px 20px; color: var(--muted); font-size: 1rem;
    }
    .loading::after {
      content: ""; display: block; width: 28px; height: 28px; margin: 14px auto 0;
      border: 2px solid var(--line); border-top-color: var(--accent);
      border-radius: 50%; animation: spin 0.7s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }

    #auth-section, #main-section { display: none; }

    .empty { text-align: center; padding: 40px; color: var(--muted); }

    @media (max-width: 640px) {
      .wrap { padding: 14px 12px; }
      .card-top { flex-direction: column; }
      .verdict-bar { gap: 4px; }
      .verdict-btn { padding: 6px 10px; font-size: 0.76rem; }
    }
  </style>
</head>
<body>
  <div id="loading-section" class="loading">Checking session...</div>

  <div id="auth-section">
    <div class="auth-wrap">
      <h2>Operator Validation</h2>
      <p class="desc">Sign in to review AI attributions.</p>
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
      <p class="subtitle" id="page-meta"></p>

      <div class="toolbar">
        <select id="filter-select">
          <option value="needs_review">Needs Review</option>
          <option value="assigned">Assigned</option>
          <option value="all">All</option>
        </select>
        <select id="limit-select">
          <option value="25">25</option>
          <option value="50" selected>50</option>
          <option value="100">100</option>
          <option value="200">200</option>
        </select>
        <button id="refresh-btn">Refresh</button>
        <div class="spacer"></div>
        <button id="signout-btn">Sign Out</button>
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

    function el(tag, attrs, children) {
      var e = document.createElement(tag);
      if (attrs) for (var k in attrs) {
        if (k === "cls") e.className = attrs[k];
        else if (k === "text") e.textContent = attrs[k];
        else e.setAttribute(k, attrs[k]);
      }
      if (children) children.forEach(function(c) {
        if (typeof c === "string") e.appendChild(document.createTextNode(c));
        else if (c) e.appendChild(c);
      });
      return e;
    }

    function confClass(c) {
      if (c >= 0.8) return "conf-high";
      if (c >= 0.6) return "conf-med";
      return "conf-low";
    }

    function pillCls(decision) {
      if (decision === "assign") return "pill pill-assign";
      if (decision === "review") return "pill pill-review";
      return "pill pill-none";
    }

    function shortId(id) {
      if (!id) return "?";
      return id.length > 12 ? id.slice(0, 8) + "..." : id;
    }

    function fmtDate(iso) {
      if (!iso) return "";
      try { return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }); }
      catch(e) { return iso; }
    }

    async function fetchSpans() {
      var filter = document.getElementById("filter-select").value;
      var limit = document.getElementById("limit-select").value;
      var url = API_URL + "?filter=" + filter + "&limit=" + limit;
      var resp = await fetch(url, {
        headers: currentToken ? { "Authorization": "Bearer " + currentToken } : {}
      });
      if (!resp.ok) throw new Error("API " + resp.status);
      return resp.json();
    }

    async function submitVerdict(spanId, verdict, interactionId, notes) {
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
          notes: notes || null
        })
      });
      return resp.json();
    }

    function renderStats(data) {
      var bar = document.getElementById("stats-bar");
      bar.replaceChildren();
      var total = data.count || 0;
      var fb = data.feedback_map || {};
      var reviewed = 0, correct = 0, incorrect = 0, unsure = 0;
      for (var k in fb) {
        reviewed++;
        if (fb[k] === "CORRECT") correct++;
        else if (fb[k] === "INCORRECT") incorrect++;
        else unsure++;
      }
      var items = [
        ["Loaded", total, ""],
        ["Reviewed", reviewed, ""],
        ["Correct", correct, "green"],
        ["Incorrect", incorrect, "red"],
        ["Unsure", unsure, "amber"],
        ["Remaining", total - reviewed, ""]
      ];
      items.forEach(function(it) {
        bar.appendChild(el("div", { cls: "stat" }, [
          el("div", { cls: "stat-label", text: it[0] }),
          el("div", { cls: "stat-value" + (it[2] ? " " + it[2] : ""), text: String(it[1]) })
        ]));
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
        list.appendChild(el("p", { cls: "empty", text: "No spans match this filter." }));
        return;
      }

      spans.forEach(function(s) {
        var existing = fb[s.span_id] || null;
        var card = el("div", { cls: "span-card" + (existing ? " has-verdict" : "") });

        // project + decision
        var project = s.applied_project || s.assigned_project || "Unassigned";
        var top = el("div", { cls: "card-top" }, [
          el("div", {}, [
            el("span", { cls: "card-project", text: project }),
            el("span", { cls: pillCls(s.decision), text: s.decision || "?", style: "margin-left:8px" })
          ]),
          el("div", { cls: "card-ids" }, [
            el("span", { text: "span:" + (s.span_index != null ? s.span_index : "?") }),
            el("span", { text: shortId(s.span_id) }),
            el("span", { text: fmtDate(s.attributed_at) })
          ])
        ]);
        card.appendChild(top);

        // interaction id
        if (s.interaction_id) {
          card.appendChild(el("div", { cls: "card-ids", style: "margin-top:2px" }, [
            el("span", { text: s.interaction_id })
          ]));
        }

        // meta row
        var conf = s.confidence != null ? Number(s.confidence) : null;
        var meta = el("div", { cls: "card-meta" }, [
          conf !== null ? el("span", { cls: confClass(conf), text: "conf:" + conf.toFixed(2) }) : null,
          s.evidence_tier != null ? el("span", { text: "tier:" + s.evidence_tier }) : null,
          s.attribution_source ? el("span", { text: "src:" + s.attribution_source }) : null,
          s.total_anchors ? el("span", { text: "anchors:" + s.total_anchors }) : null,
          s.needs_review ? el("span", { cls: "conf-low", text: "NEEDS_REVIEW" }) : null
        ]);
        card.appendChild(meta);

        // reasoning
        if (s.reasoning_summary) {
          card.appendChild(el("div", { cls: "reasoning", text: s.reasoning_summary }));
        }

        // anchors
        var hasAnchors = false;
        var anchorsDiv = el("div", { cls: "anchors" });
        for (var i = 1; i <= 3; i++) {
          var txt = s["anchor_" + i + "_text"] || s["anchor_" + i + "_quote"];
          var atype = s["anchor_" + i + "_type"];
          if (txt) {
            hasAnchors = true;
            anchorsDiv.appendChild(el("div", { cls: "anchor" }, [
              atype ? el("span", { cls: "anchor-type", text: atype }) : null,
              document.createTextNode(txt)
            ]));
          }
        }
        if (hasAnchors) {
          card.appendChild(el("div", { cls: "section-label", text: "Anchors" }));
          card.appendChild(anchorsDiv);
        }

        // verdict bar
        var vbar = el("div", { cls: "verdict-bar" });
        var verdicts = ["CORRECT", "INCORRECT", "UNSURE"];
        var btnMap = { CORRECT: "btn-correct", INCORRECT: "btn-incorrect", UNSURE: "btn-unsure" };
        var statusEl = el("span", { cls: "verdict-msg" + (existing ? " prior" : "") });
        if (existing) statusEl.textContent = "Previously: " + existing;

        // optional notes input
        var notesInput = el("input", {
          cls: "notes-input", type: "text",
          placeholder: "Optional notes...", style: "display:none"
        });

        verdicts.forEach(function(v) {
          var btn = el("button", {
            cls: "verdict-btn " + btnMap[v] + (existing === v ? " active" : ""),
            text: v
          });
          if (existing) {
            btn.disabled = true;
          } else {
            btn.addEventListener("click", async function() {
              vbar.querySelectorAll("button").forEach(function(b) { b.disabled = true; });
              statusEl.className = "verdict-msg";
              statusEl.textContent = "Saving...";
              try {
                var result = await submitVerdict(s.span_id, v, s.interaction_id, notesInput.value);
                if (result.ok) {
                  btn.classList.add("active");
                  statusEl.className = "verdict-msg ok";
                  statusEl.textContent = "Saved " + v;
                  card.classList.add("has-verdict");
                  notesInput.style.display = "none";
                } else {
                  statusEl.className = "verdict-msg err";
                  statusEl.textContent = result.error || "Error";
                  vbar.querySelectorAll("button").forEach(function(b) { b.disabled = false; });
                }
              } catch (err) {
                statusEl.className = "verdict-msg err";
                statusEl.textContent = err.message;
                vbar.querySelectorAll("button").forEach(function(b) { b.disabled = false; });
              }
            });
          }
          vbar.appendChild(btn);
        });

        vbar.appendChild(statusEl);
        card.appendChild(vbar);

        // notes row (shown for unreviewed spans)
        if (!existing) {
          var notesRow = el("div", { cls: "notes-row" });
          notesInput.style.display = "block";
          notesRow.appendChild(notesInput);
          card.appendChild(notesRow);
        }

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
