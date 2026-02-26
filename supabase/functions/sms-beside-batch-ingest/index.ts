/**
 * sms-beside-batch-ingest Edge Function v1.0.0
 * Zapier SMS batch webhook receiver for Beside VoIP SMS messages
 *
 * @version 1.0.0
 * @date 2026-02-26
 * @purpose Receive batched SMS messages from Zapier Digest, insert into sms_messages table.
 *          The existing bridge_sms_message_to_surfaces trigger (v2) handles downstream
 *          writes to calls_raw and interactions with contact resolution.
 *
 * Called by: Zapier Digest (threshold trigger)
 * Auth: Internal pattern (X-Edge-Secret + source allowlist)
 * verify_jwt = false (config.toml)
 *
 * Write path:
 *   sms_messages: UPSERT (ON CONFLICT message_id DO NOTHING) for idempotency
 *
 * Payload formats handled:
 *   Format A: digest_raw (newline-delimited JSON string)
 *   Format B: messages (JSON array)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

// ============================================================
// TYPES
// ============================================================

interface BesideSmsEntry {
  message_id: string;
  created_at: string; // "2024-10-24 14:36:46.978847 +0000 UTC"
  from_name: string;
  from_phone: string;
  to_name: string;
  to_phone: string;
  direction: "inbound" | "outbound";
  text: string;
}

interface BatchPayload {
  mode?: string;
  count?: number;
  digest_raw?: string;
  messages?: BesideSmsEntry[];
}

// ============================================================
// CONSTANTS
// ============================================================

const VERSION = "sms-beside-batch-ingest_v1.0.0";
const ALLOWED_SOURCES = ["zapier", "test", "edge"];
const ZACK_INBOX_ID = "ibx_QT0G91CPXD7N1090RC2FQ1WXJ8";
const ZACK_BESIDE_LINE = "+17066889158";

// ============================================================
// MAIN
// ============================================================

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(),
    });
  }

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "POST_ONLY" }, 405);
  }

  // ========================================
  // 1. AUTH — X-Edge-Secret + source allowlist
  // ========================================
  const authResult = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!authResult.ok) {
    return authErrorResponse(authResult.error_code!);
  }

  // ========================================
  // 2. PARSE BODY — handle both payload formats
  // ========================================
  let rawBody: string;
  try {
    rawBody = await req.text();
  } catch {
    return jsonResponse({ ok: false, error: "BODY_READ_FAILED" }, 400);
  }

  if (!rawBody || rawBody.trim().length === 0) {
    return jsonResponse({ ok: false, error: "EMPTY_BODY" }, 400);
  }

  let messages: BesideSmsEntry[] = [];
  const parseErrors: string[] = [];

  // Try to parse as JSON first
  let body: BatchPayload | null = null;
  try {
    body = JSON.parse(rawBody);
  } catch {
    // If the outer JSON parse fails, it might be the Zapier bug where
    // digest_raw is injected raw. Try to salvage by treating the whole
    // body as newline-delimited JSON.
    console.warn(
      `[sms-beside-batch-ingest] Outer JSON parse failed, attempting NDJSON fallback`,
    );
    messages = parseNdjson(rawBody, parseErrors);
  }

  if (body) {
    // Format B: messages array
    if (Array.isArray(body.messages) && body.messages.length > 0) {
      messages = body.messages;
    } // Format A: digest_raw string (newline-delimited JSON)
    else if (typeof body.digest_raw === "string" && body.digest_raw.length > 0) {
      messages = parseNdjson(body.digest_raw, parseErrors);
    } // Format A fallback: digest_raw as array (Zapier sometimes does this)
    else if (Array.isArray(body.digest_raw)) {
      messages = body.digest_raw as unknown as BesideSmsEntry[];
    } else {
      return jsonResponse({
        ok: false,
        error: "NO_MESSAGES",
        detail: "Payload must include 'messages' array or 'digest_raw' string",
      }, 400);
    }
  }

  if (messages.length === 0 && parseErrors.length > 0) {
    return jsonResponse({
      ok: false,
      error: "ALL_PARSE_FAILED",
      detail: `All ${parseErrors.length} message(s) failed to parse`,
      parse_errors: parseErrors,
    }, 400);
  }

  if (messages.length === 0) {
    return jsonResponse({
      ok: false,
      error: "NO_MESSAGES",
      detail: "No messages found in payload",
    }, 400);
  }

  console.log(
    `[sms-beside-batch-ingest] Parsed ${messages.length} messages, ${parseErrors.length} parse errors`,
  );

  // ========================================
  // 3. INIT DB CLIENT (service_role)
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ========================================
  // 4. INSERT EACH MESSAGE (idempotent upsert)
  // ========================================
  let inserted = 0;
  let skipped = 0;
  const errors: { index: number; message_id: string; error: string }[] = [];

  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];

    // Validate required fields
    if (!msg.message_id) {
      errors.push({
        index: i,
        message_id: "unknown",
        error: "missing message_id",
      });
      continue;
    }

    if (!msg.text && msg.text !== "") {
      errors.push({
        index: i,
        message_id: msg.message_id,
        error: "missing text field",
      });
      continue;
    }

    try {
      const direction = msg.direction || "inbound";
      const contactName = direction === "inbound" ? msg.from_name : msg.to_name;
      const contactPhone = direction === "inbound" ? msg.from_phone : msg.to_phone;
      // sender_user_id is NOT NULL — use from_phone, from_name, or "unknown" as fallback
      const senderUserId = direction === "inbound" ? (msg.from_phone || msg.from_name || "unknown") : ZACK_BESIDE_LINE;
      // thread_id is NOT NULL — derive from contact phone or use message_id as fallback
      const threadId = contactPhone ? `beside_sms_${contactPhone}` : `beside_sms_${msg.message_id}`;

      // Parse the Beside timestamp format: "2024-10-24 14:36:46.978847 +0000 UTC"
      const sentAt = parseBesideTimestamp(msg.created_at);

      const { error: upsertError, status } = await db
        .from("sms_messages")
        .upsert(
          {
            message_id: msg.message_id,
            thread_id: threadId,
            sent_at: sentAt,
            content: msg.text,
            direction: direction,
            contact_name: contactName || null,
            contact_phone: contactPhone || null,
            sender_inbox_id: ZACK_INBOX_ID,
            sender_user_id: senderUserId,
            ingested_at: new Date().toISOString(),
          },
          { onConflict: "message_id", ignoreDuplicates: true },
        );

      if (upsertError) {
        console.error(
          `[sms-beside-batch-ingest] Upsert failed for message_id=${msg.message_id}: ${upsertError.message}`,
        );
        errors.push({
          index: i,
          message_id: msg.message_id,
          error: upsertError.message,
        });
        continue;
      }

      // status 201 = inserted, 200/204 = conflict (already existed)
      if (status === 201) {
        inserted++;
      } else {
        skipped++;
      }
    } catch (err) {
      console.error(
        `[sms-beside-batch-ingest] Unexpected error for message_id=${msg.message_id}:`,
        err,
      );
      errors.push({
        index: i,
        message_id: msg.message_id,
        error: String(err),
      });
    }
  }

  // ========================================
  // 5. RESPONSE
  // ========================================
  const elapsed = Date.now() - t0;
  console.log(
    `[sms-beside-batch-ingest] done: inserted=${inserted} skipped=${skipped} errors=${errors.length} parse_errors=${parseErrors.length} ms=${elapsed}`,
  );

  return jsonResponse({
    ok: errors.length === 0 && parseErrors.length === 0,
    version: VERSION,
    inserted,
    skipped,
    errors: [...parseErrors.map((e) => ({ parse_error: e })), ...errors],
    ms: elapsed,
  }, 200);
});

// ============================================================
// HELPERS
// ============================================================

/**
 * Parse newline-delimited JSON into an array of BesideSmsEntry.
 * Skips blank lines. Collects parse errors without failing the batch.
 */
function parseNdjson(
  raw: string,
  parseErrors: string[],
): BesideSmsEntry[] {
  const results: BesideSmsEntry[] = [];
  const lines = raw.split("\n");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    try {
      const obj = JSON.parse(line);
      results.push(obj as BesideSmsEntry);
    } catch (err) {
      const preview = line.length > 80 ? line.slice(0, 80) + "..." : line;
      parseErrors.push(`Line ${i}: ${String(err)} — ${preview}`);
    }
  }

  return results;
}

/**
 * Parse Beside timestamp format: "2024-10-24 14:36:46.978847 +0000 UTC"
 * Falls back to ISO parse, then to current time.
 */
function parseBesideTimestamp(raw: string | undefined | null): string {
  if (!raw) return new Date().toISOString();

  // Strip trailing " UTC" if present, replace space before offset with T-style
  let cleaned = raw.trim();
  if (cleaned.endsWith(" UTC")) {
    cleaned = cleaned.slice(0, -4);
  }

  // Try direct parse (JS handles "2024-10-24 14:36:46.978847 +0000" in many engines)
  const d = new Date(cleaned);
  if (!isNaN(d.getTime())) {
    return d.toISOString();
  }

  // Fallback: try replacing space between date and time with T
  const tFormatted = cleaned.replace(
    /^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})/,
    "$1T$2",
  );
  const d2 = new Date(tFormatted);
  if (!isNaN(d2.getTime())) {
    return d2.toISOString();
  }

  console.warn(
    `[sms-beside-batch-ingest] Could not parse timestamp "${raw}", using now()`,
  );
  return new Date().toISOString();
}

function jsonResponse(
  data: Record<string, unknown>,
  status: number,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, x-source, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}
