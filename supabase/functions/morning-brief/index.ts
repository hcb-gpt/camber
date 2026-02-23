/**
 * morning-brief Edge Function v0.4.0
 *
 * Scroll-storyteller morning command post with SPA navigation and review actions.
 * - verify_jwt=false (public HTML page)
 * - Uses in-browser Supabase Auth (supabase-js CDN) with ANON key
 * - After auth, calls morning-manifest-ui endpoint with user's JWT
 * - SPA views: brief (scroll chapters), project-detail, call-detail
 * - Per-span verdict submission to operator-validation endpoint
 *
 * NOTE: Uses "Text/Html" (mixed case) for content-type to bypass Supabase
 * gateway sandbox (sb-gateway-version:1 case-sensitively matches "text/html"
 * and rewrites to text/plain + sandbox CSP).
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const FUNCTION_VERSION = "v0.4.0";

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

function esc(s: string): string {
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
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <title>Morning Brief</title>
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"><\/script>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet" />
  <style>
    :root {
      --cream: #FAF9F5; --charcoal: #141413; --charcoal-lt: #1e1e1c;
      --muted: #8A8A86; --muted-lt: #b8b8b4;
      --border-l: #e5e2dd; --border-d: #2a2a28;
      --red: #dc2626; --red-soft: #fef2f2;
      --amber: #d97706; --amber-soft: #fffbeb;
      --green: #16a34a; --green-soft: #f0fdf4;
      --blue: #2563eb;
      --spring: cubic-bezier(0.32, 0.72, 0, 1);
    }
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: "Inter", system-ui, sans-serif; color: var(--charcoal); background: var(--cream); min-height: 100vh; -webkit-font-smoothing: antialiased; overflow-x: hidden; }
    .wrap { max-width: 640px; margin: 0 auto; padding: 0 20px; }
    h1, h2, h3 { font-family: "Instrument Serif", Georgia, serif; font-weight: 400; }
    .dark-bg { background: var(--charcoal); color: var(--cream); }
    .light-bg { background: var(--cream); color: var(--charcoal); }

    /* Hero */
    .hero { background: var(--charcoal); color: var(--cream); min-height: 50vh; display: flex; align-items: center; justify-content: center; text-align: center; position: relative; overflow: hidden; }
    .hero-inner { padding: 40px 20px; position: relative; z-index: 1; }
    .hero-title { font-size: clamp(2.5rem, 8vw, 4rem); letter-spacing: -0.02em; line-height: 1.1; }
    .hero-title span { display: inline-block; opacity: 0; transform: translateY(24px); animation: titleIn 0.7s var(--spring) forwards; }
    .hero-title span:nth-child(2) { animation-delay: 0.15s; }
    @keyframes titleIn { to { opacity: 1; transform: none; } }
    .hero-date { font-family: "JetBrains Mono", monospace; font-size: 0.8rem; color: var(--muted-lt); margin-top: 16px; }
    .hero-stats { display: flex; justify-content: center; gap: 20px; margin-top: 20px; flex-wrap: wrap; }
    .stat-chip { display: flex; align-items: center; gap: 6px; }
    .stat-num { font-family: "JetBrains Mono", monospace; font-size: 1.4rem; font-weight: 500; }
    .stat-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted-lt); font-weight: 600; }
    .stat-num.red { color: var(--red); } .stat-num.amber { color: var(--amber); }
    .scroll-ind { width: 1px; height: 40px; background: var(--cream); margin: 32px auto 0; opacity: 0.3; animation: scrollP 2s ease-in-out infinite; }
    @keyframes scrollP { 0%,100% { opacity: 0.3; transform: scaleY(1); } 50% { opacity: 0.6; transform: scaleY(1.3); } }

    /* Chapters */
    .chapter { padding: 48px 0; position: relative; overflow: hidden; }
    .ch-header { display: flex; align-items: center; gap: 10px; margin-bottom: 20px; padding-bottom: 10px; border-bottom: 1px solid var(--border-l); }
    .dark-bg .ch-header { border-bottom-color: var(--border-d); }
    .ch-title { font-size: 1.6rem; letter-spacing: -0.01em; }
    .ch-count { font-family: "JetBrains Mono", monospace; font-size: 0.72rem; color: var(--muted); }
    .dark-bg .ch-count { color: var(--muted-lt); }
    .ch-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
    .dot-red { background: var(--red); } .dot-green { background: var(--green); }

    /* Cards */
    .p-card, .c-card { background: #fff; border: 1px solid var(--border-l); border-radius: 10px; padding: 16px; margin-bottom: 10px; cursor: pointer; transition: border-color 0.15s, transform 0.15s; -webkit-tap-highlight-color: transparent; }
    .p-card:hover, .c-card:hover { border-color: var(--muted); }
    .p-card:active, .c-card:active { transform: scale(0.985); }
    .p-card.flagged { border-left: 3px solid var(--red); }
    .p-card.review { border-left: 3px solid var(--amber); }
    .dark-bg .p-card, .dark-bg .c-card { background: var(--charcoal-lt); border-color: var(--border-d); }
    .dark-bg .p-card:hover, .dark-bg .c-card:hover { border-color: var(--muted); }
    .dark-bg .c-card.unmatched { border-left: 3px solid var(--muted); }
    .card-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
    .p-name { font-weight: 600; font-size: 0.95rem; }
    .p-badges, .detail-badges { display: flex; gap: 6px; flex-wrap: wrap; }
    .detail-badges { margin-bottom: 24px; }
    .badge { display: inline-flex; align-items: center; gap: 3px; padding: 2px 8px; border-radius: 6px; font-size: 0.72rem; font-weight: 600; font-family: "JetBrains Mono", monospace; }
    .badge-red { color: var(--red); background: var(--red-soft); }
    .badge-amber { color: var(--amber); background: var(--amber-soft); }
    .badge-muted { color: var(--muted); background: #f1f5f9; }
    .dark-bg .badge-muted { color: var(--muted-lt); background: rgba(255,255,255,0.06); }
    .p-caller { margin-top: 8px; font-size: 0.82rem; color: var(--muted); }
    .p-caller strong { color: inherit; font-weight: 600; }
    .c-top { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
    .c-name { font-weight: 600; font-size: 0.92rem; }
    .c-time { font-family: "JetBrains Mono", monospace; font-size: 0.72rem; color: var(--muted); white-space: nowrap; }
    .dark-bg .c-time { color: var(--muted-lt); }
    .c-tags { display: flex; gap: 5px; flex-wrap: wrap; margin-top: 8px; }
    .tag { display: inline-block; padding: 2px 8px; border-radius: 6px; font-size: 0.72rem; font-weight: 600; }
    .tag-green { color: var(--green); background: var(--green-soft); }
    .tag-amber { color: var(--amber); background: var(--amber-soft); }
    .tag-muted { color: var(--muted); background: #f1f5f9; }
    .dark-bg .tag-green { background: rgba(22,163,74,0.15); }
    .dark-bg .tag-amber { background: rgba(217,119,6,0.15); }
    .dark-bg .tag-muted { background: rgba(255,255,255,0.06); }
    .c-note { margin-top: 6px; font-size: 0.78rem; color: var(--muted); font-style: italic; }

    /* Quiet list */
    .quiet-list { background: #fff; border: 1px solid var(--border-l); border-radius: 10px; overflow: hidden; }
    .quiet-item { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; border-bottom: 1px solid #edeae6; font-size: 0.88rem; font-weight: 500; }
    .quiet-item:last-child { border-bottom: none; }
    .quiet-status { font-family: "JetBrains Mono", monospace; font-size: 0.65rem; color: var(--green); font-weight: 500; text-transform: uppercase; }

    /* Footer */
    .app-footer { background: var(--charcoal); color: var(--cream); padding: 32px 0; }
    .footer-inner { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
    .footer-link { display: inline-flex; align-items: center; padding: 10px 16px; min-height: 44px; border: 1px solid var(--border-d); border-radius: 8px; font-size: 0.85rem; font-weight: 500; color: var(--cream); text-decoration: none; background: transparent; cursor: pointer; font-family: inherit; }
    .footer-link:hover { border-color: var(--cream); }
    .footer-spacer { flex: 1; }
    .footer-ver { width: 100%; text-align: center; font-family: "JetBrains Mono", monospace; font-size: 0.65rem; color: var(--muted); margin-top: 10px; }

    /* SPA transitions */
    .view-container { position: relative; overflow-x: hidden; }
    .view-brief, .view-detail { transition: transform 0.35s var(--spring), opacity 0.35s ease; }
    .view-detail { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: var(--cream); transform: translateX(100%); overflow-y: auto; z-index: 100; -webkit-overflow-scrolling: touch; }
    .view-container.detail-active .view-brief { transform: translateX(-20%); opacity: 0.3; pointer-events: none; }
    .view-container.detail-active .view-detail { transform: translateX(0); }

    /* Detail view */
    .detail-nav { position: sticky; top: 0; z-index: 10; padding: 12px 20px; background: var(--cream); border-bottom: 1px solid var(--border-l); display: flex; align-items: center; gap: 12px; }
    .back-btn { display: inline-flex; align-items: center; padding: 8px 14px; min-height: 44px; border: 1px solid var(--border-l); border-radius: 8px; font-size: 0.85rem; font-weight: 500; color: var(--charcoal); background: transparent; cursor: pointer; font-family: inherit; -webkit-tap-highlight-color: transparent; }
    .back-btn:hover { border-color: var(--charcoal); }
    .detail-title-text { font-family: "Instrument Serif", Georgia, serif; font-size: 1.1rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail-body { padding: 24px 20px 60px; max-width: 640px; margin: 0 auto; }
    .detail-heading { font-size: 1.8rem; margin-bottom: 12px; }

    /* Span block */
    .span-block { background: #f8f7f4; border: 1px solid var(--border-l); border-radius: 10px; padding: 14px; margin-bottom: 10px; }
    .span-top { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; flex-wrap: wrap; }
    .span-idx { font-family: "JetBrains Mono", monospace; font-size: 0.75rem; font-weight: 600; color: var(--muted); }
    .span-proj { font-weight: 600; font-size: 0.9rem; }
    .pill { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.72rem; font-weight: 600; font-family: "JetBrains Mono", monospace; }
    .pill-assign { color: var(--green); background: var(--green-soft); }
    .pill-review { color: var(--amber); background: var(--amber-soft); }
    .pill-none { color: var(--muted); background: #f1f5f9; }
    .conf-row { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
    .conf-label { font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); white-space: nowrap; }
    .conf-track { flex: 1; height: 5px; background: #e5e2dd; border-radius: 3px; max-width: 160px; }
    .conf-fill { height: 100%; border-radius: 3px; transition: width 0.3s ease; }
    .conf-fill.high { background: var(--green); } .conf-fill.med { background: var(--amber); } .conf-fill.low { background: var(--red); }
    .conf-pct { font-family: "JetBrains Mono", monospace; font-size: 0.75rem; font-weight: 500; min-width: 30px; }
    .reasoning { font-size: 0.84rem; line-height: 1.5; margin-bottom: 6px; color: var(--muted); font-style: italic; }
    .anchor-list { list-style: none; margin: 6px 0; }
    .anchor-item { font-size: 0.82rem; color: var(--muted); padding: 3px 0 3px 10px; border-left: 3px solid var(--border-l); margin-bottom: 4px; font-style: italic; }
    .anchor-type { font-style: normal; font-size: 0.68rem; background: rgba(37,99,235,0.08); color: var(--blue); padding: 1px 5px; border-radius: 3px; margin-left: 4px; }
    .candidates-section { margin-top: 6px; font-size: 0.8rem; color: var(--muted); }
    .candidate-list { list-style: none; margin: 4px 0 0; }
    .candidate-item { padding: 2px 0; font-size: 0.82rem; }

    /* Verdict bar */
    .verdict-bar { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--border-l); }
    .v-btn { padding: 6px 14px; border: 1.5px solid transparent; border-radius: 6px; font-family: "JetBrains Mono", monospace; font-size: 0.78rem; font-weight: 500; cursor: pointer; transition: all 0.12s; background: transparent; min-height: 36px; -webkit-tap-highlight-color: transparent; }
    .v-btn:active:not(:disabled) { transform: scale(0.95); }
    .v-correct { color: var(--green); border-color: var(--green); }
    .v-correct:hover:not(:disabled) { background: var(--green-soft); }
    .v-correct.active { background: var(--green); color: #fff; }
    .v-incorrect { color: var(--red); border-color: var(--red); }
    .v-incorrect:hover:not(:disabled) { background: var(--red-soft); }
    .v-incorrect.active { background: var(--red); color: #fff; }
    .v-unsure { color: var(--amber); border-color: var(--amber); }
    .v-unsure:hover:not(:disabled) { background: var(--amber-soft); }
    .v-unsure.active { background: var(--amber); color: #fff; }
    .v-btn:disabled { opacity: 0.4; cursor: default; }
    .v-status { font-size: 0.75rem; font-family: "JetBrains Mono", monospace; margin-left: 4px; }
    .v-status.ok { color: var(--green); } .v-status.err { color: var(--red); } .v-status.prior { color: var(--muted); }
    .notes-area { width: 100%; padding: 8px 10px; border: 1px solid var(--border-l); border-radius: 6px; background: #f8f7f4; color: var(--charcoal); font-family: "JetBrains Mono", monospace; font-size: 0.78rem; margin-top: 6px; resize: vertical; min-height: 48px; line-height: 1.5; }
    .notes-area::placeholder { color: var(--muted); }
    .notes-help { font-size: 0.7rem; color: var(--muted); margin-top: 3px; line-height: 1.4; }
    .notes-submit { margin-top: 6px; padding: 6px 16px; border: 1.5px solid var(--charcoal); border-radius: 6px; background: var(--charcoal); color: var(--cream); font-family: "JetBrains Mono", monospace; font-size: 0.75rem; font-weight: 600; cursor: pointer; min-height: 34px; }
    .notes-submit:hover { opacity: 0.85; }
    .notes-submit:disabled { opacity: 0.4; cursor: default; }
    .span-meta { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-bottom: 6px; font-size: 0.78rem; color: var(--muted); }
    .span-meta-name { font-weight: 600; color: var(--charcoal); }
    .span-meta-date { font-family: "JetBrains Mono", monospace; font-size: 0.72rem; }
    .transcript-excerpt { font-size: 0.82rem; line-height: 1.55; color: var(--charcoal); background: #f0eeea; border-radius: 6px; padding: 10px 12px; margin: 8px 0; border-left: 3px solid var(--border-l); max-height: 120px; overflow-y: auto; white-space: pre-wrap; word-break: break-word; }

    /* Detail call blocks */
    .detail-call-block { margin-bottom: 20px; padding-bottom: 20px; border-bottom: 1px solid var(--border-l); }
    .detail-call-block:last-child { border-bottom: none; padding-bottom: 0; }
    .detail-call-header { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; margin-bottom: 10px; }
    .detail-call-name { font-weight: 600; font-size: 0.92rem; }
    .detail-call-date { font-family: "JetBrains Mono", monospace; font-size: 0.72rem; color: var(--muted); }

    /* Toast */
    .toast-container { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%); z-index: 9999; display: flex; flex-direction: column; gap: 8px; pointer-events: none; }
    .toast { padding: 10px 20px; border-radius: 8px; font-size: 0.84rem; font-weight: 500; opacity: 0; transform: translateY(10px); transition: all 0.3s ease; pointer-events: auto; white-space: nowrap; }
    .toast.visible { opacity: 1; transform: none; }
    .toast-success { background: var(--green); color: #fff; }
    .toast-error { background: var(--red); color: #fff; }

    /* Auth + Loading */
    .auth-wrap { max-width: 380px; margin: 80px auto; padding: 28px; background: #fff; border: 1px solid var(--border-l); border-radius: 14px; }
    .auth-wrap h1 { font-size: 1.5rem; margin-bottom: 4px; }
    .auth-wrap .desc { color: var(--muted); font-size: 0.85rem; margin-bottom: 20px; }
    .auth-wrap label { display: block; font-size: 0.8rem; font-weight: 500; color: var(--muted); margin-bottom: 4px; }
    .auth-wrap input { width: 100%; padding: 10px 12px; margin-bottom: 14px; border: 1px solid var(--border-l); border-radius: 8px; font-size: 0.95rem; font-family: inherit; }
    .auth-wrap input:focus { outline: 2px solid var(--charcoal); outline-offset: -1px; }
    .auth-wrap button { width: 100%; padding: 12px; border: none; border-radius: 8px; background: var(--charcoal); color: var(--cream); font-size: 1rem; font-weight: 600; font-family: inherit; cursor: pointer; min-height: 44px; }
    .auth-wrap button:hover { opacity: 0.9; }
    .auth-error { margin-top: 10px; padding: 10px 12px; border-radius: 8px; background: var(--red-soft); color: var(--red); font-size: 0.84rem; display: none; }
    .loading { text-align: center; padding: 80px 20px; color: var(--muted); font-size: 1rem; }
    .loading::after { content: ""; display: block; width: 28px; height: 28px; margin: 14px auto 0; border: 2px solid var(--border-l); border-top-color: var(--charcoal); border-radius: 50%; animation: spin 0.7s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* Scroll reveal */
    .reveal { opacity: 0; transform: translateY(24px); transition: opacity 0.5s ease, transform 0.5s var(--spring); }
    .reveal.revealed { opacity: 1; transform: none; }
    .card-rv { opacity: 0; transform: translateY(16px); transition: opacity 0.4s ease, transform 0.4s var(--spring); }
    .card-rv.revealed { opacity: 1; transform: none; }
    @media (prefers-reduced-motion: reduce) {
      .hero-title span { animation: none; opacity: 1; transform: none; }
      .scroll-ind { animation: none; }
      .reveal, .card-rv { opacity: 1; transform: none; transition: none; }
      .view-brief, .view-detail { transition: none; }
    }

    .empty-state { text-align: center; padding: 40px 20px; color: var(--muted); font-size: 0.95rem; font-style: italic; }
    #auth-section, #app { display: none; }

    @media (min-width: 769px) { .wrap { max-width: 860px; padding: 0 32px; } .hero-title { font-size: 3.5rem; } .chapter { padding: 56px 0; } .detail-body { max-width: 860px; } }
    @media (min-width: 1201px) { .wrap { max-width: 960px; padding: 0 40px; } }
    @media (max-width: 640px) { .wrap { padding: 0 14px; } .hero { min-height: 40vh; } }
  </style>
</head>
<body>
  <div id="loading-section" class="loading">Checking session...</div>
  <div id="auth-section">
    <div class="auth-wrap">
      <h1>Morning Brief</h1>
      <p class="desc">Sign in with your Camber account.</p>
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
  <div id="app">
    <div class="view-container" id="view-container">
      <div class="view-brief" id="view-brief">
        <section class="hero">
          <div class="hero-inner">
            <h1 class="hero-title"><span>Morning</span> <span>Brief</span></h1>
            <div class="hero-date" id="hero-date"></div>
            <div class="hero-stats" id="hero-stats"></div>
            <div class="scroll-ind"></div>
          </div>
          <svg viewBox="0 0 400 200" preserveAspectRatio="none" style="position:absolute;bottom:0;left:0;width:100%;height:60%;pointer-events:none;opacity:0.04"><path d="M0 200 C60 160,120 180,200 140 C280 100,340 130,400 90 L400 200Z" fill="var(--cream)"/></svg>
        </section>
        <section class="chapter light-bg" id="ch-attention">
          <svg viewBox="0 0 200 300" preserveAspectRatio="none" style="position:absolute;top:0;right:0;width:30%;height:100%;pointer-events:none;opacity:0.04"><path d="M60 300 C58 200,68 100,65 0 L70 0 C73 100,63 200,65 300Z" fill="var(--charcoal)"/><path d="M110 300 C108 180,118 60,115 0 L120 0 C123 60,113 180,115 300Z" fill="var(--charcoal)"/><path d="M160 300 C157 220,167 120,164 30 L169 30 C172 120,162 220,164 300Z" fill="var(--charcoal)"/></svg>
          <div class="wrap"><div class="ch-header reveal"><span class="ch-dot dot-red"></span><h2 class="ch-title">Needs Your Eye</h2><span class="ch-count" id="att-count"></span></div><div id="att-cards"></div></div>
        </section>
        <section class="chapter dark-bg" id="ch-calls">
          <svg viewBox="0 0 400 100" preserveAspectRatio="none" style="position:absolute;top:50%;left:0;width:100%;height:40%;pointer-events:none;opacity:0.06;transform:translateY(-50%)"><path d="M0 60 C80 40,160 70,240 45 C320 20,360 50,400 35 L400 40 C360 55,320 25,240 50 C160 75,80 45,0 65Z" fill="var(--cream)"/></svg>
          <div class="wrap"><div class="ch-header reveal"><h2 class="ch-title">Recent Activity</h2><span class="ch-count" id="calls-count"></span></div><div id="calls-cards"></div></div>
        </section>
        <section class="chapter light-bg" id="ch-clear">
          <svg viewBox="0 0 300 100" preserveAspectRatio="none" style="position:absolute;bottom:0;left:50%;width:60%;height:50%;pointer-events:none;opacity:0.03;transform:translateX(-50%)"><path d="M150 5 C110 35,50 75,10 90 L15 95 C55 80,115 40,150 12 C185 40,245 80,285 95 L290 90 C250 75,190 35,150 5Z" fill="var(--charcoal)"/><path d="M150 20 C125 40,80 65,50 78 L53 82 C83 69,128 44,150 27 C172 44,217 69,247 82 L250 78 C220 65,175 40,150 20Z" fill="var(--charcoal)"/></svg>
          <div class="wrap"><div class="ch-header reveal"><span class="ch-dot dot-green"></span><h2 class="ch-title">All Clear</h2><span class="ch-count" id="clear-count"></span></div><div id="clear-list"></div></div>
        </section>
        <footer class="app-footer"><div class="wrap footer-inner" id="app-footer"></div></footer>
      </div>
      <div class="view-detail" id="detail-panel">
        <div class="detail-nav"><button class="back-btn" id="back-btn">&larr; Back</button><span class="detail-title-text" id="detail-title"></span></div>
        <div class="detail-body" id="detail-body"></div>
      </div>
    </div>
  </div>
  <div class="toast-container" id="toast-container"></div>

  <script>
  var SUPABASE_URL = "${esc(supabaseUrl)}";
  var SUPABASE_ANON_KEY = "${esc(anonKey)}";
  var MANIFEST_URL = SUPABASE_URL + "/functions/v1/morning-manifest-ui";
  var VALIDATION_URL = SUPABASE_URL + "/functions/v1/operator-validation";
  var REVIEW_UI_URL = SUPABASE_URL + "/functions/v1/operator-validation-ui";
  var TABLE_URL = SUPABASE_URL + "/functions/v1/morning-manifest-site";
  var FUNCTION_VERSION = "${esc(version)}";
  var sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

  var state = { view:"brief", selectedProject:null, selectedCall:null, scrollY:0, feedbackMap:{}, pendingSubmissions:{}, manifestData:null, rawData:null };

  function ce(tag,cls){var e=document.createElement(tag);if(cls)e.className=cls;return e;}
  function tx(tag,text,cls){var e=ce(tag,cls);e.textContent=text;return e;}
  function escH(s){var d=document.createElement("div");d.textContent=s;return d.innerHTML;}

  function fmtDate(d){try{return(d?new Date(d):new Date()).toLocaleDateString("en-US",{weekday:"long",month:"long",day:"numeric",year:"numeric"});}catch(e){return"";}}
  function fmtTime(iso){if(!iso)return"";try{return new Date(iso).toLocaleTimeString("en-US",{hour:"numeric",minute:"2-digit"});}catch(e){return iso;}}
  function fmtDateShort(iso){if(!iso)return"";try{return new Date(iso).toLocaleDateString("en-US",{month:"short",day:"numeric"});}catch(e){return iso;}}
  function shortName(n){if(!n)return n;return n.replace(/\\s+(Residence|Build|Project|Construction|Remodel|Renovation)\\s*$/i,"").trim();}

  var loadingEl=document.getElementById("loading-section");
  var authEl=document.getElementById("auth-section");
  var appEl=document.getElementById("app");
  var authErrorEl=document.getElementById("auth-error");
  function showSection(name){
    loadingEl.style.display=name==="loading"?"block":"none";
    authEl.style.display=name==="auth"?"block":"none";
    appEl.style.display=name==="app"?"block":"none";
  }

  var GC_BAN=/attribution|segment|confidence.?score|belief|journal.?entr(?:y|ies)|claim|striking.?signal|stopline|provenance|gatekeeper|ai.?router|applied_project|span_attribution/i;
  function sanitizeReasoning(raw){
    if(!raw||typeof raw!=="string")return"";
    var t=raw.trim();
    if(/^DATA-\\d/i.test(t))return"";
    if(/\\b(backfill|fixture|non-prod|test.?fixture)\\b/i.test(t))return"";
    t=t.replace(/^[a-z][a-z0-9]*(?:_[a-z0-9]+)+\\s*:\\s*[a-z0-9_,]+(?:\\s*\\(.*?\\))?\\s*/i,"");
    t=t.replace(/\\([a-z_]+=[\\d.]+(?:,[a-z_]+=[\\d.]+)*\\)/gi,"");
    t=t.replace(/\\b[a-z]+(?:_[a-z0-9]+){2,}\\b/gi,"");
    t=t.replace(GC_BAN,"");
    t=t.replace(/[,;]+\\s*[,;]+/g,",");
    t=t.replace(/^\\s*[,;:.\\-]+\\s*/,"").replace(/\\s*[,;:.\\-]+\\s*$/,"");
    return t.replace(/\\s{2,}/g," ").trim();
  }

  function isTestCall(iid){return iid&&/DEV\\d|SMOKE|SHADOW|TEST|RACECHK|CHAINFAIL|LOADTEST|_SEED_|PROBE/i.test(iid);}
  function extractDateFromId(iid){if(!iid)return"";var m=iid.match(/(\\d{4})(\\d{2})(\\d{2})T(\\d{2})(\\d{2})(\\d{2})Z/);if(!m)return"";return m[1]+"-"+m[2]+"-"+m[3]+"T"+m[4]+":"+m[5]+":"+m[6]+"Z";}
  function displayName(d){var n=d.contact_name||"";if(!n||n==="Unknown"){var dt=d.call_date&&d.call_date.trim()?d.call_date:extractDateFromId(d.interaction_id);if(dt)return"Call "+fmtTime(dt);return"Incoming call";}return n;}

  async function loadManifest(token){
    var r=await fetch(MANIFEST_URL+"?format=json&limit=100",{headers:{"Authorization":"Bearer "+token}});
    if(!r.ok)throw new Error("Manifest API returned "+r.status);
    return r.json();
  }
  async function loadFeedback(token){
    try{var r=await fetch(VALIDATION_URL+"?filter=all&limit=500",{headers:{"Authorization":"Bearer "+token}});if(!r.ok)return{};var d=await r.json();return d.feedback_map||{};}catch(e){return{};}
  }

  function processData(data){
    var manifest=data.manifest||[];
    var allDet=data.attribution_details||[];
    var details=allDet.filter(function(d){return!isTestCall(d.interaction_id);});
    var callerByP={};
    details.forEach(function(d){
      var spans=d.spans||[];
      var eDate=(d.call_date&&d.call_date.trim())?d.call_date:extractDateFromId(d.interaction_id);
      spans.forEach(function(sp){
        var pn=sp.project_name||"";if(!pn||pn==="Unassigned")return;
        var ex=callerByP[pn];
        if(!ex||(eDate&&(!ex.call_date||eDate>ex.call_date)))callerByP[pn]={contact_name:displayName(d),call_date:eDate};
      });
    });
    var attention=[],quiet=[];
    manifest.forEach(function(p){
      var reviews=Number(p.pending_reviews)||0,calls=Number(p.new_calls)||0,resolved=Number(p.newly_resolved_reviews)||0;
      var proj={name:p.project_name||"Unknown",shortName:shortName(p.project_name||"Unknown"),reviews:reviews,calls:calls,resolved:resolved,urgency:(reviews*3)+calls,needsAttention:reviews>0,caller:callerByP[p.project_name]||null};
      if(proj.needsAttention)attention.push(proj);else quiet.push(proj);
    });
    attention.sort(function(a,b){return b.urgency-a.urgency;});
    quiet.sort(function(a,b){return a.shortName.localeCompare(b.shortName);});
    var calls=[];
    details.forEach(function(d){
      var cn=displayName(d),rawD=d.call_date&&d.call_date.trim()?d.call_date:"",callD=rawD||extractDateFromId(d.interaction_id);
      var spans=d.spans||[],projects=[],hasUnc=false,hasUnm=false,sds=[];
      spans.forEach(function(sp){
        var pn=sp.project_name||"";
        if(pn&&pn!=="Unassigned"&&projects.indexOf(pn)===-1)projects.push(pn);
        if(pn==="Unassigned"||!pn)hasUnm=true;
        if((sp.decision||"")==="review")hasUnc=true;
        sds.push({span_id:sp.span_id||"",span_index:sp.span_index,project:pn,applied_project_id:sp.applied_project_id||null,decision:sp.decision||"",confidence:Number(sp.confidence),reasoning:sp.reasoning||"",anchors:sp.anchors||[],candidates:sp.candidates||[],transcript_excerpt:sp.transcript_excerpt||null});
      });
      calls.push({interactionId:d.interaction_id||"",contactName:cn,callDate:callD,projects:projects,multiProject:projects.length>=2,uncertain:hasUnc,unmatched:hasUnm&&projects.length===0,spanCount:spans.length,spanDetails:sds});
    });
    calls.sort(function(a,b){if(!a.callDate&&!b.callDate)return 0;if(!a.callDate)return 1;if(!b.callDate)return-1;return b.callDate>a.callDate?1:b.callDate<a.callDate?-1:0;});
    var totalActive=manifest.length,totalReviews=0;
    manifest.forEach(function(p){totalReviews+=Number(p.pending_reviews)||0;});
    return{attention:attention,quiet:quiet,calls:calls,totalActive:totalActive,totalReviews:totalReviews};
  }

  /* --- Router --- */
  function navigateTo(view,params){
    state.scrollY=window.scrollY;state.view=view;
    if(view==="project"){state.selectedProject=params.name;history.pushState({view:"project",name:params.name},"","#/project/"+encodeURIComponent(params.name));renderProjectDetail(params.name);}
    else if(view==="call"){state.selectedCall=params.id;history.pushState({view:"call",id:params.id},"","#/call/"+encodeURIComponent(params.id));renderCallDetail(params.id);}
    document.getElementById("view-container").classList.add("detail-active");
    document.getElementById("detail-panel").scrollTop=0;
  }
  function navigateBack(){
    document.getElementById("view-container").classList.remove("detail-active");
    state.view="brief";state.selectedProject=null;state.selectedCall=null;
    history.pushState({view:"brief"},"","#/");
    setTimeout(function(){window.scrollTo(0,state.scrollY);},50);
  }
  document.getElementById("back-btn").addEventListener("click",navigateBack);
  window.addEventListener("popstate",function(e){
    if(!e.state||e.state.view==="brief"){document.getElementById("view-container").classList.remove("detail-active");state.view="brief";setTimeout(function(){window.scrollTo(0,state.scrollY);},50);}
    else if(e.state.view==="project"){state.selectedProject=e.state.name;renderProjectDetail(e.state.name);document.getElementById("view-container").classList.add("detail-active");}
    else if(e.state.view==="call"){state.selectedCall=e.state.id;renderCallDetail(e.state.id);document.getElementById("view-container").classList.add("detail-active");}
  });

  /* --- Toast --- */
  function showToast(msg,type){
    var t=ce("div","toast toast-"+(type||"success"));t.textContent=msg;
    document.getElementById("toast-container").appendChild(t);
    requestAnimationFrame(function(){t.classList.add("visible");});
    setTimeout(function(){t.classList.remove("visible");setTimeout(function(){t.remove();},300);},3000);
  }

  /* --- Verdict --- */
  async function submitVerdict(spanId,verdict,interactionId,projectId,notesEl){
    if(state.pendingSubmissions[spanId])return;
    state.pendingSubmissions[spanId]=true;
    state.feedbackMap[spanId]=verdict;
    updateVUI(spanId,verdict,"saving");
    try{
      var sess=(await sb.auth.getSession()).data.session;
      if(!sess){showToast("Session expired","error");delete state.feedbackMap[spanId];updateVUI(spanId,null,"");return;}
      var r=await fetch(VALIDATION_URL,{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+sess.access_token},body:JSON.stringify({span_id:spanId,verdict:verdict,interaction_id:interactionId||null,project_id:projectId||null,notes:notesEl?notesEl.value.trim()||null:null})});
      var res=await r.json();
      if(res.ok){showToast("Saved: "+verdict,"success");if(navigator.vibrate)navigator.vibrate(10);updateVUI(spanId,verdict,"ok");}
      else{delete state.feedbackMap[spanId];updateVUI(spanId,null,"");showToast(res.error||"Failed","error");}
    }catch(err){delete state.feedbackMap[spanId];updateVUI(spanId,null,"");showToast("Network error","error");}
    finally{delete state.pendingSubmissions[spanId];}
  }
  function updateVUI(spanId,verdict,status){
    var bar=document.querySelector("[data-span-id='"+spanId+"']");if(!bar)return;
    bar.querySelectorAll(".v-btn").forEach(function(b){b.classList.remove("active");b.disabled=!!verdict;if(verdict&&b.dataset.verdict===verdict)b.classList.add("active");});
    if(verdict){var ni=bar.parentNode.querySelector(".notes-area");if(ni)ni.style.display="none";var nh=bar.parentNode.querySelector(".notes-help");if(nh)nh.style.display="none";var ns=bar.parentNode.querySelector(".notes-submit");if(ns)ns.style.display="none";}
    var st=bar.querySelector(".v-status");
    if(st){if(status==="saving"){st.className="v-status";st.textContent="Saving...";}else if(status==="ok"){st.className="v-status ok";st.textContent="Saved";}else if(verdict){st.className="v-status prior";st.textContent="Prior: "+verdict;}else{st.className="v-status";st.textContent="";}}
  }

  /* --- Render span block --- */
  function renderSpanBlock(sp,interactionId,contactName,callDate){
    var block=ce("div","span-block");
    var existing=state.feedbackMap[sp.span_id]||null;

    /* Call context: date + correspondent */
    if(contactName||callDate){
      var meta=ce("div","span-meta");
      if(contactName&&contactName!=="Incoming call")meta.appendChild(tx("span",contactName,"span-meta-name"));
      if(callDate){var ds=fmtDateShort(callDate);var ts=fmtTime(callDate);if(ds)meta.appendChild(tx("span",ds+(ts?" "+ts:""),"span-meta-date"));}
      if(meta.childNodes.length>0)block.appendChild(meta);
    }

    var top=ce("div","span-top");
    top.appendChild(tx("span","Span "+(sp.span_index+1),"span-idx"));
    top.appendChild(tx("span",sp.project||"Unassigned","span-proj"));
    var pc=sp.decision==="assign"?"pill pill-assign":sp.decision==="review"?"pill pill-review":"pill pill-none";
    top.appendChild(tx("span",sp.decision||"none",pc));
    block.appendChild(top);
    var cp=Math.round(sp.confidence*100);
    var cr=ce("div","conf-row");cr.appendChild(tx("span","Confidence","conf-label"));
    var trk=ce("div","conf-track");var fill=ce("div","conf-fill "+(cp>=80?"high":cp>=60?"med":"low"));fill.style.width=cp+"%";trk.appendChild(fill);cr.appendChild(trk);
    cr.appendChild(tx("span",cp+"%","conf-pct"));block.appendChild(cr);
    var clean=sanitizeReasoning(sp.reasoning);if(clean)block.appendChild(tx("div",clean,"reasoning"));

    /* Transcript excerpt */
    if(sp.transcript_excerpt){block.appendChild(tx("div",sp.transcript_excerpt,"transcript-excerpt"));}

    if(sp.anchors&&sp.anchors.length>0){
      var al=ce("ul","anchor-list");
      sp.anchors.forEach(function(a){var q=a.quote||a.text||"";if(!q)return;var li=ce("li","anchor-item");li.textContent="\\u201C"+q+"\\u201D";if(a.type){li.appendChild(tx("span",a.type,"anchor-type"));}al.appendChild(li);});
      block.appendChild(al);
    }
    if(sp.candidates&&sp.candidates.length>0){
      var cd=ce("div","candidates-section");cd.appendChild(tx("span","Candidates:","conf-label"));
      var cl=ce("ul","candidate-list");
      var maxScore=Math.max.apply(null,sp.candidates.map(function(c){return c.score||0;}));
      sp.candidates.forEach(function(c){var s=c.score||0;var pct=maxScore>0?Math.round(s/maxScore*100):0;cl.appendChild(tx("li",(c.project_name||c.project_id||"?")+" ("+pct+"%)","candidate-item"));});
      cd.appendChild(cl);block.appendChild(cd);
    }
    if(sp.span_id){
      var vb=ce("div","verdict-bar");vb.setAttribute("data-span-id",sp.span_id);
      [{l:"\\u2713 Correct",v:"CORRECT",c:"v-correct"},{l:"\\u2717 Wrong",v:"INCORRECT",c:"v-incorrect"},{l:"? Unsure",v:"UNSURE",c:"v-unsure"}].forEach(function(vd){
        var btn=ce("button","v-btn "+vd.c+(existing===vd.v?" active":""));btn.textContent=vd.l;btn.dataset.verdict=vd.v;
        if(existing)btn.disabled=true;
        else btn.addEventListener("click",function(){submitVerdict(sp.span_id,vd.v,interactionId,sp.applied_project_id,block.querySelector(".notes-area"));});
        vb.appendChild(btn);
      });
      var se=ce("span","v-status"+(existing?" prior":""));if(existing)se.textContent="Prior: "+existing;vb.appendChild(se);block.appendChild(vb);
      if(!existing){
        var na=ce("textarea","notes-area");na.placeholder="Add review notes...";na.rows=2;block.appendChild(na);
        block.appendChild(tx("div","e.g. correct project, wrong project name, caller context, or corrected attribution like \\u201Cshould be Permar Residence\\u201D","notes-help"));
        var sb2=ce("button","notes-submit");sb2.textContent="Submit Notes";sb2.addEventListener("click",function(){
          var txt=na.value.trim();if(!txt){showToast("Enter notes first","error");return;}
          submitVerdict(sp.span_id,"UNSURE",interactionId,sp.applied_project_id,na);
        });
        block.appendChild(sb2);
      }
    }
    return block;
  }

  /* --- Render Brief --- */
  function renderBrief(data,raw){
    document.getElementById("hero-date").textContent=fmtDate(raw.generated_at);
    var hs=document.getElementById("hero-stats");hs.replaceChildren();
    function addS(n,l,c){var ch=ce("div","stat-chip");ch.appendChild(tx("span",String(n),"stat-num"+(c?" "+c:"")));ch.appendChild(tx("span",l,"stat-label"));hs.appendChild(ch);}
    addS(data.totalActive,"Active","");
    if(data.totalReviews>0)addS(data.totalReviews,"To Review","amber");

    var ac=document.getElementById("att-cards");ac.replaceChildren();
    document.getElementById("att-count").textContent=data.attention.length+" project"+(data.attention.length!==1?"s":"");
    if(data.attention.length>0){
      data.attention.forEach(function(p,i){
        var cls="p-card card-rv"+(p.reviews>0?" review":"");
        var card=ce("div",cls);card.style.transitionDelay=(i*0.08)+"s";
        card.setAttribute("role","button");card.setAttribute("tabindex","0");
        var top=ce("div","card-top");top.appendChild(tx("span",p.shortName,"p-name"));
        var bg=ce("div","p-badges");
        if(p.reviews>0)bg.appendChild(tx("span",p.reviews+" to review","badge badge-amber"));
        if(p.calls>0)bg.appendChild(tx("span",p.calls+" call"+(p.calls!==1?"s":""),"badge badge-muted"));
        if(p.resolved>0)bg.appendChild(tx("span",p.resolved+" resolved","badge badge-muted"));
        top.appendChild(bg);card.appendChild(top);
        if(p.caller&&p.caller.contact_name&&p.caller.contact_name!=="Incoming call"){
          var calDiv=ce("div","p-caller");
          calDiv.appendChild(document.createTextNode("Latest: "));
          var strong=ce("strong");strong.textContent=p.caller.contact_name;
          calDiv.appendChild(strong);card.appendChild(calDiv);
        }
        card.addEventListener("click",function(){navigateTo("project",{name:p.name});});
        card.addEventListener("keydown",function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();card.click();}});
        ac.appendChild(card);
      });
    }else{ac.appendChild(tx("div","All clear. No projects need attention.","empty-state"));}

    var cc=document.getElementById("calls-cards");cc.replaceChildren();
    document.getElementById("calls-count").textContent=data.calls.length+" call"+(data.calls.length!==1?"s":"");
    if(data.calls.length>0){
      data.calls.forEach(function(c,i){
        var cls="c-card card-rv"+(c.unmatched?" unmatched":"");
        var card=ce("div",cls);card.style.transitionDelay=(i*0.06)+"s";
        card.setAttribute("role","button");card.setAttribute("tabindex","0");
        var top=ce("div","c-top");top.appendChild(tx("span",c.contactName,"c-name"));
        if(c.callDate)top.appendChild(tx("span",fmtDateShort(c.callDate)+" "+fmtTime(c.callDate),"c-time"));
        card.appendChild(top);
        var tags=ce("div","c-tags");
        c.projects.forEach(function(pn){tags.appendChild(tx("span",shortName(pn),c.uncertain?"tag tag-amber":"tag tag-green"));});
        if(c.unmatched)tags.appendChild(tx("span","Not matched","tag tag-muted"));
        if(c.multiProject)tags.appendChild(tx("span",c.projects.length+" jobs","tag tag-muted"));
        if(tags.childNodes.length>0)card.appendChild(tags);
        var notes=[];if(c.uncertain)notes.push("Needs review");if(c.spanCount>1)notes.push(c.spanCount+" parts");
        if(notes.length>0)card.appendChild(tx("div",notes.join(" \\u00B7 "),"c-note"));
        card.addEventListener("click",function(){navigateTo("call",{id:c.interactionId});});
        card.addEventListener("keydown",function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();card.click();}});
        cc.appendChild(card);
      });
    }else{cc.appendChild(tx("div","No recent calls","empty-state"));}

    var cll=document.getElementById("clear-list");cll.replaceChildren();
    document.getElementById("clear-count").textContent=data.quiet.length+" project"+(data.quiet.length!==1?"s":"");
    if(data.quiet.length>0){
      var list=ce("div","quiet-list reveal");
      data.quiet.forEach(function(p){var item=ce("div","quiet-item");item.appendChild(tx("span",p.shortName));item.appendChild(tx("span",p.calls>0?"quiet":"no activity","quiet-status"));list.appendChild(item);});
      cll.appendChild(list);
    }

    var ft=document.getElementById("app-footer");ft.replaceChildren();
    var rl=ce("a","footer-link");rl.textContent=data.totalReviews>0?"Review Queue ("+data.totalReviews+")":"Review Queue";rl.href=REVIEW_UI_URL;ft.appendChild(rl);
    var tl=ce("a","footer-link");tl.textContent="All Projects";tl.href=TABLE_URL;ft.appendChild(tl);
    ft.appendChild(ce("div","footer-spacer"));
    var so=ce("button","footer-link");so.textContent="Sign Out";so.addEventListener("click",function(){signOut();});ft.appendChild(so);
    ft.appendChild(tx("div",FUNCTION_VERSION,"footer-ver"));
    showSection("app");setupScrollReveal();
  }

  /* --- Project Detail --- */
  function renderProjectDetail(projectName){
    var title=document.getElementById("detail-title");var body=document.getElementById("detail-body");
    title.textContent=shortName(projectName);body.replaceChildren();
    body.appendChild(tx("h2",shortName(projectName),"detail-heading"));
    var data=state.manifestData;if(!data)return;
    var proj=data.attention.concat(data.quiet).find(function(p){return p.name===projectName;});
    if(proj){
      var bg=ce("div","detail-badges");
      if(proj.reviews>0)bg.appendChild(tx("span",proj.reviews+" to review","badge badge-amber"));
      if(proj.calls>0)bg.appendChild(tx("span",proj.calls+" call"+(proj.calls!==1?"s":""),"badge badge-muted"));
      if(proj.resolved>0)bg.appendChild(tx("span",proj.resolved+" resolved","badge badge-muted"));
      body.appendChild(bg);
    }
    var pCalls=data.calls.filter(function(c){return c.projects.indexOf(projectName)!==-1;});
    if(pCalls.length===0){body.appendChild(tx("div","No recent calls for this project.","empty-state"));return;}
    pCalls.forEach(function(c){
      var blk=ce("div","detail-call-block");
      var hdr=ce("div","detail-call-header");hdr.appendChild(tx("span",c.contactName,"detail-call-name"));
      if(c.callDate)hdr.appendChild(tx("span",fmtDateShort(c.callDate)+" "+fmtTime(c.callDate),"detail-call-date"));
      blk.appendChild(hdr);
      c.spanDetails.filter(function(sp){return sp.project===projectName;}).forEach(function(sp){blk.appendChild(renderSpanBlock(sp,c.interactionId,c.contactName,c.callDate));});
      body.appendChild(blk);
    });
  }

  /* --- Call Detail --- */
  function renderCallDetail(interactionId){
    var title=document.getElementById("detail-title");var body=document.getElementById("detail-body");body.replaceChildren();
    var data=state.manifestData;if(!data)return;
    var call=data.calls.find(function(c){return c.interactionId===interactionId;});
    if(!call){title.textContent="Call";body.appendChild(tx("div","Call not found.","empty-state"));return;}
    title.textContent=call.contactName;
    body.appendChild(tx("h2",call.contactName,"detail-heading"));
    var meta=ce("div","detail-badges");
    if(call.callDate)meta.appendChild(tx("span",fmtDateShort(call.callDate)+" "+fmtTime(call.callDate),"badge badge-muted"));
    meta.appendChild(tx("span",call.spanCount+" span"+(call.spanCount!==1?"s":""),"badge badge-muted"));
    call.projects.forEach(function(p){meta.appendChild(tx("span",shortName(p),"badge badge-amber"));});
    body.appendChild(meta);
    if(call.spanDetails.length===0){body.appendChild(tx("div","No spans to review.","empty-state"));return;}
    call.spanDetails.forEach(function(sp){body.appendChild(renderSpanBlock(sp,call.interactionId,call.contactName,call.callDate));});
  }

  /* --- Scroll reveal --- */
  function setupScrollReveal(){
    if(window.matchMedia("(prefers-reduced-motion: reduce)").matches)return;
    var obs=new IntersectionObserver(function(entries){entries.forEach(function(e){if(e.isIntersecting){e.target.classList.add("revealed");obs.unobserve(e.target);}});},{threshold:0.15});
    document.querySelectorAll(".reveal,.card-rv").forEach(function(el){obs.observe(el);});
  }

  /* --- Auth --- */
  async function handleSession(session){
    if(!session){showSection("auth");return;}
    showSection("loading");
    try{
      var raw=await loadManifest(session.access_token);
      if(!raw.ok)throw new Error(raw.error||"API error");
      state.rawData=raw;state.manifestData=processData(raw);
      state.feedbackMap=await loadFeedback(session.access_token);
      renderBrief(state.manifestData,raw);
    }catch(err){
      console.error("Failed:",err);showSection("auth");
      authErrorEl.style.display="block";authErrorEl.textContent="Failed to load: "+err.message;
    }
  }
  async function signOut(){await sb.auth.signOut();showSection("auth");}
  document.getElementById("login-form").addEventListener("submit",async function(e){
    e.preventDefault();authErrorEl.style.display="none";
    var email=document.getElementById("email").value;
    var pw=document.getElementById("password").value;
    var res=await sb.auth.signInWithPassword({email:email,password:pw});
    if(res.error){authErrorEl.style.display="block";authErrorEl.textContent=res.error.message;return;}
    handleSession(res.data.session);
  });
  (async function(){var r=await sb.auth.getSession();handleSession(r.data.session);})();
  <\/script>
</body>
</html>`;
}
