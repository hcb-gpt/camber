/**
 * morning-manifest-d3 Edge Function v0.1.0
 *
 * D3.js visual dashboard for the morning manifest.
 * - verify_jwt=false (public HTML shell, auth is client-side)
 * - Uses "Text/Html" (mixed case) to bypass Supabase gateway sandbox
 *   (sb-gateway-version:1 case-sensitively matches "text/html")
 * - Loads D3 v7 from CDN, renders 3 interactive charts from morning-manifest-ui data
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
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  const html = buildPage(supabaseUrl, supabaseAnonKey, FUNCTION_VERSION);
  return new Response(html, {
    status: 200,
    headers: new Headers({
      "content-type": "Text/Html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    }),
  });
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
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Morning Manifest — D3 Dashboard</title>
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"><\/script>
  <script src="https://d3js.org/d3.v7.min.js"><\/script>
  <style>
    @import url("https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;700&family=IBM+Plex+Mono:wght@400;600&display=swap");
    :root {
      --bg:#f5f7f2;--ink:#11231f;--muted:#44615c;
      --card:#ffffff;--line:#c7d8d2;
      --accent:#0b8f72;--accent-soft:#dff6ef;
      --warn:#bc5f14;--warn-soft:#fdeedc;
      --high:#9f2222;--high-soft:#f9e3e3;
    }
    *{box-sizing:border-box}
    body{margin:0;font-family:"Space Grotesk","Avenir Next","Segoe UI",sans-serif;color:var(--ink);
      background:radial-gradient(circle at 90% -10%,#d8efe8 0%,rgba(216,239,232,0) 48%),linear-gradient(160deg,#f7faf6 0%,#edf3ee 100%)}
    .wrap{max-width:1200px;margin:0 auto;padding:24px}
    h1{margin:0 0 4px;font-size:clamp(1.7rem,3.4vw,2.8rem);letter-spacing:-0.02em}
    .subtitle{margin:0 0 24px;color:var(--muted);font-size:0.95rem}
    .chart-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:24px}
    .chart-card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:20px;box-shadow:0 10px 24px rgba(27,51,45,0.06)}
    .chart-card h2{margin:0 0 4px;font-size:1.05rem}
    .chart-card .chart-desc{margin:0 0 16px;color:var(--muted);font-size:0.82rem}
    .chart-card.full{grid-column:1/-1}
    .bar-label{font-family:"Space Grotesk",sans-serif;font-size:12px;fill:var(--ink)}
    .bar-value{font-family:"IBM Plex Mono",monospace;font-size:11px;fill:var(--muted)}
    .axis text{font-family:"Space Grotesk",sans-serif;font-size:11px;fill:var(--muted)}
    .axis line,.axis path{stroke:var(--line)}
    .grid line{stroke:#e7efeb;stroke-dasharray:2,3}
    .grid path{display:none}
    .tooltip{position:absolute;visibility:hidden;background:#fff;border:1px solid var(--line);padding:10px 14px;border-radius:10px;font-size:0.85rem;pointer-events:none;box-shadow:0 4px 12px rgba(0,0,0,0.08);font-family:"Space Grotesk",sans-serif;max-width:240px;z-index:100}
    .tooltip strong{display:block;margin-bottom:4px}
    .tooltip .mono{font-family:"IBM Plex Mono",monospace;font-size:0.78rem;color:var(--muted)}
    .auth-container{max-width:420px;margin:80px auto;padding:32px;background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:0 10px 24px rgba(27,51,45,0.06)}
    .auth-container h2{margin:0 0 4px;font-size:1.4rem}
    .auth-container p{margin:0 0 20px;color:var(--muted);font-size:0.9rem}
    .auth-container label{display:block;margin-bottom:4px;font-size:0.85rem;font-weight:500;color:var(--muted)}
    .auth-container input{width:100%;padding:10px 12px;margin-bottom:14px;border:1px solid var(--line);border-radius:8px;font-size:0.95rem;font-family:inherit}
    .auth-container button{width:100%;padding:12px;border:none;border-radius:8px;background:var(--accent);color:#fff;font-size:1rem;font-weight:600;font-family:inherit;cursor:pointer}
    .auth-container button:hover{opacity:0.9}
    .auth-error{margin-top:12px;padding:10px 12px;border-radius:8px;background:var(--high-soft);color:var(--high);font-size:0.88rem;display:none}
    .loading{text-align:center;padding:60px 20px;color:var(--muted);font-size:1.1rem}
    .loading::after{content:"";display:block;width:32px;height:32px;margin:16px auto 0;border:3px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:spin .8s linear infinite}
    @keyframes spin{to{transform:rotate(360deg)}}
    #auth-section,#dashboard-section{display:none}
    .signout-row{margin-top:20px;text-align:right}
    .signout-row button{background:none;border:1px solid var(--line);border-radius:8px;padding:8px 16px;cursor:pointer;font-family:inherit;color:var(--muted)}
    @media(max-width:760px){.wrap{padding:14px}.chart-grid{grid-template-columns:1fr}}
  </style>
</head>
<body>
  <div id="loading-section" class="loading">Checking session...</div>
  <div id="auth-section">
    <div class="auth-container">
      <h2>Morning Manifest — D3</h2>
      <p>Sign in with your Camber account to view the visual dashboard.</p>
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
  <div id="dashboard-section">
    <main class="wrap">
      <h1>Morning Manifest — D3 Dashboard</h1>
      <p class="subtitle" id="dash-meta"></p>
      <div class="chart-grid">
        <div class="chart-card">
          <h2>Pending Reviews by Project</h2>
          <p class="chart-desc">Horizontal bar — sorted by review queue depth</p>
          <svg id="chart-reviews" width="100%" height="300"></svg>
        </div>
        <div class="chart-card">
          <h2>Activity Breakdown</h2>
          <p class="chart-desc">Stacked bar — calls, journal, beliefs, strikes per project</p>
          <svg id="chart-activity" width="100%" height="300"></svg>
        </div>
        <div class="chart-card full">
          <h2>Project Heatmap</h2>
          <p class="chart-desc">Colour intensity encodes metric magnitude across projects</p>
          <svg id="chart-heatmap" width="100%" height="240"></svg>
        </div>
      </div>
      <div class="signout-row">
        <button id="signout-btn">Sign Out</button>
      </div>
    </main>
  </div>
  <div class="tooltip" id="tip"></div>
  <script>
    var SUPABASE_URL="${esc(supabaseUrl)}";
    var SUPABASE_ANON_KEY="${esc(anonKey)}";
    var MANIFEST_UI_URL=SUPABASE_URL+"/functions/v1/morning-manifest-ui";
    var FUNCTION_VERSION="${esc(version)}";
    var sb=supabase.createClient(SUPABASE_URL,SUPABASE_ANON_KEY);
    var loadingEl=document.getElementById("loading-section");
    var authEl=document.getElementById("auth-section");
    var dashEl=document.getElementById("dashboard-section");
    var authErrorEl=document.getElementById("auth-error");
    var tip=d3.select("#tip");

    var palette={accent:"#0b8f72",warn:"#bc5f14",high:"#9f2222",blue:"#3b7dd8",purple:"#7b5ea7",teal:"#0b8f72",orange:"#bc5f14",muted:"#44615c"};
    var activityKeys=["new_calls","new_journal_entries","new_belief_claims","new_striking_signals"];
    var activityLabels={new_calls:"Calls",new_journal_entries:"Journal",new_belief_claims:"Beliefs",new_striking_signals:"Strikes"};
    var activityColours=d3.scaleOrdinal().domain(activityKeys).range([palette.blue,palette.teal,palette.purple,palette.orange]);

    function showSection(n){loadingEl.style.display=n==="loading"?"block":"none";authEl.style.display=n==="auth"?"block":"none";dashEl.style.display=n==="dash"?"block":"none"}
    function shortName(n){if(!n)return"Unknown";return n.replace(/ (Residence|Project|Build|Home|House)$/i,"")}
    function showTip(ev,h){tip.style("visibility","visible").html(h);tip.style("top",(ev.pageY-tip.node().offsetHeight-12)+"px").style("left",(ev.pageX-tip.node().offsetWidth/2)+"px")}
    function hideTip(){tip.style("visibility","hidden")}
    function varInk(){return"#11231f"}

    function drawReviewsChart(rows){
      var svg=d3.select("#chart-reviews");svg.selectAll("*").remove();
      var box=svg.node().parentElement.getBoundingClientRect();
      var W=box.width-40,H=300;svg.attr("width",W).attr("height",H);
      var sorted=rows.slice().sort(function(a,b){return(Number(b.pending_reviews)||0)-(Number(a.pending_reviews)||0)});
      var margin={top:10,right:50,bottom:20,left:120},iW=W-margin.left-margin.right,iH=H-margin.top-margin.bottom;
      var g=svg.append("g").attr("transform","translate("+margin.left+","+margin.top+")");
      var y=d3.scaleBand().domain(sorted.map(function(d){return shortName(d.project_name)})).range([0,iH]).padding(0.25);
      var maxVal=d3.max(sorted,function(d){return Number(d.pending_reviews)||0})||1;
      var x=d3.scaleLinear().domain([0,maxVal]).range([0,iW]);
      g.append("g").attr("class","grid").call(d3.axisBottom(x).tickSize(iH).tickFormat(""));
      g.append("g").attr("class","axis").call(d3.axisLeft(y).tickSize(0).tickPadding(8));
      g.selectAll(".bar").data(sorted).join("rect").attr("class","bar")
        .attr("y",function(d){return y(shortName(d.project_name))}).attr("height",y.bandwidth()).attr("x",0).attr("width",0).attr("rx",4)
        .attr("fill",function(d){var v=Number(d.pending_reviews)||0;if(v>=10)return palette.high;if(v>=3)return palette.warn;return palette.accent})
        .on("mouseover",function(ev,d){d3.select(this).attr("opacity",0.8);showTip(ev,"<strong>"+(d.project_name||"Unknown")+"</strong><span class='mono'>"+d.project_id+"</span><br>Pending: <b>"+(Number(d.pending_reviews)||0)+"</b><br>Resolved: "+(Number(d.newly_resolved_reviews)||0))})
        .on("mousemove",function(ev){showTip(ev,tip.html())})
        .on("mouseout",function(){d3.select(this).attr("opacity",1);hideTip()})
        .transition().duration(600).ease(d3.easeCubicOut)
        .attr("width",function(d){return x(Number(d.pending_reviews)||0)});
      g.selectAll(".val").data(sorted).join("text").attr("class","bar-value")
        .attr("y",function(d){return y(shortName(d.project_name))+y.bandwidth()/2}).attr("dy","0.35em")
        .attr("x",function(d){return x(Number(d.pending_reviews)||0)+6})
        .text(function(d){return Number(d.pending_reviews)||0})
        .attr("opacity",0).transition().delay(400).duration(300).attr("opacity",1);
    }

    function drawActivityChart(rows){
      var svg=d3.select("#chart-activity");svg.selectAll("*").remove();
      var box=svg.node().parentElement.getBoundingClientRect();
      var W=box.width-40,H=300;svg.attr("width",W).attr("height",H);
      var sorted=rows.slice().sort(function(a,b){
        var sA=activityKeys.reduce(function(s,k){return s+(Number(a[k])||0)},0);
        var sB=activityKeys.reduce(function(s,k){return s+(Number(b[k])||0)},0);return sB-sA});
      var margin={top:10,right:20,bottom:50,left:40},iW=W-margin.left-margin.right,iH=H-margin.top-margin.bottom;
      var g=svg.append("g").attr("transform","translate("+margin.left+","+margin.top+")");
      var x=d3.scaleBand().domain(sorted.map(function(d){return shortName(d.project_name)})).range([0,iW]).padding(0.2);
      var stacked=d3.stack().keys(activityKeys)(sorted.map(function(d){
        var o={name:shortName(d.project_name),_raw:d};activityKeys.forEach(function(k){o[k]=Number(d[k])||0});return o}));
      var maxY=d3.max(stacked,function(l){return d3.max(l,function(d){return d[1]})})||1;
      var y=d3.scaleLinear().domain([0,maxY]).nice().range([iH,0]);
      g.append("g").attr("class","grid").call(d3.axisLeft(y).tickSize(-iW).tickFormat(""));
      g.append("g").attr("class","axis").attr("transform","translate(0,"+iH+")").call(d3.axisBottom(x).tickSize(0).tickPadding(8))
        .selectAll("text").attr("transform","rotate(-35)").style("text-anchor","end");
      g.append("g").attr("class","axis").call(d3.axisLeft(y).ticks(5));
      g.selectAll(".layer").data(stacked).join("g").attr("class","layer")
        .attr("fill",function(d){return activityColours(d.key)})
        .selectAll("rect").data(function(d){return d.map(function(v){v.key=d.key;return v})}).join("rect")
        .attr("x",function(d){return x(d.data.name)}).attr("width",x.bandwidth()).attr("y",iH).attr("height",0).attr("rx",2)
        .on("mouseover",function(ev,d){d3.select(this).attr("opacity",0.7);showTip(ev,"<strong>"+d.data._raw.project_name+"</strong><br>"+activityLabels[d.key]+": <b>"+(d[1]-d[0])+"</b>")})
        .on("mousemove",function(ev){showTip(ev,tip.html())})
        .on("mouseout",function(){d3.select(this).attr("opacity",1);hideTip()})
        .transition().duration(600).ease(d3.easeCubicOut)
        .attr("y",function(d){return y(d[1])}).attr("height",function(d){return y(d[0])-y(d[1])});
      var legend=svg.append("g").attr("transform","translate("+(margin.left+8)+","+(H-14)+")");
      activityKeys.forEach(function(k,i){var lg=legend.append("g").attr("transform","translate("+(i*110)+",0)");
        lg.append("rect").attr("width",10).attr("height",10).attr("rx",2).attr("fill",activityColours(k));
        lg.append("text").attr("x",14).attr("y",9).attr("class","bar-value").text(activityLabels[k])});
    }

    function drawHeatmap(rows){
      var svg=d3.select("#chart-heatmap");svg.selectAll("*").remove();
      var box=svg.node().parentElement.getBoundingClientRect();
      var W=box.width-40,H=240;svg.attr("width",W).attr("height",H);
      var metrics=["new_calls","new_journal_entries","new_belief_claims","new_striking_signals","pending_reviews","newly_resolved_reviews"];
      var metricLabels={new_calls:"Calls",new_journal_entries:"Journal",new_belief_claims:"Beliefs",new_striking_signals:"Strikes",pending_reviews:"Pending",newly_resolved_reviews:"Resolved"};
      var sorted=rows.slice().sort(function(a,b){return String(a.project_name||"").localeCompare(String(b.project_name||""))});
      var margin={top:60,right:20,bottom:10,left:120},iW=W-margin.left-margin.right,iH=H-margin.top-margin.bottom;
      var g=svg.append("g").attr("transform","translate("+margin.left+","+margin.top+")");
      var names=sorted.map(function(d){return shortName(d.project_name)});
      var x=d3.scaleBand().domain(metrics).range([0,iW]).padding(0.06);
      var y=d3.scaleBand().domain(names).range([0,iH]).padding(0.06);
      var cells=[];sorted.forEach(function(row){metrics.forEach(function(m){cells.push({name:shortName(row.project_name),metric:m,value:Number(row[m])||0,_raw:row})})});
      var maxVal=d3.max(cells,function(d){return d.value})||1;
      var colour=d3.scaleSequential(d3.interpolateYlOrRd).domain([0,maxVal]);
      svg.append("g").attr("transform","translate("+margin.left+","+(margin.top-6)+")")
        .selectAll("text").data(metrics).join("text")
        .attr("x",function(d){return x(d)+x.bandwidth()/2}).attr("y",0).attr("text-anchor","middle").attr("class","bar-value")
        .text(function(d){return metricLabels[d]});
      g.selectAll(".rowlabel").data(names).join("text").attr("x",-8)
        .attr("y",function(d){return y(d)+y.bandwidth()/2}).attr("dy","0.35em").attr("text-anchor","end").attr("class","bar-label").text(function(d){return d});
      g.selectAll("rect").data(cells).join("rect")
        .attr("x",function(d){return x(d.metric)}).attr("y",function(d){return y(d.name)})
        .attr("width",x.bandwidth()).attr("height",y.bandwidth()).attr("rx",4).attr("fill","#e7efeb")
        .on("mouseover",function(ev,d){d3.select(this).attr("stroke",varInk()).attr("stroke-width",2);showTip(ev,"<strong>"+d._raw.project_name+"</strong><br>"+metricLabels[d.metric]+": <b>"+d.value+"</b>")})
        .on("mousemove",function(ev){showTip(ev,tip.html())})
        .on("mouseout",function(){d3.select(this).attr("stroke","none");hideTip()})
        .transition().duration(500).delay(function(d,i){return i*15})
        .attr("fill",function(d){return d.value===0?"#f0f5f2":colour(d.value)});
      g.selectAll(".cellval").data(cells).join("text")
        .attr("x",function(d){return x(d.metric)+x.bandwidth()/2}).attr("y",function(d){return y(d.name)+y.bandwidth()/2})
        .attr("dy","0.35em").attr("text-anchor","middle")
        .style("font-family","'IBM Plex Mono',monospace").style("font-size","11px")
        .style("fill",function(d){return d.value>maxVal*0.6?"#fff":"#44615c"}).style("pointer-events","none")
        .text(function(d){return d.value}).attr("opacity",0).transition().delay(600).duration(300).attr("opacity",1);
    }

    async function loadManifest(token){
      var resp=await fetch(MANIFEST_UI_URL+"?format=json&limit=100",{headers:{"Authorization":"Bearer "+token}});
      if(!resp.ok)throw new Error("Manifest API returned "+resp.status);return resp.json()}

    function renderDashboard(data){
      showSection("dash");
      document.getElementById("dash-meta").textContent="Generated "+(data.generated_at||"unknown")+" \\u00b7 "+(data.summary.project_row_count||0)+" projects \\u00b7 "+data.ms+"ms \\u00b7 D3 v"+d3.version+" \\u00b7 "+FUNCTION_VERSION;
      var rows=data.manifest||[];drawReviewsChart(rows);drawActivityChart(rows);drawHeatmap(rows);
      var resizeTimer;window.addEventListener("resize",function(){clearTimeout(resizeTimer);resizeTimer=setTimeout(function(){drawReviewsChart(rows);drawActivityChart(rows);drawHeatmap(rows)},200)})}

    async function handleSession(session){
      if(!session){showSection("auth");return}showSection("loading");
      try{var data=await loadManifest(session.access_token);if(!data.ok)throw new Error(data.error||"API error");renderDashboard(data)}
      catch(err){console.error("Failed to load manifest:",err);showSection("auth");authErrorEl.style.display="block";authErrorEl.textContent="Failed to load manifest: "+err.message}}

    async function signOut(){await sb.auth.signOut();showSection("auth")}
    document.getElementById("signout-btn").addEventListener("click",signOut);
    document.getElementById("login-form").addEventListener("submit",async function(e){
      e.preventDefault();authErrorEl.style.display="none";
      var email=document.getElementById("email").value;var password=document.getElementById("password").value;
      var result=await sb.auth.signInWithPassword({email:email,password:password});
      if(result.error){authErrorEl.style.display="block";authErrorEl.textContent=result.error.message;return}
      handleSession(result.data.session)});
    (async function(){var result=await sb.auth.getSession();handleSession(result.data.session)})();
  <\/script>
</body>
</html>`;
}
