import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getModelConfigCached } from "../_shared/model_config.ts";
import {
  agePhrase,
  buildDeterministicFallback,
  buildEvidenceItemsFromHighlights,
  classifyIntent,
  extractOpenLoopHintsFromEvidence,
  sanitizeSuperintendentFragment,
  type EvidenceItem,
  type Intent,
} from "./superintendent_v1.ts";

const FUNCTION_VERSION = "redline-assistant_v0.6.0";
const CONTRACT_VERSION = "assistant_context_v1";
const DEFAULT_MODEL_ID = "gpt-4o";
const DEFAULT_MAX_TOKENS = 2048;
const DEFAULT_TEMPERATURE = 0.7;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type RosterProject = {
  id: string;
  name: string;
  status: string | null;
};

type ResolutionOutcome = {
  mode: "single" | "ambiguous" | "none" | "no_signal";
  token: string | null;
  matches: RosterProject[];
  resolvedProjectId: string | null;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-edge-secret, x-request-id",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Expose-Headers":
      "x-request-id,x-contract-version,x-function-version,x-model-id,x-model-config-source,x-assistant-style,x-assistant-intent",
  };
}

function json(
  data: unknown,
  status = 200,
  requestId?: string,
  extraHeaders?: Record<string, string>,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders(),
      "Content-Type": "application/json",
      ...(requestId ? { "x-request-id": requestId } : {}),
      "x-function-version": FUNCTION_VERSION,
      "x-contract-version": CONTRACT_VERSION,
      ...(extraHeaders ?? {}),
    },
  });
}

function toStringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

function toIntOrNull(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === "string" && value.trim().length > 0) {
    const n = Number.parseInt(value.trim(), 10);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function wordCount(value: string): number {
  const s = String(value || "").trim();
  if (!s) return 0;
  return s.split(/\s+/).length;
}

const SUPERINTENDENT_STYLE = "superintendent_v1" as const;
const LEGACY_STYLE = "legacy" as const;
type ResponseStyle = typeof SUPERINTENDENT_STYLE | typeof LEGACY_STYLE;

const BANNED_OUTPUT_PATTERNS: Array<{ re: RegExp; label: string }> = [
  { re: /\bUTC\b/i, label: "UTC" },
  { re: /\binbound\b/i, label: "inbound" },
  { re: /\boutbound\b/i, label: "outbound" },
  { re: /\binteraction(s)?\b/i, label: "interaction" },
  { re: /\bthese interactions show\b/i, label: "these_interactions_show" },
  { re: /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, label: "uuid" },
  { re: /\b\d{4}-\d{2}-\d{2}(?:[T\s]\d{2}:\d{2}(?::\d{2})?)?/i, label: "iso_datetime" },
  { re: /\b\d{1,2}\/\d{1,2}\/\d{2,4}\b/i, label: "slash_date" },
  { re: /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+\d{1,2}(?:,\s*\d{4})?\b/i, label: "month_date" },
  { re: /(^|\n)\s*\d+\.\s+/, label: "numbered_log" },
];

function violatesSuperintendentStyle(text: string): string | null {
  const wc = wordCount(text);
  if (wc > 200) return `too_long_words=${wc}`;
  for (const { re, label } of BANNED_OUTPUT_PATTERNS) {
    if (re.test(text)) return `banned_token=${label}`;
  }
  if (!/(^|\n)(Next:|Want me to)/i.test(text)) return "missing_next";
  return null;
}

// ---------------------------------------------------------------------------
// Project resolution (token-based matching against roster)
// ---------------------------------------------------------------------------

function normalizeText(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9\s]/g, " ").replace(/\s+/g, " ")
    .trim();
}

function tokenizeProjectQuery(value: string): string[] {
  const stopwords = new Set([
    "what",
    "where",
    "when",
    "which",
    "this",
    "that",
    "with",
    "from",
    "about",
    "have",
    "recent",
    "recently",
    "going",
    "today",
    "update",
    "status",
    "projects",
    "project",
    "for",
    "the",
    "and",
    "you",
  ]);
  return normalizeText(value)
    .split(" ")
    .map((t) => t.trim())
    .filter((t) => t.length >= 3 && !stopwords.has(t));
}

function stripProjectSuffix(name: string): string {
  return normalizeText(name)
    .replace(/\b(residence|project|home|job|phase)\b/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function resolveProjectFromMessage(
  message: string,
  roster: RosterProject[],
): ResolutionOutcome {
  if (!message || roster.length === 0) {
    return { mode: "no_signal", token: null, matches: [], resolvedProjectId: null };
  }
  const tokens = tokenizeProjectQuery(message);
  if (tokens.length === 0) {
    return { mode: "no_signal", token: null, matches: [], resolvedProjectId: null };
  }

  const scored = roster
    .map((project) => {
      const fullName = normalizeText(project.name);
      const stemName = stripProjectSuffix(project.name);
      let score = 0;
      for (const token of tokens) {
        if (fullName.includes(token)) score += 20;
        if (stemName && stemName.includes(token)) score += 20;
        if (token === stemName || token === fullName) score += 30;
      }
      if (tokens.length > 0) {
        const joined = tokens.join(" ");
        if (fullName.includes(joined) || (stemName && stemName.includes(joined))) {
          score += 50;
        }
      }
      return { project, score };
    })
    .filter((r) => r.score > 0)
    .sort((a, b) => b.score - a.score);

  if (scored.length === 0) {
    return { mode: "none", token: tokens[0], matches: [], resolvedProjectId: null };
  }
  const matches = scored.map((r) => r.project);
  if (matches.length === 1) {
    return { mode: "single", token: tokens[0], matches, resolvedProjectId: matches[0].id };
  }
  return { mode: "ambiguous", token: tokens[0], matches, resolvedProjectId: null };
}

function isProjectsRosterQuery(message: string): boolean {
  return /what\s+projects|which\s+projects|projects\s+do\s+you\s+have|list\s+projects/i
    .test(message);
}

// ---------------------------------------------------------------------------
// SSE helpers
// ---------------------------------------------------------------------------

function buildSSEChunk(content: string): Uint8Array {
  const payload = JSON.stringify({ choices: [{ delta: { content } }] });
  return new TextEncoder().encode(`data: ${payload}\n\n`);
}

function textSseResponse(
  content: string,
  requestId: string,
  extraHeaders: Record<string, string> = {},
): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(buildSSEChunk(content));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(stream, {
    status: 200,
    headers: {
      ...corsHeaders(),
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "x-request-id": requestId,
      "x-function-version": FUNCTION_VERSION,
      "x-contract-version": CONTRACT_VERSION,
      ...extraHeaders,
    },
  });
}

// ---------------------------------------------------------------------------
// Data-grounded context fetch via assistant_context_v1() RPC
// ---------------------------------------------------------------------------

async function fetchGroundedContext(
  db: SupabaseClient,
): Promise<{
  payload: Record<string, unknown> | null;
  source: "rpc" | "projects_fallback";
  error: string | null;
}> {
  try {
    const { data, error } = await db.rpc("assistant_context_v1", {
      p_window_hours: 48,
      p_projects_limit: 100,
      p_highlights_per_project: 5,
      p_contacts_limit: 50,
      p_candidates_per_contact: 3,
    });

    if (error) {
      console.warn(
        `[redline-assistant] assistant_context_v1 RPC failed: ${error.message}. Falling back to projects table.`,
      );
      return await fetchProjectsFallback(db, error.message);
    }

    return {
      payload: data as Record<string, unknown>,
      source: "rpc",
      error: null,
    };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : "rpc_unknown_error";
    console.warn(`[redline-assistant] assistant_context_v1 RPC exception: ${msg}. Falling back to projects table.`);
    return await fetchProjectsFallback(db, msg);
  }
}

async function fetchProjectsFallback(
  db: SupabaseClient,
  rpcError: string,
): Promise<{
  payload: Record<string, unknown> | null;
  source: "projects_fallback";
  error: string | null;
}> {
  try {
    const { data: projectRows, error } = await db
      .from("projects")
      .select("id, name, status")
      .order("updated_at", { ascending: false, nullsFirst: false })
      .limit(100);

    if (error || !Array.isArray(projectRows)) {
      return {
        payload: null,
        source: "projects_fallback",
        error: `rpc: ${rpcError}; fallback: ${error?.message ?? "no_data"}`,
      };
    }

    if (projectRows.length === 0) {
      return { payload: null, source: "projects_fallback", error: `rpc: ${rpcError}; fallback: projects_table_empty` };
    }

    return {
      payload: {
        packet_version: "projects_fallback_v1",
        generated_at_utc: new Date().toISOString(),
        projects_roster: projectRows.map((r: Record<string, unknown>) => ({
          id: r.id,
          name: r.name ?? "Unknown Project",
          status: r.status ?? null,
        })),
        project_recent_highlights: [],
        contact_project_candidates: [],
      },
      source: "projects_fallback",
      error: `rpc_unavailable: ${rpcError}`,
    };
  } catch (fallbackErr: unknown) {
    const msg = fallbackErr instanceof Error ? fallbackErr.message : "fallback_error";
    return { payload: null, source: "projects_fallback", error: `rpc: ${rpcError}; fallback: ${msg}` };
  }
}

// ---------------------------------------------------------------------------
// Direct-query fallback for project highlights
// Covers the 3 data loss points in the RPC:
//   1) SMS silently dropped by JOIN (sms_messages.id ≠ interactions.id)
//   2) Unattributed calls excluded by project_id IS NOT NULL
//   3) Narrow window — we use 7 days here as a safety net
// ---------------------------------------------------------------------------

type DirectHighlight = {
  source: "interaction" | "sms";
  id: string;
  event_at_utc: string | null;
  channel: string | null;
  contact_name: string | null;
  summary_text: string | null;
};

async function fetchDirectHighlights(
  db: SupabaseClient,
  projectId: string,
): Promise<DirectHighlight[]> {
  const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const highlights: DirectHighlight[] = [];

  try {
    // 1) Recent interactions for this project (calls, attributed)
    const { data: interactions } = await db
      .from("interactions")
      .select("id, event_at_utc, channel, contact_name, human_summary")
      .eq("project_id", projectId)
      .gte("event_at_utc", sevenDaysAgo)
      .order("event_at_utc", { ascending: false, nullsFirst: false })
      .limit(10);

    if (Array.isArray(interactions)) {
      for (const row of interactions as Array<Record<string, unknown>>) {
        highlights.push({
          source: "interaction",
          id: String(row.id ?? ""),
          event_at_utc: toStringOrNull(row.event_at_utc),
          channel: toStringOrNull(row.channel),
          contact_name: toStringOrNull(row.contact_name),
          summary_text: toStringOrNull(row.human_summary),
        });
      }
    }

    // 2) Recent SMS for contacts anchored to this project.
    //    sms_messages has contact_phone but no contact_id or project_id.
    //    Resolve: project_contacts → contacts.phone → sms_messages.contact_phone.
    const { data: projectContactRows } = await db
      .from("project_contacts")
      .select("contact_id")
      .eq("project_id", projectId)
      .eq("is_active", true);

    if (Array.isArray(projectContactRows) && projectContactRows.length > 0) {
      const contactIds = (projectContactRows as Array<Record<string, unknown>>)
        .map((r) => String(r.contact_id ?? ""))
        .filter((id) => id.length > 0);

      if (contactIds.length > 0) {
        // Get phones for these contacts
        const { data: contactPhoneRows } = await db
          .from("contacts")
          .select("phone")
          .in("id", contactIds);

        const phones = Array.isArray(contactPhoneRows)
          ? (contactPhoneRows as Array<Record<string, unknown>>)
            .map((r) => toStringOrNull(r.phone))
            .filter((p): p is string => p !== null)
          : [];

        if (phones.length > 0) {
          const { data: smsRows } = await db
            .from("sms_messages")
            .select("id, sent_at, direction, contact_name, content")
            .in("contact_phone", phones)
            .gte("sent_at", sevenDaysAgo)
            .order("sent_at", { ascending: false, nullsFirst: false })
            .limit(10);

          if (Array.isArray(smsRows)) {
            for (const row of smsRows as Array<Record<string, unknown>>) {
              highlights.push({
                source: "sms",
                id: String(row.id ?? ""),
                event_at_utc: toStringOrNull(row.sent_at),
                channel: "sms",
                contact_name: toStringOrNull(row.contact_name),
                summary_text: toStringOrNull(row.content) ? String(row.content).slice(0, 280) : null,
              });
            }
          }
        }
      }
    }
  } catch (err: unknown) {
    console.warn(
      "[redline-assistant] fetchDirectHighlights failed",
      {
        fn: "fetchDirectHighlights",
        projectId,
        error: err instanceof Error ? err.message : "unknown",
        stack: err instanceof Error ? err.stack : undefined,
      },
    );
  }

  // Sort by event time descending, limit to 10
  highlights.sort((a, b) => (b.event_at_utc ?? "").localeCompare(a.event_at_utc ?? ""));
  return highlights.slice(0, 10);
}

// ---------------------------------------------------------------------------
// Project snapshot (open loops, commitments, phase)
// ---------------------------------------------------------------------------

type ProjectSnapshot = {
  project_id?: string;
  system_record?: Record<string, unknown> | null;
  last_activity?: string | null;
  open_loops?: Array<Record<string, unknown>>;
  active_commitments?: Array<Record<string, unknown>>;
  error?: string;
};

async function fetchProjectSnapshot(
  db: SupabaseClient,
  projectId: string,
): Promise<{ snapshot: ProjectSnapshot | null; error: string | null }> {
  try {
    const { data, error } = await db.rpc("get_project_state_snapshot", { p_project_id: projectId });
    if (error) return { snapshot: null, error: error.message };
    if (!data || typeof data !== "object") return { snapshot: null, error: "snapshot_empty" };
    return { snapshot: data as ProjectSnapshot, error: null };
  } catch (err: unknown) {
    return { snapshot: null, error: err instanceof Error ? err.message : "snapshot_exception" };
  }
}

// ---------------------------------------------------------------------------
// OpenAI
// ---------------------------------------------------------------------------

async function openAiChatCompletionsStream(
  openAiKey: string,
  model: string,
  maxTokens: number,
  temperature: number,
  systemPrompt: string,
  userMessage: string,
): Promise<Response> {
  return await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${openAiKey}`,
    },
    body: JSON.stringify({
      model,
      stream: true,
      max_tokens: maxTokens,
      temperature,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userMessage },
      ],
    }),
  });
}

async function openAiChatCompletionText(
  openAiKey: string,
  model: string,
  maxTokens: number,
  temperature: number,
  systemPrompt: string,
  userMessage: string,
): Promise<{ ok: boolean; status: number; content: string; errorText: string | null }> {
  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${openAiKey}`,
    },
    body: JSON.stringify({
      model,
      stream: false,
      max_tokens: maxTokens,
      temperature,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userMessage },
      ],
    }),
  });

  if (!resp.ok) {
    const t = await resp.text().catch(() => "");
    return { ok: false, status: resp.status, content: "", errorText: t.slice(0, 1000) };
  }

  const jsonResp = await resp.json().catch(() => null) as Record<string, unknown> | null;
  const choices = Array.isArray(jsonResp?.choices) ? jsonResp!.choices as Array<Record<string, unknown>> : [];
  const msg = choices.length > 0 && typeof choices[0].message === "object" ? choices[0].message as Record<string, unknown> : null;
  const content = msg && typeof msg.content === "string" ? msg.content : "";
  return { ok: true, status: 200, content: String(content || ""), errorText: null };
}

function buildSuperintendentSystemPrompt(params: {
  intent: Intent;
  nowUtcIso: string;
  clientTzName: string | null;
  clientUtcOffsetMinutes: number | null;
  project: {
    name: string;
    statusLine: string | null;
  };
  evidence: EvidenceItem[];
  openLoops: Array<{ description: string; age: string }> | null;
  commitments: Array<{ who: string; text: string; age: string }> | null;
  openLoopHints: string[];
  snapshotError: string | null;
}): string {
  const templateProjectStatus = `
TEMPLATE (project status / "tell me about <project>"):
<Project> — <status/phase if known>.

Latest: <1 sentence: what happened + who + human time>.

Open loop: <1 sentence: what's still not closed>.

Next: <1 suggestion or offer to help>.
`;

  const templateSchedule = `
TEMPLATE (schedule / "who's coming tomorrow"):
<Who> is scheduled <when>. That's <tomorrow/today>.

I don't see anyone else confirmed.

Heads up: <1 dependency/risk>.

Want me to <next action>?
`;

  const templateYesNo = `
TEMPLATE (yes/no follow-up / "did the inspector call back"):
Yes/No.

Context: <who + human time + what it was about>.

Next: <concrete next action>.
`;

  const templateMoney = `
TEMPLATE (money / "what do I owe Eddie"):
$<amount> OR "I can't compute that from the evidence I have."

If you state a dollar amount, show the math (quantity @ rate) AND quote the exact evidence line.

You told him <promise> (<human time>).

Want me to <next step>?
`;

  const templateBottleneck = `
TEMPLATE (bottleneck / "what's the holdup"):
It's stuck on <single bottleneck>.

Chain: <A> -> <B> -> <C>.

Risk: <1 sentence>.

Suggestion: <next step>.

If you can't justify a full chain from evidence, say so and fall back to: Latest + Open loop + Next.
`;

  const intentTemplate = params.intent === "schedule_who"
    ? templateSchedule
    : params.intent === "yes_no_followup"
    ? templateYesNo
    : params.intent === "money_owed"
    ? templateMoney
    : params.intent === "bottleneck"
    ? templateBottleneck
    : templateProjectStatus;

  const groundingNotes = params.snapshotError
    ? `SNAPSHOT_WARNING: project snapshot unavailable (${params.snapshotError}). Rely only on EVIDENCE + OPEN_LOOP_HINTS.`
    : "SNAPSHOT_OK: project snapshot available.";

  return `You are the HCB Redline Assistant for Heartwood Custom Builders.
You speak like a sharp superintendent on a jobsite: short, direct, actionable.

HARD RULES (must follow):
1) Plain text only. No JSON.
2) First line must be the answer (no preamble).
3) Use human time phrases; DO NOT print timestamps or ISO dates.
4) Do NOT use these words/phrases: "UTC", "interaction", "inbound", "outbound", "These interactions show".
5) Do NOT print IDs/UUIDs.
6) Keep it under 200 words (aim under 120).
7) If the evidence is insufficient, say so plainly. No guessing.

${intentTemplate.trim()}

DATA GROUNDING (strict):
- Use ONLY facts in CONTEXT below.
- Prefer naming people (Jorge, the homeowner) over metadata.
- Surface one open loop if present (or a hinted open loop), even if the user didn't ask.
- End with a useful next step ("Want me to…").

${groundingNotes}

CONTEXT:
${JSON.stringify(params, null, 2)}
`;
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders() });
  }

  const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();
  if (req.method !== "POST") {
    return json(
      { ok: false, error: "method_not_allowed", request_id: requestId, function_version: FUNCTION_VERSION },
      405,
      requestId,
    );
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const openAiKey = Deno.env.get("OPENAI_API_KEY");

    if (!supabaseUrl || !supabaseKey) {
      return json(
        { ok: false, error: "missing_supabase_config", request_id: requestId, function_version: FUNCTION_VERSION },
        500,
        requestId,
      );
    }
    if (!openAiKey) {
      return json(
        { ok: false, error: "missing_openai_key", request_id: requestId, function_version: FUNCTION_VERSION },
        500,
        requestId,
      );
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json(
        { ok: false, error: "invalid_json", request_id: requestId, function_version: FUNCTION_VERSION },
        400,
        requestId,
      );
    }

    const userMessage = toStringOrNull(body.message);
    if (!userMessage) {
      return json(
        { ok: false, error: "message_required", request_id: requestId, function_version: FUNCTION_VERSION },
        400,
        requestId,
      );
    }

    const intent = classifyIntent(userMessage);
    const requestedModel = toStringOrNull(body.model);
    const inputProjectId = toStringOrNull(body.project_id);
    const contactId = toStringOrNull(body.contact_id);
    const clientTzName = toStringOrNull(body.client_tz_name);
    const clientUtcOffsetMinutes = toIntOrNull(body.client_utc_offset_minutes);
    const requestedStyleRaw = toStringOrNull(body.response_style);
    const requestedStyle: ResponseStyle | null = requestedStyleRaw === LEGACY_STYLE
      ? LEGACY_STYLE
      : requestedStyleRaw === SUPERINTENDENT_STYLE
      ? SUPERINTENDENT_STYLE
      : null;

    const db = createClient(supabaseUrl, supabaseKey);

    // Parallel: model config + grounded context RPC
    const [modelConfig, groundedResult] = await Promise.all([
      getModelConfigCached(db, {
        functionName: "redline-assistant",
        modelId: DEFAULT_MODEL_ID,
        maxTokens: DEFAULT_MAX_TOKENS,
        temperature: DEFAULT_TEMPERATURE,
      }),
      fetchGroundedContext(db),
    ]);

    const groundedPayload = groundedResult.payload;

    const provider = requestedModel ? "openai" : modelConfig.provider;
    const primaryModel = requestedModel ?? modelConfig.modelId;
    const fallbackModel = !requestedModel &&
        provider === "openai" &&
        modelConfig.fallbackProvider === "openai" &&
        modelConfig.fallbackModelId
      ? modelConfig.fallbackModelId
      : null;

    if (provider !== "openai") {
      return json(
        {
          ok: false,
          error: "unsupported_model_provider",
          provider,
          request_id: requestId,
          function_version: FUNCTION_VERSION,
        },
        500,
        requestId,
      );
    }

    // Extract projects roster from grounded context
    const projectsRoster: RosterProject[] = Array.isArray(groundedPayload?.projects_roster)
      ? (groundedPayload!.projects_roster as Array<Record<string, unknown>>).map((r) => ({
        id: String(r.id ?? ""),
        name: String(r.name ?? "Unknown Project"),
        status: toStringOrNull(r.status),
      })).filter((r) => r.id.length > 0)
      : [];

    // Project resolution: explicit > message-inferred > contact-based
    const resolution = resolveProjectFromMessage(userMessage, projectsRoster);
    let effectiveProjectId = inputProjectId ?? resolution.resolvedProjectId;

    // If still no project, try contact-based resolution
    let contactCandidates: Array<Record<string, unknown>> = [];
    if (!effectiveProjectId && contactId && Array.isArray(groundedPayload?.contact_project_candidates)) {
      const contactEntry = (groundedPayload!.contact_project_candidates as Array<Record<string, unknown>>)
        .find((c) => String(c.contact_id) === contactId);
      if (contactEntry) {
        contactCandidates = Array.isArray(contactEntry.project_candidates)
          ? contactEntry.project_candidates as Array<Record<string, unknown>>
          : [];
        if (contactEntry.is_single_project_contact === true && contactCandidates.length >= 1) {
          effectiveProjectId = String(contactCandidates[0].project_id ?? "");
        }
      }
    }

    const defaultStyle: ResponseStyle = effectiveProjectId ? SUPERINTENDENT_STYLE : LEGACY_STYLE;
    const responseStyle: ResponseStyle = requestedStyle ?? defaultStyle;

    // Disambiguation: deterministic + jobsite tone (no IDs, no timestamps).
    if (!effectiveProjectId && resolution.mode === "ambiguous" && resolution.matches.length > 0) {
      const options = resolution.matches.slice(0, 5).map((p) => {
        const status = p.status ? ` (${sanitizeSuperintendentFragment(p.status)})` : "";
        return `- ${sanitizeSuperintendentFragment(p.name)}${status}`;
      });
      const answer = `Which one do you mean?\n\n${options.join("\n")}\n`;
      return textSseResponse(answer, requestId, {
        "x-assistant-style": SUPERINTENDENT_STYLE,
        "x-assistant-intent": intent,
      });
    }

    if (!effectiveProjectId && resolution.mode === "none") {
      const suggestions = projectsRoster.slice(0, 5).map((p) => `- ${sanitizeSuperintendentFragment(p.name)}`);
      const answer = suggestions.length > 0
        ? `Which project do you mean?\n\nHere are a few:\n${suggestions.join("\n")}\n`
        : "Which project do you mean?\n";
      return textSseResponse(answer, requestId, {
        "x-assistant-style": SUPERINTENDENT_STYLE,
        "x-assistant-intent": intent,
      });
    }

    // Handle roster-listing queries directly (no LLM needed)
    if (isProjectsRosterQuery(userMessage)) {
      const lines = projectsRoster.slice(0, 15).map((p, i) => {
        const status = p.status ? ` (${p.status})` : "";
        return `${i + 1}. ${p.name}${status}`;
      });
      const answer = projectsRoster.length > 0
        ? `Active project roster (${lines.length} shown):\n${lines.join("\n")}`
        : "No projects found in the current context.";
      return textSseResponse(answer, requestId, {
        "x-assistant-style": responseStyle,
        "x-assistant-intent": intent,
      });
    }

    if (responseStyle === SUPERINTENDENT_STYLE && effectiveProjectId) {
      const nowUtc = new Date();

      const projectFromRoster = projectsRoster.find((p) => p.id === effectiveProjectId) ?? null;

      const [directHighlights, snapshotResult] = await Promise.all([
        fetchDirectHighlights(db, effectiveProjectId),
        fetchProjectSnapshot(db, effectiveProjectId),
      ]);

      const snapshot = snapshotResult.snapshot;
      const snapshotError = snapshotResult.error;

      const sys = snapshot && snapshot.system_record && typeof snapshot.system_record === "object"
        ? snapshot.system_record as Record<string, unknown>
        : null;
      const projectName = toStringOrNull(sys?.name) ?? projectFromRoster?.name ?? "This project";
      const phase = toStringOrNull(sys?.phase);
      const status = toStringOrNull(sys?.status);
      const statusParts = [
        phase && phase.toLowerCase() !== "unknown" ? phase : null,
        status && status.toLowerCase() !== "unknown" ? status : null,
      ].filter((v): v is string => typeof v === "string" && v.trim().length > 0);
      const statusLine = statusParts.length > 0 ? statusParts.join(" / ") : (projectFromRoster?.status ?? null);

      let evidence = buildEvidenceItemsFromHighlights({
        highlights: directHighlights,
        now_utc: nowUtc,
        client_tz_name: clientTzName,
        client_utc_offset_minutes: clientUtcOffsetMinutes,
      });

      // Fallback evidence: use assistant_context_v1 highlight_text if direct-query slice is empty.
      if (evidence.length === 0 && Array.isArray(groundedPayload?.project_recent_highlights)) {
        const entry = (groundedPayload!.project_recent_highlights as Array<Record<string, unknown>>)
          .find((ph) => String(ph.project_id) === effectiveProjectId);
        const rpcHighlights = entry && Array.isArray(entry.highlights) ? entry.highlights as Array<Record<string, unknown>> : [];
        if (rpcHighlights.length > 0) {
          const mapped = rpcHighlights.map((h) => ({
            event_at_utc: toStringOrNull(h.event_at_utc),
            channel: toStringOrNull(h.interaction_type),
            contact_name: null,
            summary_text: toStringOrNull(h.highlight_text),
          }));
          evidence = buildEvidenceItemsFromHighlights({
            highlights: mapped,
            now_utc: nowUtc,
            client_tz_name: clientTzName,
            client_utc_offset_minutes: clientUtcOffsetMinutes,
          });
        }
      }

      const openLoopsRaw = snapshot && Array.isArray(snapshot.open_loops) ? snapshot.open_loops : [];
      const openLoops = openLoopsRaw
        .slice(0, 3)
        .map((o) => ({
          description: sanitizeSuperintendentFragment(toStringOrNull(o?.description) ?? ""),
          age: agePhrase(toStringOrNull(o?.created_at), nowUtc),
        }))
        .filter((o) => o.description.length > 0);

      const commitmentsRaw = snapshot && Array.isArray(snapshot.active_commitments) ? snapshot.active_commitments : [];
      const commitments = commitmentsRaw
        .slice(0, 3)
        .map((c) => ({
          who: sanitizeSuperintendentFragment(toStringOrNull(c?.speaker_label) ?? "") || "(someone)",
          text: sanitizeSuperintendentFragment(toStringOrNull(c?.claim_text) ?? ""),
          age: agePhrase(toStringOrNull(c?.created_at), nowUtc),
        }))
        .filter((c) => c.text.length > 0);

      const openLoopHints = extractOpenLoopHintsFromEvidence(evidence.map((e) => e.excerpt));

      const systemPrompt = buildSuperintendentSystemPrompt({
        intent,
        nowUtcIso: nowUtc.toISOString(),
        clientTzName: clientTzName ?? null,
        clientUtcOffsetMinutes,
        project: { name: projectName, statusLine },
        evidence,
        openLoops: openLoops.length > 0 ? openLoops : null,
        commitments: commitments.length > 0 ? commitments : null,
        openLoopHints,
        snapshotError,
      });

      const maxTokens = Math.min(512, Math.max(128, modelConfig.maxTokens));
      const temperature = 0.2;

      let activeModel = primaryModel;
      let llmResp = await openAiChatCompletionText(
        openAiKey,
        primaryModel,
        maxTokens,
        temperature,
        systemPrompt,
        userMessage,
      );

      if (!llmResp.ok && fallbackModel && fallbackModel !== primaryModel) {
        console.warn(
          `[redline-assistant] superintendent primary model failed (${primaryModel}). falling back to ${fallbackModel}. status=${llmResp.status} body=${llmResp.errorText}`,
        );
        activeModel = fallbackModel;
        llmResp = await openAiChatCompletionText(
          openAiKey,
          fallbackModel,
          maxTokens,
          temperature,
          systemPrompt,
          userMessage,
        );
      }

      const fallbackText = buildDeterministicFallback({
        projectName,
        projectStatusLine: statusLine,
        evidence,
        openLoops: openLoops.length > 0 ? openLoops : null,
        openLoopHints,
      });

      let finalText = fallbackText;
      let modelHeader = "deterministic_fallback";

      if (llmResp.ok) {
        const content = String(llmResp.content || "").trim();
        const violation = content ? violatesSuperintendentStyle(content) : "empty";
        if (!violation) {
          finalText = content.endsWith("\n") ? content : content + "\n";
          modelHeader = activeModel;
        } else {
          console.warn(
            `[redline-assistant] superintendent output violated style: ${violation}. request_id=${requestId}`,
          );
        }
      } else {
        console.warn(
          `[redline-assistant] superintendent llm error. request_id=${requestId} status=${llmResp.status} body=${llmResp.errorText}`,
        );
      }

      return textSseResponse(finalText, requestId, {
        "x-model-id": modelHeader,
        "x-model-config-source": modelConfig.source,
        "x-assistant-style": SUPERINTENDENT_STYLE,
        "x-assistant-intent": intent,
      });
    }

    // Extract highlights for the effective project (if any)
    let projectHighlights: unknown[] = [];
    let highlightsSource = "rpc";
    if (effectiveProjectId && Array.isArray(groundedPayload?.project_recent_highlights)) {
      const entry = (groundedPayload!.project_recent_highlights as Array<Record<string, unknown>>)
        .find((ph) => String(ph.project_id) === effectiveProjectId);
      if (entry && Array.isArray(entry.highlights)) {
        projectHighlights = entry.highlights as unknown[];
      }
    }

    // Fallback: if RPC returned empty highlights for a resolved project,
    // query interactions + SMS directly. This covers the 3 RPC data loss
    // points (SMS JOIN bug, unattributed filter, narrow window).
    if (projectHighlights.length === 0 && effectiveProjectId) {
      const directHits = await fetchDirectHighlights(db, effectiveProjectId);
      if (directHits.length > 0) {
        projectHighlights = directHits;
        highlightsSource = "direct_query_fallback";
      }
    }

    // Build the grounded context packet for the LLM
    const contextPacket = {
      request_id: requestId,
      function_version: FUNCTION_VERSION,
      contract_version: CONTRACT_VERSION,
      packet_version: toStringOrNull(groundedPayload?.packet_version) ?? CONTRACT_VERSION,
      generated_at_utc: groundedPayload?.generated_at_utc ?? null,
      grounded_source: groundedResult.source === "rpc" ? "assistant_context_v1_rpc" : "projects_fallback",
      grounded_error: groundedResult.error,
      message_scope: {
        contact_id: contactId,
        explicit_project_id: inputProjectId,
        effective_project_id: effectiveProjectId,
      },
      resolution: {
        mode: resolution.mode,
        token: resolution.token,
        matches: resolution.matches.slice(0, 5).map((m) => ({
          project_id: m.id,
          project_name: m.name,
        })),
        resolved_project_id: effectiveProjectId,
      },
      projects_roster: projectsRoster,
      project_recent_highlights: Array.isArray(groundedPayload?.project_recent_highlights)
        ? groundedPayload!.project_recent_highlights
        : [],
      focused_project_highlights: projectHighlights,
      focused_highlights_source: highlightsSource,
      contact_project_candidates: contactCandidates,
    };

    const systemPrompt = `You are the HCB Redline Assistant for Heartwood Custom Builders.
You answer project questions for operators with concise, factual guidance.

DATA GROUNDING RULES (strict):
1) Use ONLY facts present in the CONTEXT_PACKET below. Never hallucinate projects or data.
2) The projects_roster is the canonical list of all known projects. If a project name is in the roster, it exists.
3) project_recent_highlights contains recent interaction events per project, each with interaction_id pointers back to the source.
4) focused_project_highlights contains highlights specifically for the resolved project (if any). These may come from the RPC (with interaction_id, interaction_type, highlight_text) or from direct queries (with id, channel, contact_name, summary_text). Use whichever fields are present.
5) If asked about project roster or "what projects", list project names from projects_roster.
6) For status-style questions, cite at least one concrete highlight (event_at_utc, channel, summary_text or highlight_text) tied to a project name.
7) If resolution.mode is "ambiguous", present the matches and ask the user to pick.
8) If resolution.mode is "none", say no match found and suggest closest roster names.
9) If focused_project_highlights is empty, say you don't have recent activity details for this project, but confirm the project exists if it's in the roster.
10) Cite project names, contact names, and IDs when available.

CONTEXT_PACKET:
${JSON.stringify(contextPacket, null, 2)}
`;

    let activeModel = primaryModel;
    let openAiResponse = await openAiChatCompletionsStream(
      openAiKey,
      primaryModel,
      modelConfig.maxTokens,
      modelConfig.temperature,
      systemPrompt,
      userMessage,
    );

    if (!openAiResponse.ok && fallbackModel && fallbackModel !== primaryModel) {
      const primaryErrorBody = await openAiResponse.text();
      console.warn(
        `[redline-assistant] primary model failed (${primaryModel}). falling back to ${fallbackModel}. status=${openAiResponse.status} body=${primaryErrorBody}`,
      );
      activeModel = fallbackModel;
      openAiResponse = await openAiChatCompletionsStream(
        openAiKey,
        fallbackModel,
        modelConfig.maxTokens,
        modelConfig.temperature,
        systemPrompt,
        userMessage,
      );
    }

    if (!openAiResponse.ok) {
      const errorText = await openAiResponse.text();
      return json(
        {
          ok: false,
          error: "llm_error",
          details: errorText,
          status: openAiResponse.status,
          request_id: requestId,
          function_version: FUNCTION_VERSION,
          contract_version: CONTRACT_VERSION,
        },
        500,
        requestId,
      );
    }

    return new Response(openAiResponse.body, {
      status: 200,
      headers: {
        ...corsHeaders(),
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "x-request-id": requestId,
        "x-function-version": FUNCTION_VERSION,
        "x-contract-version": CONTRACT_VERSION,
        "x-model-id": activeModel,
        "x-model-config-source": modelConfig.source,
        "x-assistant-style": responseStyle,
        "x-assistant-intent": intent,
      },
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "internal_error";
    console.error("[redline-assistant] Error:", message);
    return json(
      {
        ok: false,
        error: "internal_error",
        details: message,
        request_id: requestId,
        function_version: FUNCTION_VERSION,
        contract_version: CONTRACT_VERSION,
      },
      500,
      requestId,
    );
  }
});
