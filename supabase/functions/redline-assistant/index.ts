import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getModelConfigCached } from "../_shared/model_config.ts";

const FUNCTION_VERSION = "redline-assistant_v0.5.0";
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
      "x-request-id,x-contract-version,x-function-version,x-model-id,x-model-config-source,x-assistant-context-request-id,x-assistant-context-contract-version",
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
      ...(requestId ? { "x-request-id": requestId, "x-assistant-context-request-id": requestId } : {}),
      "x-function-version": FUNCTION_VERSION,
      "x-contract-version": CONTRACT_VERSION,
      "x-assistant-context-contract-version": CONTRACT_VERSION,
      ...(extraHeaders ?? {}),
    },
  });
}

function toStringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
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
      "x-assistant-context-request-id": requestId,
      "x-function-version": FUNCTION_VERSION,
      "x-contract-version": CONTRACT_VERSION,
      "x-assistant-context-contract-version": CONTRACT_VERSION,
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
// OpenAI streaming
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

    const requestedModel = toStringOrNull(body.model);
    const inputProjectId = toStringOrNull(body.project_id);
    const contactId = toStringOrNull(body.contact_id);

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

    // Handle roster-listing queries directly (no LLM needed)
    if (isProjectsRosterQuery(userMessage)) {
      const lines = projectsRoster.slice(0, 50).map((p, i) => {
        const status = p.status ? ` (${p.status})` : "";
        return `${i + 1}. ${p.name}${status}`;
      });
      const answer = projectsRoster.length > 0
        ? `Active project roster (${lines.length} shown):\n${lines.join("\n")}`
        : "No projects found in the current context.";
      return textSseResponse(answer, requestId);
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
6) For status-style questions, cite at least one concrete highlight (event_at_utc, channel, summary_text or highlight_text) and EXPLICITLY include its interaction_id (e.g. cll_XYZ) when available in the packet. Also, explicitly state the count of interactions found for the project (e.g., "Found 3 interactions").
7) If resolution.mode is "ambiguous", present the matches and ask the user to pick.
8) If resolution.mode is "none", say no match found and suggest closest roster names.
9) If focused_project_highlights is empty, say you don't have recent activity details for this project, but confirm the project exists if it's in the roster.
10) Cite project names, contact names, and IDs when available.

CONTEXT_PACKET:
${JSON.stringify(contextPacket, null, 2)}
`;

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
        "x-assistant-context-request-id": requestId,
        "x-function-version": FUNCTION_VERSION,
        "x-contract-version": CONTRACT_VERSION,
        "x-assistant-context-contract-version": CONTRACT_VERSION,
        "x-model-id": activeModel,
        "x-model-config-source": modelConfig.source,
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
