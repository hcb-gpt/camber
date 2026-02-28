import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getModelConfigCached } from "../_shared/model_config.ts";

const _FUNCTION_VERSION = "redline-assistant_v0.2.0";
const DEFAULT_MODEL_ID = Deno.env.get("REDLINE_ASSISTANT_MODEL") || "gpt-4o";
const DEFAULT_MAX_TOKENS = Number(Deno.env.get("REDLINE_ASSISTANT_MAX_TOKENS") || "1400");
const DEFAULT_TEMPERATURE = Number(Deno.env.get("REDLINE_ASSISTANT_TEMPERATURE") || "0.2");

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-edge-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders() });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const openaiKey = Deno.env.get("OPENAI_API_KEY")!;
    const db = createClient(supabaseUrl, supabaseKey);

    const { message, contact_id, project_id, model: requestedModel } = await req.json();

    if (!message) {
      return new Response(JSON.stringify({ error: "message_required" }), {
        status: 400,
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // 1. Gather Context Packet
    const context: any = {
      project: null,
      contact: null,
      beliefs: null,
      interactions: [],
      open_loops: [],
    };

    const promises = [];

    if (project_id) {
      promises.push(
        db.from("mat_project_context").select("*").eq("project_id", project_id).maybeSingle().then((res) => {
          context.project = res.data;
        }),
      );
      promises.push(
        db.from("mat_belief_context").select("*").eq("project_id", project_id).maybeSingle().then((res) => {
          context.beliefs = res.data;
        }),
      );
      promises.push(
        db.from("journal_open_loops").select("*").eq("project_id", project_id).eq("status", "open").limit(10).then(
          (res) => {
            context.open_loops = res.data || [];
          },
        ),
      );
      promises.push(
        db.from("interactions").select("interaction_id, contact_name, event_at_utc, human_summary").eq(
          "project_id",
          project_id,
        ).order("event_at_utc", { ascending: false }).limit(15).then((res) => {
          context.interactions = res.data || [];
        }),
      );
    } else if (contact_id) {
      promises.push(
        db.from("mat_contact_context").select("*").eq("contact_id", contact_id).maybeSingle().then((res) => {
          context.contact = res.data;
        }),
      );
      promises.push(
        db.from("interactions").select("interaction_id, contact_name, event_at_utc, human_summary").eq(
          "contact_id",
          contact_id,
        ).order("event_at_utc", { ascending: false }).limit(15).then((res) => {
          context.interactions = res.data || [];
        }),
      );
    } else {
      // Global context
      promises.push(
        db.from("interactions").select("interaction_id, contact_name, event_at_utc, human_summary").order(
          "event_at_utc",
          { ascending: false },
        ).limit(20).then((res) => {
          context.interactions = res.data || [];
        }),
      );
      promises.push(
        db.from("mat_project_context").select("project_name, project_status, risk_flag, last_interaction_at").order(
          "last_interaction_at",
          { ascending: false },
        ).limit(5).then((res) => {
          context.top_projects = res.data || [];
        }),
      );
    }

    await Promise.all(promises);

    const modelConfig = await getModelConfigCached(db, {
      functionName: "redline-assistant",
      modelId: DEFAULT_MODEL_ID,
      maxTokens: DEFAULT_MAX_TOKENS,
      temperature: DEFAULT_TEMPERATURE,
    });
    const runtimeModelId = typeof requestedModel === "string" && requestedModel.trim().length > 0
      ? requestedModel.trim()
      : modelConfig.modelId;

    // 2. Build Prompt
    const systemPrompt =
      `You are the HCB Redline Assistant. You help Chad (CTO) and Zack (GC) understand what's going on in their construction projects.
HCB = Heartwood Custom Builders. Zack is the lead GC.
Use the provided context packet to answer the user's message. 
Be concise, professional, and builder-focused.
Always cite Interaction IDs or Project names when referencing specific events.
If you don't know the answer, say so.

CONTEXT PACKET:
${JSON.stringify(context, null, 2)}
`;

    // 3. Call OpenAI (Streaming)
    const openaiBody = {
      model: runtimeModelId,
      max_tokens: modelConfig.maxTokens,
      temperature: modelConfig.temperature,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: message },
      ],
      stream: true,
    };

    const openaiRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${openaiKey}`,
      },
      body: JSON.stringify(openaiBody),
    });

    if (!openaiRes.ok) {
      const errText = await openaiRes.text();
      console.error("[redline-assistant] OpenAI API error:", errText);
      return new Response(JSON.stringify({ error: "llm_error", details: errText }), {
        status: 500,
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // 4. Proxy Stream
    return new Response(openaiRes.body, {
      status: 200,
      headers: {
        ...corsHeaders(),
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
      },
    });
  } catch (err: any) {
    console.error("[redline-assistant] Error:", err.message);
    return new Response(JSON.stringify({ error: "internal_error", details: err.message }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }
});
