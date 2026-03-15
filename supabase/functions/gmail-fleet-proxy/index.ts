import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { gmailApiGetJson, resolveGmailAccessToken } from "../_shared/gmail.ts";
import { decodeGmailMessageText, extractHeader } from "../gmail-financial-pipeline/extraction.ts";

const JSON_HEADERS = { "Content-Type": "application/json" };
const DEFAULT_MAX_RESULTS = 10;
const MAX_MAX_RESULTS = 20;
const ALLOWED_SOURCES = ["orbit-gmail-mcp", "strat", "operator", "gmail-fleet-proxy"];

interface AttachmentInfo {
  attachment_id: string;
  filename: string;
  mime_type: string | null;
  part_id: string | null;
  size: number | null;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: JSON_HEADERS,
  });
}

function safeArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : [];
}

function clampInteger(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

function normalizeWhitespace(value: string | null): string {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function parseDateToIso(raw: string | null): string | null {
  const parsed = Date.parse(String(raw || ""));
  if (!Number.isFinite(parsed)) return null;
  return new Date(parsed).toISOString();
}

function collectAttachments(payload: unknown): AttachmentInfo[] {
  const out: AttachmentInfo[] = [];

  function walk(part: unknown): void {
    if (!part || typeof part !== "object") return;
    const typed = part as Record<string, unknown>;
    const filename = normalizeWhitespace(String(typed.filename || ""));
    const mimeType = normalizeWhitespace(String(typed.mimeType || "")) || null;
    const partId = normalizeWhitespace(String(typed.partId || "")) || null;
    const body = typed.body && typeof typed.body === "object" ? typed.body as Record<string, unknown> : {};
    const attachmentId = normalizeWhitespace(String(body.attachmentId || ""));
    const size = body.size === undefined || body.size === null ? null : Number(body.size);

    if (filename || attachmentId) {
      out.push({
        attachment_id: attachmentId,
        filename: filename || "(unnamed)",
        mime_type: mimeType,
        part_id: partId,
        size: Number.isFinite(size) ? size : null,
      });
    }

    for (const child of safeArray<unknown>(typed.parts)) {
      walk(child);
    }
  }

  walk(payload);
  return out;
}

function evidenceLocator(threadId: string | null, messageId: string): string {
  if (threadId) return `gmail:thread/${threadId}#msg=${messageId}`;
  return `gmail:msg/${messageId}`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "post_only" }, 405);
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code || "invalid_edge_secret");
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const warnings: string[] = [];
  const access = await resolveGmailAccessToken({ env: Deno.env, warnings });
  if (!access.token) {
    return json({
      ok: false,
      error: "gmail_auth_unconfigured",
      auth_mode: access.authMode,
      warnings,
    }, 500);
  }

  const action = String(body.action || "").trim().toLowerCase();
  if (action === "search") {
    const query = String(body.query || "").trim();
    if (!query) {
      return json({ ok: false, error: "missing_query" }, 400);
    }

    const maxResults = clampInteger(body.max_results, DEFAULT_MAX_RESULTS, 1, MAX_MAX_RESULTS);
    const pageToken = String(body.page_token || "").trim();
    const includeSpamTrash = body.include_spam_trash === true;

    const listResp = await gmailApiGetJson({
      token: access.token,
      path: "messages",
      params: {
        q: query,
        maxResults,
        pageToken: pageToken || undefined,
        includeSpamTrash: includeSpamTrash ? "true" : "false",
        fields: "messages(id,threadId),nextPageToken,resultSizeEstimate",
      },
    });

    if (!listResp.ok) {
      return json({
        ok: false,
        error: "gmail_search_failed",
        gmail_status: listResp.status,
        auth_mode: access.authMode,
        warnings,
      }, 502);
    }

    const messages = [];
    for (const item of safeArray<Record<string, unknown>>(listResp.json?.messages)) {
      const messageId = String(item?.id || "").trim();
      if (!messageId) continue;

      const metadataResp = await gmailApiGetJson({
        token: access.token,
        path: `messages/${encodeURIComponent(messageId)}`,
        params: {
          format: "metadata",
          metadataHeaders: ["Subject", "From", "To", "Date"],
          fields: "id,threadId,labelIds,internalDate,snippet,payload(headers)",
        },
      });

      if (!metadataResp.ok) {
        warnings.push(
          metadataResp.status > 0
            ? `gmail_metadata_failed_http_${metadataResp.status}`
            : "gmail_metadata_network_error",
        );
        continue;
      }

      const message = metadataResp.json || {};
      const headers = safeArray<Record<string, unknown>>(message?.payload?.headers);
      const dateHeader = extractHeader(headers, "Date");
      const internalMs = message?.internalDate ? Number(message.internalDate) : null;
      const dateIso = internalMs && Number.isFinite(internalMs)
        ? new Date(internalMs).toISOString()
        : parseDateToIso(dateHeader);

      messages.push({
        message_id: String(message.id || messageId),
        thread_id: message.threadId ? String(message.threadId) : null,
        label_ids: safeArray<string>(message.labelIds).map((value) => String(value || "")).filter(Boolean),
        date: dateIso,
        from: extractHeader(headers, "From"),
        to: extractHeader(headers, "To"),
        subject: extractHeader(headers, "Subject"),
        snippet: normalizeWhitespace(String(message.snippet || "")) || null,
        evidence_locator: evidenceLocator(
          message.threadId ? String(message.threadId) : null,
          String(message.id || messageId),
        ),
      });
    }

    return json({
      ok: true,
      action: "search",
      auth_mode: access.authMode,
      warnings,
      query,
      next_page_token: typeof listResp.json?.nextPageToken === "string" ? listResp.json.nextPageToken : null,
      result_size_estimate: Number(listResp.json?.resultSizeEstimate || messages.length) || messages.length,
      messages,
    });
  }

  if (action === "read") {
    const messageId = String(body.message_id || body.messageId || "").trim();
    if (!messageId) {
      return json({ ok: false, error: "missing_message_id" }, 400);
    }

    const messageResp = await gmailApiGetJson({
      token: access.token,
      path: `messages/${encodeURIComponent(messageId)}`,
      params: {
        format: "full",
        fields: "id,threadId,labelIds,internalDate,snippet,sizeEstimate,historyId," +
          "payload(headers,mimeType,filename,body/data,body/attachmentId,body/size," +
          "parts(partId,mimeType,filename,body/data,body/attachmentId,body/size,headers," +
          "parts(partId,mimeType,filename,body/data,body/attachmentId,body/size,headers,parts)))",
      },
    });

    if (!messageResp.ok) {
      return json({
        ok: false,
        error: "gmail_read_failed",
        gmail_status: messageResp.status,
        auth_mode: access.authMode,
        warnings,
      }, 502);
    }

    const message = messageResp.json || {};
    const payload = message.payload || {};
    const headers = safeArray<Record<string, unknown>>(payload?.headers);
    const dateHeader = extractHeader(headers, "Date");
    const internalMs = message?.internalDate ? Number(message.internalDate) : null;
    const dateIso = internalMs && Number.isFinite(internalMs)
      ? new Date(internalMs).toISOString()
      : parseDateToIso(dateHeader);
    const snippet = normalizeWhitespace(String(message.snippet || "")) || null;
    const bodyText = [snippet || "", decodeGmailMessageText(payload)].filter(Boolean).join("\n\n").trim() || null;

    return json({
      ok: true,
      action: "read",
      auth_mode: access.authMode,
      warnings,
      message: {
        message_id: String(message.id || messageId),
        thread_id: message.threadId ? String(message.threadId) : null,
        label_ids: safeArray<string>(message.labelIds).map((value) => String(value || "")).filter(Boolean),
        history_id: message.historyId ? String(message.historyId) : null,
        size_estimate: message.sizeEstimate === undefined || message.sizeEstimate === null
          ? null
          : Number(message.sizeEstimate),
        date: dateIso,
        from: extractHeader(headers, "From"),
        to: extractHeader(headers, "To"),
        cc: extractHeader(headers, "Cc"),
        bcc: extractHeader(headers, "Bcc"),
        subject: extractHeader(headers, "Subject"),
        snippet,
        body_text: bodyText,
        attachments: collectAttachments(payload),
        evidence_locator: evidenceLocator(
          message.threadId ? String(message.threadId) : null,
          String(message.id || messageId),
        ),
      },
    });
  }

  return json({
    ok: false,
    error: "unsupported_action",
    supported_actions: ["search", "read"],
  }, 400);
});
