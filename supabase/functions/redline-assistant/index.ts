import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";
import { getModelConfigCached } from "../_shared/model_config.ts";

const FUNCTION_VERSION = "redline-assistant_v0.3.0";
const DEFAULT_MODEL_ID = "gpt-4o";
const DEFAULT_MAX_TOKENS = 2048;
const DEFAULT_TEMPERATURE = 0.7;

type ContactProjectCandidate = {
  project_id: string;
  project_name: string | null;
  project_status: string | null;
  last_interaction_at: string | null;
};

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-edge-secret, x-request-id",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Expose-Headers":
      "x-request-id,x-assistant-context-request-id,x-assistant-context-contract-version,x-model-id,x-model-config-source",
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
      ...(extraHeaders ?? {}),
    },
  });
}

function toStringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

async function resolveContactProjectCandidates(
  db: SupabaseClient,
  contactId: string | null,
): Promise<
  { candidates: ContactProjectCandidate[]; autoProjectId: string | null }
> {
  if (!contactId) {
    return { candidates: [], autoProjectId: null };
  }

  const { data: interactionRows } = await db
    .from("interactions")
    .select("project_id, event_at_utc")
    .eq("contact_id", contactId)
    .not("project_id", "is", null)
    .order("event_at_utc", { ascending: false })
    .limit(50);

  const rows = Array.isArray(interactionRows)
    ? (interactionRows as Array<Record<string, unknown>>)
    : [];
  const latestByProject = new Map<string, string | null>();

  for (const row of rows) {
    const projectId = toStringOrNull(row.project_id);
    if (!projectId || latestByProject.has(projectId)) {
      continue;
    }
    latestByProject.set(projectId, toStringOrNull(row.event_at_utc));
  }

  const projectIds = Array.from(latestByProject.keys());
  if (projectIds.length === 0) {
    return { candidates: [], autoProjectId: null };
  }

  const { data: projectRows } = await db
    .from("projects")
    .select("id, name, status")
    .in("id", projectIds);

  const projectMap = new Map<string, Record<string, unknown>>();
  for (
    const row of Array.isArray(projectRows)
      ? (projectRows as Array<Record<string, unknown>>)
      : []
  ) {
    const id = toStringOrNull(row.id);
    if (id) {
      projectMap.set(id, row);
    }
  }

  const candidates: ContactProjectCandidate[] = projectIds.map((projectId) => {
    const projectRow = projectMap.get(projectId);
    return {
      project_id: projectId,
      project_name: toStringOrNull(projectRow?.name ?? null),
      project_status: toStringOrNull(projectRow?.status ?? null),
      last_interaction_at: latestByProject.get(projectId) ?? null,
    };
  });

  candidates.sort((left, right) =>
    (right.last_interaction_at ?? "").localeCompare(
      left.last_interaction_at ?? "",
    )
  );

  return {
    candidates,
    autoProjectId: candidates.length === 1 ? candidates[0].project_id : null,
  };
}

async function fetchAssistantContext(
  supabaseUrl: string,
  serviceRoleKey: string,
  requestId: string,
  projectId: string | null,
): Promise<{
  packet: Record<string, unknown> | null;
  headerRequestId: string | null;
  contractVersion: string | null;
  error: string | null;
  status: number | null;
}> {
  const url = new URL(`${supabaseUrl}/functions/v1/assistant-context`);
  url.searchParams.set("limit", "10");
  if (projectId) {
    url.searchParams.set("project_id", projectId);
  }

  try {
    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${serviceRoleKey}`,
        "apikey": serviceRoleKey,
        "x-request-id": requestId,
      },
    });

    const headerRequestId = response.headers.get("x-request-id");
    const contractVersionHeader = response.headers.get(
      "x-assistant-context-contract-version",
    );
    const rawBody = await response.text();

    let parsedBody: Record<string, unknown> | null = null;
    try {
      parsedBody = JSON.parse(rawBody) as Record<string, unknown>;
    } catch {
      parsedBody = null;
    }

    if (!response.ok) {
      return {
        packet: parsedBody,
        headerRequestId,
        contractVersion: contractVersionHeader,
        error: `assistant_context_http_${response.status}`,
        status: response.status,
      };
    }

    return {
      packet: parsedBody,
      headerRequestId,
      contractVersion: toStringOrNull(parsedBody?.contract_version) ??
        contractVersionHeader,
      error: null,
      status: response.status,
    };
  } catch (error: unknown) {
    return {
      packet: null,
      headerRequestId: null,
      contractVersion: null,
      error: error instanceof Error
        ? error.message
        : "assistant_context_fetch_failed",
      status: null,
    };
  }
}

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

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders() });
  }

  const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();
  if (req.method !== "POST") {
    return json(
      {
        ok: false,
        error: "method_not_allowed",
        request_id: requestId,
        function_version: FUNCTION_VERSION,
      },
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
        {
          ok: false,
          error: "missing_supabase_config",
          request_id: requestId,
          function_version: FUNCTION_VERSION,
        },
        500,
        requestId,
      );
    }
    if (!openAiKey) {
      return json(
        {
          ok: false,
          error: "missing_openai_key",
          request_id: requestId,
          function_version: FUNCTION_VERSION,
        },
        500,
        requestId,
      );
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json(
        {
          ok: false,
          error: "invalid_json",
          request_id: requestId,
          function_version: FUNCTION_VERSION,
        },
        400,
        requestId,
      );
    }

    const userMessage = toStringOrNull(body.message);
    if (!userMessage) {
      return json(
        {
          ok: false,
          error: "message_required",
          request_id: requestId,
          function_version: FUNCTION_VERSION,
        },
        400,
        requestId,
      );
    }

    const requestedModel = toStringOrNull(body.model);
    const inputProjectId = toStringOrNull(body.project_id);
    const contactId = toStringOrNull(body.contact_id);

    const db = createClient(supabaseUrl, supabaseKey);
    const modelConfig = await getModelConfigCached(db, {
      functionName: "redline-assistant",
      modelId: DEFAULT_MODEL_ID,
      maxTokens: DEFAULT_MAX_TOKENS,
      temperature: DEFAULT_TEMPERATURE,
    });

    const { candidates, autoProjectId } = await resolveContactProjectCandidates(
      db,
      contactId,
    );
    const effectiveProjectId = inputProjectId ?? autoProjectId;

    const assistantContext = await fetchAssistantContext(
      supabaseUrl,
      supabaseKey,
      requestId,
      effectiveProjectId,
    );

    const assistantContextPacket = assistantContext.packet;
    const assistantContextRequestId =
      toStringOrNull(assistantContextPacket?.request_id) ??
        assistantContext.headerRequestId;
    const assistantContextContractVersion =
      toStringOrNull(assistantContextPacket?.contract_version) ??
        assistantContext.contractVersion;

    const assistantContextV1 = {
      request_id: assistantContextRequestId,
      function_version: toStringOrNull(
        assistantContextPacket?.function_version,
      ),
      contract_version: assistantContextContractVersion,
      metric_contract: assistantContextPacket?.metric_contract ?? null,
      top_projects: Array.isArray(assistantContextPacket?.top_projects)
        ? assistantContextPacket?.top_projects
        : [],
      who_needs_you: Array.isArray(assistantContextPacket?.who_needs_you)
        ? assistantContextPacket?.who_needs_you
        : [],
      review_pressure: assistantContextPacket?.review_pressure ?? null,
      review_pressure_by_project:
        Array.isArray(assistantContextPacket?.review_pressure_by_project)
          ? assistantContextPacket?.review_pressure_by_project
          : [],
      recent_activity: assistantContextPacket?.recent_activity ?? null,
      project_context: assistantContextPacket?.project_context ?? null,
      fetch_status: assistantContext.error ? "error" : "ok",
      fetch_error: assistantContext.error,
      fetch_http_status: assistantContext.status,
    };

    const context = {
      request_id: requestId,
      function_version: FUNCTION_VERSION,
      message_scope: {
        contact_id: contactId,
        explicit_project_id: inputProjectId,
        effective_project_id: effectiveProjectId,
      },
      contact_project_candidates: candidates,
      single_project_auto: {
        applied: !inputProjectId && !!autoProjectId,
        project_id: autoProjectId,
      },
      assistant_context_v1: assistantContextV1,
    };

    const systemPrompt =
      `You are the HCB Redline Assistant for Heartwood Custom Builders.
You answer project questions for operators with concise, factual guidance.

Hard response rules:
1) Use ONLY facts present in assistant_context_v1 and contact candidate context.
2) If asked about project roster, return project names from assistant_context_v1.top_projects.
3) If "Winship Residence" is present in top_projects and user asks about Winship or projects, explicitly mention "Winship Residence".
4) For status-style questions, include at least one concrete recent fact (metric or timeline item) tied to a project name.
5) If context is missing, say exactly what is missing.
6) Cite project names and interaction IDs when available.

CONTEXT_PACKET_ASSISTANT_CONTEXT_V1:
${JSON.stringify(context, null, 2)}
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
          assistant_context_request_id: assistantContextRequestId,
          assistant_context_contract_version: assistantContextContractVersion,
          function_version: FUNCTION_VERSION,
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
        "x-model-id": activeModel,
        "x-model-config-source": modelConfig.source,
        ...(assistantContextRequestId
          ? { "x-assistant-context-request-id": assistantContextRequestId }
          : {}),
        ...(assistantContextContractVersion
          ? {
            "x-assistant-context-contract-version":
              assistantContextContractVersion,
          }
          : {}),
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
      },
      500,
      requestId,
    );
  }
});
