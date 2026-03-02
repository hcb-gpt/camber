import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getModelConfigCached } from "../_shared/model_config.ts";

const _FUNCTION_VERSION = "redline-assistant_v0.3.0";
const DEFAULT_MODEL_ID = Deno.env.get("REDLINE_ASSISTANT_MODEL") || "gpt-4o";
const DEFAULT_MAX_TOKENS = Number(
  Deno.env.get("REDLINE_ASSISTANT_MAX_TOKENS") || "1400",
);
const DEFAULT_TEMPERATURE = Number(
  Deno.env.get("REDLINE_ASSISTANT_TEMPERATURE") || "0.2",
);
const DEFAULT_PROVIDER = (Deno.env.get("REDLINE_ASSISTANT_PROVIDER") || "openai").toLowerCase();
const DEFAULT_ANTHROPIC_MODEL = Deno.env.get("REDLINE_ASSISTANT_ANTHROPIC_MODEL") ||
  "claude-3-5-sonnet-latest";
const ROSTER_LIMIT = 50;
const RECENT_INTERACTIONS_LIMIT = 150;
const OPEN_LOOP_LIMIT = 40;

type ProjectRosterItem = {
  project_id: string;
  project_name: string;
  status: string | null;
  risk_flag: string | null;
  last_interaction_at: string | null;
};

type ResolutionOutcome =
  | {
    mode: "single";
    token: string;
    matches: ProjectRosterItem[];
    resolvedProjectId: string;
  }
  | {
    mode: "ambiguous";
    token: string;
    matches: ProjectRosterItem[];
    resolvedProjectId: null;
  }
  | {
    mode: "none";
    token: string;
    matches: ProjectRosterItem[];
    resolvedProjectId: null;
  }
  | {
    mode: "no_signal";
    token: null;
    matches: ProjectRosterItem[];
    resolvedProjectId: null;
  };

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-edge-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

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
    "hardscape",
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
    .map((token) => token.trim())
    .filter((token) => token.length >= 4 && !stopwords.has(token));
}

function isProjectsRosterQuery(message: string): boolean {
  return /what\s+projects|which\s+projects|projects\s+do\s+you\s+have|list\s+projects/i
    .test(message);
}

function stripProjectSuffix(projectName: string): string {
  return normalizeText(projectName).replace(
    /\b(residence|project|home|job|phase)\b/g,
    "",
  ).replace(/\s+/g, " ").trim();
}

function resolveProjectFromMessage(
  message: string,
  roster: ProjectRosterItem[],
): ResolutionOutcome {
  if (!message || roster.length === 0) {
    return {
      mode: "no_signal",
      token: null,
      matches: [],
      resolvedProjectId: null,
    };
  }

  const tokens = tokenizeProjectQuery(message);
  if (tokens.length === 0) {
    return {
      mode: "no_signal",
      token: null,
      matches: [],
      resolvedProjectId: null,
    };
  }

  const scored = roster
    .map((project) => {
      const fullName = normalizeText(project.project_name);
      const stemName = stripProjectSuffix(project.project_name);
      let score = 0;

      for (const token of tokens) {
        if (fullName.includes(token)) score += 20;
        if (stemName && stemName.includes(token)) score += 20;
        if (token === stemName || token === fullName) score += 30;
      }

      if (tokens.length > 0) {
        const joined = tokens.join(" ");
        if (
          fullName.includes(joined) || (stemName && stemName.includes(joined))
        ) {
          score += 50;
        }
      }

      return { project, score };
    })
    .filter((row) => row.score > 0)
    .sort((a, b) => b.score - a.score);

  if (scored.length === 0) {
    return {
      mode: "none",
      token: tokens[0],
      matches: [],
      resolvedProjectId: null,
    };
  }

  const matches = scored.map((row) => row.project);
  if (matches.length === 1) {
    return {
      mode: "single",
      token: tokens[0],
      matches,
      resolvedProjectId: matches[0].project_id,
    };
  }

  return {
    mode: "ambiguous",
    token: tokens[0],
    matches,
    resolvedProjectId: null,
  };
}

function renderProjectsRosterResponse(roster: ProjectRosterItem[]): string {
  if (roster.length === 0) {
    return "I do not have any active projects in the current context packet.";
  }
  const top = roster.slice(0, 15);
  const lines = top.map((project, index) => {
    const status = project.status ? ` (${project.status})` : "";
    return `${index + 1}. ${project.project_name}${status}`;
  });
  return `Grounded project roster (${top.length} shown):\n${lines.join("\n")}`;
}

function renderAmbiguousProjectResponse(
  message: string,
  matches: ProjectRosterItem[],
): string {
  const top = matches.slice(0, 5);
  const lines = top.map((project, index) => `${index + 1}. ${project.project_name}`);
  return `I found multiple project matches for "${message}". Which one do you mean?\n${lines.join("\n")}`;
}

function renderNoMatchProjectResponse(
  token: string,
  roster: ProjectRosterItem[],
): string {
  const suggestions = roster
    .filter((project) => normalizeText(project.project_name).includes(token.slice(0, 3)))
    .slice(0, 5);
  if (suggestions.length === 0) {
    return `I do not see a project matching "${token}" in the current roster.`;
  }
  const suggestionLines = suggestions.map((project, index) => `${index + 1}. ${project.project_name}`);
  return `I do not see a project matching "${token}". Closest matches:\n${suggestionLines.join("\n")}`;
}

function buildSSEChunk(content: string): Uint8Array {
  const payload = JSON.stringify({ choices: [{ delta: { content } }] });
  return new TextEncoder().encode(`data: ${payload}\n\n`);
}

function textSseResponse(
  content: string,
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
      ...extraHeaders,
    },
  });
}

function openAiProxyResponse(
  body: ReadableStream<Uint8Array> | null,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(body, {
    status: 200,
    headers: {
      ...corsHeaders(),
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      ...extraHeaders,
    },
  });
}

async function translateAnthropicToOpenAiSse(
  res: Response,
  extraHeaders: Record<string, string> = {},
): Promise<Response> {
  const reader = res.body?.getReader();
  if (!reader) {
    return textSseResponse(
      "Assistant upstream response was empty.",
      extraHeaders,
    );
  }

  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      let buffer = "";
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || !trimmed.startsWith("data: ")) continue;

            const jsonStr = trimmed.slice(6);
            if (!jsonStr || jsonStr === "[DONE]") continue;

            try {
              const evt = JSON.parse(jsonStr);
              if (
                evt.type === "content_block_delta" &&
                evt.delta?.type === "text_delta"
              ) {
                controller.enqueue(buildSSEChunk(String(evt.delta.text || "")));
              } else if (evt.type === "message_stop") {
                controller.enqueue(encoder.encode("data: [DONE]\n\n"));
              }
            } catch {
              continue;
            }
          }
        }
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      } catch (error) {
        controller.error(error);
      }
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      ...corsHeaders(),
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      ...extraHeaders,
    },
  });
}

async function fetchProjectsRoster(
  db: any,
  limit = ROSTER_LIMIT,
): Promise<ProjectRosterItem[]> {
  const fromMat = await db
    .from("mat_project_context")
    .select(
      "project_id, project_name, project_status, risk_flag, last_interaction_at",
    )
    .order("last_interaction_at", { ascending: false, nullsFirst: false })
    .limit(limit);

  if (!fromMat.error && Array.isArray(fromMat.data)) {
    const roster = fromMat.data
      .map((row: any) => ({
        project_id: String(row.project_id),
        project_name: String(row.project_name || "Unknown Project"),
        status: row.project_status ? String(row.project_status) : null,
        risk_flag: row.risk_flag ? String(row.risk_flag) : null,
        last_interaction_at: row.last_interaction_at ? String(row.last_interaction_at) : null,
      }))
      .filter((row: ProjectRosterItem) => row.project_id && row.project_name);
    if (roster.length > 0) return roster;
  }

  if (fromMat.error) {
    console.warn(
      "[redline-assistant] mat_project_context roster query failed:",
      fromMat.error.message,
    );
  }

  const fromProjects = await db
    .from("projects")
    .select("id, name, status, updated_at")
    .order("updated_at", { ascending: false, nullsFirst: false })
    .limit(limit);

  if (fromProjects.error) {
    console.warn(
      "[redline-assistant] projects roster fallback failed:",
      fromProjects.error.message,
    );
    return [];
  }

  return (fromProjects.data || []).map((row: any) => ({
    project_id: String(row.id),
    project_name: String(row.name || "Unknown Project"),
    status: row.status ? String(row.status) : null,
    risk_flag: null,
    last_interaction_at: row.updated_at ? String(row.updated_at) : null,
  }));
}

async function fetchRecentInteractions(
  db: any,
  roster: ProjectRosterItem[],
  limit = RECENT_INTERACTIONS_LIMIT,
) {
  const interactionsRes = await db
    .from("interactions")
    .select(
      "interaction_id, project_id, event_at_utc, channel, contact_name, human_summary",
    )
    .order("event_at_utc", { ascending: false, nullsFirst: false })
    .limit(limit);

  if (interactionsRes.error) {
    console.warn(
      "[redline-assistant] recent interactions query failed:",
      interactionsRes.error.message,
    );
    return [];
  }

  const data = interactionsRes.data || [];
  const namesByProjectId = new Map<string, string>();
  for (const item of roster) {
    namesByProjectId.set(item.project_id, item.project_name);
  }

  const missingProjectIds = Array.from(
    new Set(
      data
        .map((row: any) => String(row.project_id || ""))
        .filter((projectId: string) => projectId.length > 0 && !namesByProjectId.has(projectId)),
    ),
  );

  if (missingProjectIds.length > 0) {
    const namesRes = await db.from("projects").select("id, name").in(
      "id",
      missingProjectIds,
    );
    if (!namesRes.error) {
      for (const row of namesRes.data || []) {
        namesByProjectId.set(
          String((row as any).id),
          String((row as any).name || ""),
        );
      }
    }
  }

  return data.map((row: any) => ({
    interaction_id: row.interaction_id,
    project_id: row.project_id ?? null,
    project_name: row.project_id ? namesByProjectId.get(String(row.project_id)) ?? null : null,
    event_at_utc: row.event_at_utc ?? null,
    channel: row.channel ?? null,
    contact_name: row.contact_name ?? null,
    human_summary: row.human_summary ?? null,
  }));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders() });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const openaiKey = Deno.env.get("OPENAI_API_KEY");
    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    const db = createClient(supabaseUrl, supabaseKey);

    let requestBody: any = {};
    try {
      requestBody = await req.json();
    } catch {
      return new Response(JSON.stringify({ error: "invalid_json" }), {
        status: 400,
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    const { message, contact_id, project_id, model: requestedModel } = requestBody;

    if (!message) {
      return new Response(JSON.stringify({ error: "message_required" }), {
        status: 400,
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    const projectsRoster = await fetchProjectsRoster(db, ROSTER_LIMIT);
    const resolution = resolveProjectFromMessage(
      String(message),
      projectsRoster,
    );
    const explicitProjectId = typeof project_id === "string" && project_id.trim().length > 0 ? project_id.trim() : null;
    const resolvedProjectId = explicitProjectId ?? resolution.resolvedProjectId;

    if (isProjectsRosterQuery(String(message))) {
      return textSseResponse(renderProjectsRosterResponse(projectsRoster));
    }

    if (!explicitProjectId && resolution.mode === "ambiguous") {
      return textSseResponse(
        renderAmbiguousProjectResponse(String(message), resolution.matches),
      );
    }

    if (!explicitProjectId && resolution.mode === "none" && resolution.token) {
      return textSseResponse(
        renderNoMatchProjectResponse(resolution.token, projectsRoster),
      );
    }

    const context: any = {
      project: null,
      contact: null,
      beliefs: null,
      interactions: [],
      recent_interactions: [],
      open_loops: [],
      projects_roster: projectsRoster,
      pending_triage: null,
      resolution: {
        mode: resolution.mode,
        token: resolution.token,
        matches: resolution.matches.slice(0, 5).map((item) => ({
          project_id: item.project_id,
          project_name: item.project_name,
        })),
        resolved_project_id: resolvedProjectId,
      },
    };

    const [recentInteractions, openLoops, pendingTriage] = await Promise.all([
      fetchRecentInteractions(db, projectsRoster, RECENT_INTERACTIONS_LIMIT),
      db
        .from("journal_open_loops")
        .select("id, project_id, description, loop_type, status, created_at")
        .eq("status", "open")
        .order("created_at", { ascending: false, nullsFirst: false })
        .limit(OPEN_LOOP_LIMIT),
      db.from("v_review_queue_summary").select("*").limit(1).maybeSingle(),
    ]);

    context.recent_interactions = recentInteractions;
    context.open_loops = openLoops.error ? [] : (openLoops.data || []);
    context.pending_triage = pendingTriage.error ? null : pendingTriage.data;

    if (openLoops.error) {
      console.warn(
        "[redline-assistant] open loops query failed:",
        openLoops.error.message,
      );
    }
    if (pendingTriage.error) {
      console.warn(
        "[redline-assistant] review queue summary query failed:",
        pendingTriage.error.message,
      );
    }

    const scopedPromises: Promise<void>[] = [];

    if (resolvedProjectId) {
      scopedPromises.push((async () => {
        const [projectRes, beliefRes, loopRes, interactionRes] = await Promise
          .all([
            db.from("mat_project_context").select("*").eq(
              "project_id",
              resolvedProjectId,
            ).maybeSingle(),
            db.from("mat_belief_context").select("*").eq(
              "project_id",
              resolvedProjectId,
            ).maybeSingle(),
            db
              .from("journal_open_loops")
              .select(
                "id, project_id, description, loop_type, status, created_at",
              )
              .eq("project_id", resolvedProjectId)
              .eq("status", "open")
              .order("created_at", { ascending: false, nullsFirst: false })
              .limit(20),
            db
              .from("interactions")
              .select(
                "interaction_id, project_id, contact_name, event_at_utc, channel, human_summary",
              )
              .eq("project_id", resolvedProjectId)
              .order("event_at_utc", { ascending: false, nullsFirst: false })
              .limit(30),
          ]);

        if (!projectRes.error) context.project = projectRes.data;
        if (!beliefRes.error) context.beliefs = beliefRes.data;
        if (!loopRes.error) context.project_open_loops = loopRes.data || [];
        if (!interactionRes.error) {
          context.interactions = interactionRes.data || [];
        }

        if (projectRes.error) {
          console.warn(
            "[redline-assistant] project context failed:",
            projectRes.error.message,
          );
        }
        if (beliefRes.error) {
          console.warn(
            "[redline-assistant] belief context failed:",
            beliefRes.error.message,
          );
        }
        if (loopRes.error) {
          console.warn(
            "[redline-assistant] project open loops failed:",
            loopRes.error.message,
          );
        }
        if (interactionRes.error) {
          console.warn(
            "[redline-assistant] project interactions failed:",
            interactionRes.error.message,
          );
        }
      })());
    } else if (contact_id) {
      scopedPromises.push((async () => {
        const [contactRes, interactionRes] = await Promise.all([
          db.from("mat_contact_context").select("*").eq(
            "contact_id",
            contact_id,
          ).maybeSingle(),
          db
            .from("interactions")
            .select(
              "interaction_id, project_id, contact_name, event_at_utc, channel, human_summary",
            )
            .eq("contact_id", contact_id)
            .order("event_at_utc", { ascending: false, nullsFirst: false })
            .limit(30),
        ]);
        if (!contactRes.error) context.contact = contactRes.data;
        if (!interactionRes.error) {
          context.interactions = interactionRes.data || [];
        }
        if (contactRes.error) {
          console.warn(
            "[redline-assistant] contact context failed:",
            contactRes.error.message,
          );
        }
        if (interactionRes.error) {
          console.warn(
            "[redline-assistant] contact interactions failed:",
            interactionRes.error.message,
          );
        }
      })());
    }

    await Promise.all(scopedPromises);

    const modelConfig = await getModelConfigCached(db, {
      functionName: "redline-assistant",
      modelId: DEFAULT_MODEL_ID,
      maxTokens: DEFAULT_MAX_TOKENS,
      temperature: DEFAULT_TEMPERATURE,
      provider: DEFAULT_PROVIDER,
    });

    let runtimeProvider = String(modelConfig.provider || DEFAULT_PROVIDER)
      .toLowerCase();
    const runtimeModelId = typeof requestedModel === "string" && requestedModel.trim().length > 0
      ? requestedModel.trim()
      : modelConfig.modelId;
    let providerWarning: string | null = null;

    if (runtimeProvider === "anthropic" && !anthropicKey) {
      runtimeProvider = "openai";
      providerWarning = "anthropic_configured_but_missing_key_fell_back_to_openai";
      console.warn(
        "[redline-assistant] ANTHROPIC_API_KEY missing; falling back to OpenAI.",
      );
    }

    if (runtimeProvider === "openai" && !openaiKey) {
      return new Response(JSON.stringify({ error: "openai_api_key_missing" }), {
        status: 500,
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    context.runtime = {
      provider: runtimeProvider,
      model_id: runtimeModelId,
      provider_warning: providerWarning,
      config_source: modelConfig.source,
      resolved_project_id: resolvedProjectId,
    };

    const systemPrompt =
      `You are the HCB Redline Assistant. You help Chad (CTO) and Zack (GC) understand what's going on in their construction projects.
HCB = Heartwood Custom Builders. Zack is the lead GC. Use only the provided context packet.
Grounding rules:
- Never claim a project exists unless it appears in projects_roster.
- If resolution.mode is "ambiguous", ask the user to pick from resolution.matches.
- If resolution.mode is "none", say no exact match and suggest closest roster names.
- If the question is project-specific, include at least one interaction_id when available.
- Keep response concise and concrete.

CONTEXT PACKET:
${JSON.stringify(context, null, 2)}
`;

    if (runtimeProvider === "anthropic") {
      const anthropicModel = runtimeModelId.toLowerCase().includes("claude") ? runtimeModelId : DEFAULT_ANTHROPIC_MODEL;

      const anthropicBody = {
        model: anthropicModel,
        max_tokens: modelConfig.maxTokens,
        temperature: modelConfig.temperature,
        stream: true,
        system: systemPrompt,
        messages: [{ role: "user", content: String(message) }],
      };

      const anthropicRes = await fetch(
        "https://api.anthropic.com/v1/messages",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-api-key": anthropicKey!,
            "anthropic-version": "2023-06-01",
          },
          body: JSON.stringify(anthropicBody),
        },
      );

      if (!anthropicRes.ok) {
        const errText = await anthropicRes.text();
        console.error("[redline-assistant] Anthropic API error:", errText);
        return new Response(
          JSON.stringify({
            error: "llm_error",
            provider: "anthropic",
            details: errText,
          }),
          {
            status: 500,
            headers: { "Content-Type": "application/json", ...corsHeaders() },
          },
        );
      }

      const headers: Record<string, string> = {
        "x-assistant-provider": "anthropic",
        "x-assistant-model": anthropicModel,
      };
      if (providerWarning) {
        headers["x-assistant-provider-warning"] = providerWarning;
      }
      return await translateAnthropicToOpenAiSse(anthropicRes, headers);
    }

    const openaiBody = {
      model: runtimeModelId,
      max_tokens: modelConfig.maxTokens,
      temperature: modelConfig.temperature,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: String(message) },
      ],
      stream: true,
    };

    const openaiRes = await fetch(
      "https://api.openai.com/v1/chat/completions",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${openaiKey!}`,
        },
        body: JSON.stringify(openaiBody),
      },
    );

    if (!openaiRes.ok) {
      const errText = await openaiRes.text();
      console.error("[redline-assistant] OpenAI API error:", errText);
      return new Response(
        JSON.stringify({
          error: "llm_error",
          provider: "openai",
          details: errText,
        }),
        {
          status: 500,
          headers: { "Content-Type": "application/json", ...corsHeaders() },
        },
      );
    }

    const headers: Record<string, string> = {
      "x-assistant-provider": "openai",
      "x-assistant-model": runtimeModelId,
    };
    if (providerWarning) {
      headers["x-assistant-provider-warning"] = providerWarning;
    }
    return openAiProxyResponse(openaiRes.body, headers);
  } catch (err: any) {
    console.error("[redline-assistant] Error:", err.message);
    return new Response(
      JSON.stringify({ error: "internal_error", details: err.message }),
      {
        status: 500,
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      },
    );
  }
});
