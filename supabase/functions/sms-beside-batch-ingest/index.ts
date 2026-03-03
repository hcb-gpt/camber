/**
 * sms-beside-batch-ingest Edge Function v1.3.1
 * Zapier SMS batch webhook receiver for Beside VoIP SMS messages
 *
 * @version 1.3.1
 * @date 2026-03-03
 * @purpose Receive batched SMS messages from Zapier Digest, insert into sms_messages table.
 *          The existing bridge_sms_message_to_surfaces trigger (v2) handles downstream
 *          writes to calls_raw and interactions with contact resolution.
 *
 * @changelog v1.3.1
 *   - Add auth compatibility window for Zapier secret/header drift:
 *     accepts X-Secret with current EDGE_SHARED_SECRET and legacy/previous
 *     secret candidates while preserving source allowlist.
 * @changelog v1.3.0
 *   - Implement zapier-shadow events write to public.beside_thread_events and beside_threads
 *     to support Beside parity metrics.
 *   - Includes computeBodyHash() with normalization matching SQL packet spec.
 *   - Added retryable shadow write block.
 * @changelog v1.1.0
 *   - Added resolveContactFields() with 4 misattribution guards:
 *     Guard 1: from_phone matches OWNER_PHONES → suppress, senderUserId="unknown"
 *     Guard 2: from_phone empty + from_name in ADMIN_NAMES → suppress, senderUserId="unknown"
 *     Guard 3: (outbound) to_phone empty + to_name in ADMIN_NAMES → suppress
 *     Guard 4: thread_id uses stable per-phone key; orphans get nomatch prefix
 *   - Fixes Beside ~2.6% bug: from_name="Chad Barlow", from_phone="" on inbound
 *   - Fixes senderUserId incorrectly becoming "Chad Barlow" instead of "unknown"
 *   - Downstream trigger Guard 2 (sender_user_id='unknown' check) now fires correctly
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
  // Beside native IDs — optional, populated when Zapier exposes them.
  // Used as fallback resolution when contact_phone is NULL.
  contact_id?: string;
  conversation_id?: string;
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

const VERSION = "sms-beside-batch-ingest_v1.3.1";
const ALLOWED_SOURCES = ["zapier", "test", "edge"];
const ZACK_INBOX_ID = "ibx_QT0G91CPXD7N1090RC2FQ1WXJ8";
const ZACK_BESIDE_LINE = "+17066889158";

// -----------------------------------------------------------------------
// MISATTRIBUTION GUARD CONSTANTS
//
// Beside bug (~2.6%): inbound messages on the shared inbox return
// from_name="Chad Barlow" and from_phone="" — the inbox admin who never
// texts. The real user is Zack Sittler, but we can't know who the actual
// sender is without more context, so we suppress rather than guess.
//
// OWNER_PHONES: The shared company line(s). When from_phone matches one
//   of these on an inbound message, the SENDER is on the shared line
//   (i.e. the Beside API confused the inbox owner with the caller) —
//   treat it as unresolvable.
//
// ADMIN_NAMES: Known inbox admin display names that Beside incorrectly
//   injects when it cannot resolve the real sender. These names should
//   NEVER appear as contact_name on inbound messages with no phone.
// -----------------------------------------------------------------------
const OWNER_PHONES = new Set([ZACK_BESIDE_LINE]);

const ADMIN_NAMES = new Set([
  "chad barlow", // Beside inbox admin — never a real SMS contact
]);

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

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
    // Compatibility window:
    // - accept legacy Zapier secret in X-Secret or X-Edge-Secret
    // - optionally accept previous rotated edge secret if configured
    // This keeps source allowlisting in place and avoids broad auth relaxation.
    const source = (req.headers.get("X-Source") || req.headers.get("source") || "").trim();
    const sourceAllowed = source.length > 0 && ALLOWED_SOURCES.includes(source);
    const incomingXEdgeSecret = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret") || "";
    const incomingXSecret = req.headers.get("X-Secret") || req.headers.get("x-secret") || "";
    const currentEdgeSecret = (Deno.env.get("EDGE_SHARED_SECRET") || "").trim();
    const legacyCandidates = [
      (Deno.env.get("ZAPIER_INGEST_SECRET") || "").trim(),
      (Deno.env.get("ZAPIER_SECRET") || "").trim(),
      (Deno.env.get("EDGE_SHARED_SECRET_PREVIOUS") || "").trim(),
    ].filter((s) => s.length > 0);

    const matchesCandidate = (candidate: string): boolean => {
      return (
        (incomingXEdgeSecret.length > 0 && constantTimeEqual(incomingXEdgeSecret, candidate)) ||
        (incomingXSecret.length > 0 && constantTimeEqual(incomingXSecret, candidate))
      );
    };

    const compatAccepted = sourceAllowed && (
      // Header-contract mismatch: Zapier still sending X-Secret with current edge secret.
      (currentEdgeSecret.length > 0 &&
        incomingXSecret.length > 0 &&
        constantTimeEqual(incomingXSecret, currentEdgeSecret)) ||
      // Legacy/previous secret compatibility window.
      legacyCandidates.some(matchesCandidate)
    );

    if (!compatAccepted) {
      return authErrorResponse(authResult.error_code!);
    }

    console.warn(
      `[sms-beside-batch-ingest] AUTH_COMPAT_ACCEPT source=${source} x_edge_secret_len=${incomingXEdgeSecret.length} x_secret_len=${incomingXSecret.length}`,
    );
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
    // Format B: messages array (of objects or of JSON strings)
    if (Array.isArray(body.messages) && body.messages.length > 0) {
      // Zapier list might be strings — parse each if needed
      messages = body.messages.map((item: unknown) => {
        if (typeof item === "string") {
          try {
            return JSON.parse(item);
          } catch {
            parseErrors.push(`messages[] string parse failed: ${String(item).slice(0, 80)}`);
            return null;
          }
        }
        return item;
      }).filter(Boolean) as BesideSmsEntry[];
    } // Format A: digest_raw string (newline-delimited JSON)
    else if (typeof body.digest_raw === "string" && body.digest_raw.length > 0) {
      messages = parseNdjson(body.digest_raw, parseErrors);
    } // Format A fallback: digest_raw as array (Zapier sometimes does this)
    else if (Array.isArray(body.digest_raw)) {
      messages = (body.digest_raw as unknown[]).map((item: unknown) => {
        if (typeof item === "string") {
          try {
            return JSON.parse(item);
          } catch {
            parseErrors.push(`digest_raw[] string parse failed: ${String(item).slice(0, 80)}`);
            return null;
          }
        }
        return item;
      }).filter(Boolean) as BesideSmsEntry[];
    } else {
      return jsonResponse({
        ok: false,
        error: "NO_MESSAGES",
        detail: "Payload must include 'messages' array or 'digest_raw' string",
        body_preview: rawBody.slice(0, 500),
        body_keys: Object.keys(body),
        messages_type: typeof body.messages,
        digest_raw_type: typeof body.digest_raw,
      }, 400);
    }
  }

  if (messages.length === 0 && parseErrors.length > 0) {
    return jsonResponse({
      ok: false,
      error: "ALL_PARSE_FAILED",
      detail: `All ${parseErrors.length} message(s) failed to parse`,
      parse_errors: parseErrors,
      body_preview: rawBody.slice(0, 500),
      body_type: body ? typeof body : "json_parse_failed",
      body_keys: body ? Object.keys(body) : [],
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

      // Resolve contact fields with misattribution guards.
      // This replaces the previous inline derivation and handles:
      //   - Beside admin-name bug (from_name="Chad Barlow", from_phone="")
      //   - Owner phone on inbound (from_phone = shared company line)
      //   - Outbound recipient missing (to_name="Chad Barlow", to_phone="")
      //   - Thread ID stability (per-phone rather than per-message)
      const {
        contactName,
        contactPhone,
        senderUserId,
        threadId,
        warnings: contactWarnings,
      } = resolveContactFields(msg);

      if (contactWarnings.length > 0) {
        console.warn(
          `[sms-beside-batch-ingest] misattribution guard triggered for message_id=${msg.message_id}: ${
            contactWarnings.join("; ")
          }`,
        );
      }

      // Parse the Beside timestamp format: "2024-10-24 14:36:46.978847 +0000 UTC"
      const sentAt = parseBesideTimestamp(msg.created_at);

      // Normalize Beside native IDs: treat empty strings as null
      const besideContactId = (msg.contact_id || "").trim() || null;
      const besideConversationId = (msg.conversation_id || "").trim() || null;

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
            beside_contact_id: besideContactId,
            beside_conversation_id: besideConversationId,
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

      // ========================================
      // SHADOW WRITE — Beside Parity Metrics
      // ========================================
      try {
        const bodyHash = await computeBodyHash(msg.text);
        const capturedAt = new Date().toISOString();

        // 1. Ensure thread exists (UPSERT into beside_threads)
        // Note: threadId comes from resolveContactFields and uses beside_sms_ prefix
        await db.from("beside_threads").upsert({
          beside_room_id: threadId,
          source: "zapier",
          contact_phone_e164: contactPhone,
          updated_at_utc: sentAt,
          captured_at_utc: capturedAt,
          payload_json: { notes: "Auto-created via zapier shadow ingest" },
        }, { onConflict: "beside_room_id" });

        // 2. Insert event (UPSERT into beside_thread_events)
        await db.from("beside_thread_events").upsert({
          beside_event_id: `zapier_${msg.message_id}`,
          beside_room_id: threadId,
          beside_event_type: "message",
          occurred_at_utc: sentAt,
          direction: direction,
          text: msg.text,
          contact_phone_e164: contactPhone,
          zapier_event_id: msg.message_id,
          source: "zapier",
          captured_at_utc: capturedAt,
          record_hash: bodyHash,
          payload_json: msg,
        }, { onConflict: "beside_event_id" });
      } catch (shadowError) {
        // Shadow write failure is non-blocking but should be logged
        const shadowErrorMessage = shadowError instanceof Error ? shadowError.message : String(shadowError);
        console.warn(
          `[sms-beside-batch-ingest] Shadow write failed for message_id=${msg.message_id}: ${shadowErrorMessage}`,
        );
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
 * Resolve contact_name, contact_phone, sender_user_id, and thread_id from
 * a raw BesideSmsEntry, guarding against the Beside admin-name misattribution
 * bug (~2.6% of inbound messages on the shared inbox line).
 *
 * Rules applied in order:
 *
 *  INBOUND:
 *   1. Owner-phone guard: if from_phone is a known company line, Beside has
 *      confused the inbox owner with the external sender. Suppress both name
 *      and phone; write sender_user_id = "unknown".
 *   2. Admin-name guard: if from_phone is empty AND from_name matches a known
 *      admin name (case-insensitive), Beside has injected the admin as the
 *      sender. Suppress the name; write sender_user_id = "unknown".
 *   3. Normal inbound: use from_phone (preferred) or from_name for identity.
 *
 *  OUTBOUND:
 *   4. Admin-name guard: if to_phone is empty AND to_name matches a known
 *      admin name, Beside could not resolve the recipient. Suppress.
 *   5. Normal outbound: contact is the recipient (to_name / to_phone).
 *
 *  THREAD ID (applied after contact resolution):
 *   6. If contactPhone is available and NOT an owner phone: stable hash on
 *      the phone number. This groups all messages with the same counterparty
 *      into one thread regardless of per-message variability.
 *   7. If contactPhone is null/empty (unresolvable sender): fall back to
 *      beside_sms_nomatch_<message_id> to make clear this is an orphan.
 *      Using message_id avoids grouping unrelated orphaned messages together.
 *
 * @returns { contactName, contactPhone, senderUserId, threadId, warnings }
 */
function resolveContactFields(msg: BesideSmsEntry): {
  contactName: string | null;
  contactPhone: string | null;
  senderUserId: string;
  threadId: string;
  warnings: string[];
} {
  const warnings: string[] = [];
  const direction = msg.direction || "inbound";

  let contactName: string | null = null;
  let contactPhone: string | null = null;
  let senderUserId: string;

  if (direction === "inbound") {
    const rawPhone = (msg.from_phone || "").trim();
    const rawName = (msg.from_name || "").trim();

    // Guard 1: from_phone is a known owner/company line.
    // Beside confused the inbox owner with the external sender.
    if (rawPhone && OWNER_PHONES.has(rawPhone)) {
      warnings.push(
        `beside_owner_phone_on_inbound: from_phone=${rawPhone} matches owner line; suppressing contact identity`,
      );
      contactName = null;
      contactPhone = null;
      senderUserId = "unknown";
    } // Guard 2: from_phone empty AND from_name is a known admin name.
    // Beside injected the inbox admin name instead of the real sender.
    else if (!rawPhone && rawName && ADMIN_NAMES.has(rawName.toLowerCase())) {
      warnings.push(
        `beside_admin_name_misattribution: from_name="${rawName}" is a known admin name with no phone; suppressing`,
      );
      contactName = null;
      contactPhone = null;
      senderUserId = "unknown";
    } // Normal inbound: trust what Beside gave us.
    else {
      contactName = rawName || null;
      contactPhone = rawPhone || null;
      // Prefer phone as stable identity; fall back to name; last resort: "unknown"
      senderUserId = rawPhone || rawName || "unknown";
    }
  } else {
    // Outbound: contact is the RECIPIENT
    const rawPhone = (msg.to_phone || "").trim();
    const rawName = (msg.to_name || "").trim();

    // Guard 4: to_phone empty AND to_name is a known admin name.
    // Beside could not resolve the recipient and injected the admin name.
    if (!rawPhone && rawName && ADMIN_NAMES.has(rawName.toLowerCase())) {
      warnings.push(
        `beside_admin_name_on_outbound: to_name="${rawName}" is a known admin name with no phone; suppressing`,
      );
      contactName = null;
      contactPhone = null;
    } else {
      contactName = rawName || null;
      contactPhone = rawPhone || null;
    }

    // For outbound, our side is always Zack's line
    senderUserId = ZACK_BESIDE_LINE;
  }

  // Thread ID derivation
  // Use a stable per-counterparty key when we have a real external phone.
  // Owner phones cannot serve as a thread key (they represent the inbox, not
  // the remote party), so they fall through to the orphan bucket.
  let threadId: string;
  if (contactPhone && !OWNER_PHONES.has(contactPhone)) {
    threadId = `beside_sms_${contactPhone}`;
  } else {
    // No resolvable counterparty phone — use message_id as an orphan marker.
    // Prefix makes orphans queryable without joining on message_id.
    threadId = `beside_sms_nomatch_${msg.message_id}`;
    if (!warnings.some((w) => w.startsWith("beside_"))) {
      // Only add this warning if we haven't already explained why phone is null
      warnings.push(`thread_fallback_to_message_id: no resolvable contact_phone`);
    }
  }

  return { contactName, contactPhone, senderUserId, threadId, warnings };
}

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

/**
 * Compute sha256 hex hash of normalized text for parity comparison.
 * Mirrors SQL normalization in v_beside_direct_read_parity_72h:
 *   lower(regexp_replace(regexp_replace(trim(text), '\\s+', ' ', 'g'), '[^[:alnum:][:space:]]+', '', 'g'))
 */
async function computeBodyHash(text: string | null): Promise<string> {
  if (!text) return "";
  const normalized = text
    .trim()
    .replace(/\s+/g, " ")
    .replace(/[^a-zA-Z0-9\s]/g, "")
    .toLowerCase();

  const msgUint8 = new TextEncoder().encode(normalized);
  const hashBuffer = await crypto.subtle.digest("SHA-256", msgUint8);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const hashHex = hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
  return hashHex;
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
