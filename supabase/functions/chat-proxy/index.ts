/**
 * chat-proxy Edge Function v2.0.0
 *
 * Proxies Anthropic Claude completions for the public camber-map page.
 * The API key stays server-side — never sent to the browser.
 * Translates Anthropic SSE → OpenAI-compatible SSE so the client parser is unchanged.
 *
 * Auth: anon key (verify_jwt=false) + origin allowlist.
 * Streams SSE responses back to the client.
 */

const ALLOWED_ORIGINS = [
  "https://hcb-gpt.github.io",
  "http://localhost:3000",
  "http://localhost:5000",
  "http://127.0.0.1:3000",
  "http://127.0.0.1:5000",
];

function corsHeaders(origin: string): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function isAllowedOrigin(req: Request): string | null {
  const origin = req.headers.get("origin") || "";
  if (ALLOWED_ORIGINS.includes(origin)) return origin;
  if (/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) return origin;
  return null;
}

Deno.serve(async (req) => {
  const origin = isAllowedOrigin(req);

  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(origin || "*"),
    });
  }

  if (!origin) {
    return new Response(JSON.stringify({ error: "origin_not_allowed" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
    });
  }

  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
    });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
    });
  }

  // Extract messages from OpenAI-format request
  const inMessages = (body.messages || []) as Array<{ role: string; content: string }>;

  // Separate system messages (Anthropic uses a top-level system param)
  let systemPrompt = "";
  const userMessages: Array<{ role: string; content: string }> = [];
  for (const msg of inMessages) {
    if (msg.role === "system") {
      systemPrompt += (systemPrompt ? "\n\n" : "") + msg.content;
    } else {
      userMessages.push({ role: msg.role, content: msg.content });
    }
  }

  // Build Anthropic request
  const anthropicBody = {
    model: "claude-opus-4-6",
    max_tokens: 2048,
    stream: true,
    ...(systemPrompt ? { system: systemPrompt } : {}),
    messages: userMessages,
  };

  const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": anthropicKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(anthropicBody),
  });

  if (!anthropicRes.ok) {
    const errText = await anthropicRes.text();
    return new Response(JSON.stringify({ error: { message: errText } }), {
      status: anthropicRes.status,
      headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
    });
  }

  // Translate Anthropic SSE → OpenAI-compatible SSE
  const reader = anthropicRes.body!.getReader();
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
            if (jsonStr === "[DONE]") continue;

            try {
              const evt = JSON.parse(jsonStr);

              if (evt.type === "content_block_delta" && evt.delta?.type === "text_delta") {
                // Translate to OpenAI format
                const openaiChunk = {
                  choices: [{ delta: { content: evt.delta.text } }],
                };
                controller.enqueue(encoder.encode(`data: ${JSON.stringify(openaiChunk)}\n\n`));
              } else if (evt.type === "message_stop") {
                controller.enqueue(encoder.encode("data: [DONE]\n\n"));
              }
            } catch {
              // Skip unparseable lines
            }
          }
        }
        // Ensure DONE is sent
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      } catch (err) {
        controller.error(err);
      }
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      ...corsHeaders(origin),
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
    },
  });
});
