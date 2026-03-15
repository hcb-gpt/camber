/**
 * gmail-context-lookup Edge Function v1.0.0
 *
 * Deterministic Gmail context fetch for a contact email set.
 * - 30d lookback default
 * - <= 5 Gmail API calls per run (1 list + up to 4 get)
 * - 1h DB-backed cache keyed by normalized contact email set
 * - fail-open: returns empty context on auth/API failures
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { gmailApiGetJson, resolveGmailAccessToken } from "../../../../shared/gmail.js";

const LOOKBACK_DAYS_DEFAULT = 30;
const MAX_RESULTS_DEFAULT = 5;
const CACHE_TTL_SECONDS_DEFAULT = 3600;
const MAX_GMAIL_API_CALLS = 5;
const LIST_CALLS = 1;
const MAX_GET_CALLS = Math.max(0, MAX_GMAIL_API_CALLS - LIST_CALLS);

const DEFAULT_STOPWORDS = new Set([
  "re",
  "fw",
  "fwd",
  "the",
  "and",
  "a",
  "an",
  "for",
  "to",
  "of",
  "on",
  "in",
  "at",
  "with",
  "from",
  "update",
  "call",
  "text",
]);

interface AliasRow {
  alias: string;
  project_id: string | null;
}

interface EmailContextItem {
  message_id: string;
  thread_id: string | null;
  date: string | null;
  from: string | null;
  to: string | null;
  subject: string | null;
  subject_keywords: string[];
  project_mentions: string[];
  mentioned_project_ids: string[];
  amounts_mentioned: string[];
  evidence_locator: string;
}

interface EmailLookupMeta {
  step: string;
  source: string | null;
  contact_id: string | null;
  query: string | null;
  date_range: string | null;
  results_count: number;
  returned_count: number;
  cached: boolean;
  lookup_ms: number | null;
  gmail_api_calls: number;
  auth_mode: string | null;
  warnings: string[];
  truncation: string[];
}

function safeArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : [];
}

function uniqStrings(values: unknown[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    const str = String(value || "").trim();
    if (!str) continue;
    const low = str.toLowerCase();
    if (seen.has(low)) continue;
    seen.add(low);
    out.push(str);
  }
  return out;
}

function parseDateToIso(raw: unknown): string | null {
  const parsed = Date.parse(String(raw || ""));
  if (!Number.isFinite(parsed)) return null;
  return new Date(parsed).toISOString();
}

function ymd(value: Date): string {
  const yyyy = String(value.getUTCFullYear());
  const mm = String(value.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(value.getUTCDate()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

function extractHeader(headers: unknown, name: string): string | null {
  const wanted = String(name || "").toLowerCase();
  for (const header of safeArray<Record<string, unknown>>(headers)) {
    const headerName = String(header?.name || "").toLowerCase();
    if (headerName !== wanted) continue;
    const value = String(header?.value || "").trim();
    return value || null;
  }
  return null;
}

function findMentions(
  text: string,
  aliases: AliasRow[],
): { project_mentions: string[]; mentioned_project_ids: string[] } {
  const hayLower = String(text || "").toLowerCase();
  const matches: Array<{ alias: string; project_id: string | null }> = [];
  const seen = new Set<string>();
  const isWordChar = (ch: string) => /[a-z0-9]/i.test(ch);

  for (const row of aliases) {
    const alias = String(row?.alias || "").trim();
    if (!alias) continue;
    const aliasLower = alias.toLowerCase();
    if (aliasLower.length < 3) continue;

    const idx = hayLower.indexOf(aliasLower);
    if (idx < 0) continue;

    const before = idx === 0 ? " " : hayLower[idx - 1];
    const afterIdx = idx + aliasLower.length;
    const after = afterIdx >= hayLower.length ? " " : hayLower[afterIdx];
    if (isWordChar(before) || isWordChar(after)) continue;

    const key = `${aliasLower}|${String(row?.project_id || "").toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);

    matches.push({
      alias,
      project_id: row?.project_id ? String(row.project_id) : null,
    });
  }

  return {
    project_mentions: matches.map((m) => m.alias),
    mentioned_project_ids: uniqStrings(matches.map((m) => m.project_id)).filter(Boolean),
  };
}

function extractAmounts(text: string): string[] {
  const raw = String(text || "");
  const regex = /\$(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?\s*(?:k|K)?/g;
  const matches = raw.match(regex) || [];
  return uniqStrings(matches).slice(0, 10);
}

function extractSubjectKeywords(subject: string | null, stopwords: Set<string>): string[] {
  const lower = String(subject || "").toLowerCase();
  if (!lower.trim()) return [];

  const tokens = lower
    .replace(/[^a-z0-9]+/g, " ")
    .split(/\s+/)
    .map((t) => t.trim())
    .filter(Boolean);

  const out: string[] = [];
  const seen = new Set<string>();
  for (const token of tokens) {
    if (token.length < 3) continue;
    if (stopwords.has(token)) continue;
    if (seen.has(token)) continue;
    seen.add(token);
    out.push(token);
    if (out.length >= 12) break;
  }
  return out;
}

function sanitizeEmailContext(items: EmailContextItem[]): EmailContextItem[] {
  return safeArray<EmailContextItem>(items).map((item) => ({
    message_id: String(item.message_id || ""),
    thread_id: item.thread_id ? String(item.thread_id) : null,
    date: item.date ? String(item.date) : null,
    from: item.from ? String(item.from).replace(/\s+/g, " ").trim() : null,
    to: item.to ? String(item.to).replace(/\s+/g, " ").trim() : null,
    subject: item.subject ? String(item.subject).slice(0, 240) : null,
    subject_keywords: safeArray<string>(item.subject_keywords).slice(0, 12),
    project_mentions: safeArray<string>(item.project_mentions).slice(0, 12),
    mentioned_project_ids: safeArray<string>(item.mentioned_project_ids).slice(0, 12),
    amounts_mentioned: safeArray<string>(item.amounts_mentioned).slice(0, 10),
    evidence_locator: String(item.evidence_locator || ""),
  }));
}

function parseEmailArray(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.map((v) => String(v || "").trim()).filter(Boolean);
  }
  if (typeof value === "string") {
    return value.split(/[,\n;]+/).map((v) => v.trim()).filter(Boolean);
  }
  return [];
}

function clampInteger(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const parts = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0"));
  return parts.join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

Deno.serve(async (req: Request) => {
  const startedAt = Date.now();
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const edgeSecretHeader = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  const hasValidEdgeSecret = !!(
    expectedSecret &&
    edgeSecretHeader &&
    constantTimeEqual(edgeSecretHeader, expectedSecret)
  );

  const authHeader = req.headers.get("Authorization");

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) {
    return new Response(JSON.stringify({ error: "missing_supabase_env" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const db = createClient(supabaseUrl, serviceRole);

  if (!hasValidEdgeSecret) {
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "missing_auth", hint: "X-Edge-Secret or Authorization Bearer token required" }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!anonKey) {
      return new Response(JSON.stringify({ error: "missing_anon_key" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    const anonClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await anonClient.auth.getUser();
    if (authErr || !user) {
      return new Response(JSON.stringify({ error: "invalid_token", detail: authErr?.message || null }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const allowedEmails = (Deno.env.get("ALLOWED_EMAILS") || "")
      .split(",")
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean);

    const userEmail = (user.email || "").toLowerCase();
    if (allowedEmails.length === 0) {
      return new Response(JSON.stringify({ error: "config_error", hint: "ALLOWED_EMAILS must be configured" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (!allowedEmails.includes(userEmail)) {
      return new Response(JSON.stringify({ error: "forbidden", hint: "User not authorized" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }
  }

  const warnings: string[] = [];
  const truncation: string[] = [];
  const source = typeof body.source === "string" ? body.source : null;
  const lookbackDays = clampInteger(body.lookback_days, LOOKBACK_DAYS_DEFAULT, 1, 60);
  const requestedMaxResults = clampInteger(body.max_results, MAX_RESULTS_DEFAULT, 1, 10);
  const cacheTtlSeconds = clampInteger(body.cache_ttl_seconds, CACHE_TTL_SECONDS_DEFAULT, 60, 24 * 60 * 60);
  const stopwords = new Set(DEFAULT_STOPWORDS);
  const customStopwords = parseEmailArray(body.stopwords);
  for (const token of customStopwords) stopwords.add(token.toLowerCase());

  let contactId = typeof body.contact_id === "string" ? body.contact_id : null;
  const interactionId = typeof body.interaction_id === "string" ? body.interaction_id : null;

  const meta: EmailLookupMeta = {
    step: "gmail_context_lookup",
    source,
    contact_id: contactId,
    query: null,
    date_range: null,
    results_count: 0,
    returned_count: 0,
    cached: false,
    lookup_ms: null,
    gmail_api_calls: 0,
    auth_mode: null,
    warnings,
    truncation,
  };

  if (!contactId && interactionId) {
    const { data: interactionRow } = await db
      .from("interactions")
      .select("contact_id")
      .eq("interaction_id", interactionId)
      .maybeSingle();
    if (interactionRow?.contact_id) {
      contactId = interactionRow.contact_id;
      meta.contact_id = contactId;
    }
  }

  if (!contactId) {
    warnings.push("no_contact_id");
    meta.lookup_ms = Date.now() - startedAt;
    return new Response(JSON.stringify({ ok: true, email_context: [], email_lookup_meta: meta }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  let contactRow: Record<string, unknown> | null = null;
  try {
    const selections = ["id,email,email_address,emails", "id,email,email_address", "*"];
    for (const selection of selections) {
      const { data, error } = await db
        .from("contacts")
        .select(selection)
        .eq("id", contactId)
        .maybeSingle();
      if (!error) {
        contactRow = (data as unknown as Record<string, unknown>) || null;
        break;
      }
    }
  } catch (error: unknown) {
    warnings.push(`contacts_lookup_exception:${String((error as Error)?.message || error).slice(0, 80)}`);
  }

  const emails = uniqStrings([
    contactRow?.email,
    contactRow?.email_address,
    ...parseEmailArray(contactRow?.emails),
  ])
    .map((value) => value.trim().toLowerCase())
    .filter((value) => value.includes("@"));

  if (!emails.length) {
    warnings.push("no_email_on_contact");
    meta.lookup_ms = Date.now() - startedAt;
    return new Response(JSON.stringify({ ok: true, email_context: [], email_lookup_meta: meta }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const normalizedEmailKey = emails.sort().join("|");
  const emailFingerprint = await sha256Hex(normalizedEmailKey);
  const cacheKey = `gmail_ctx:${emailFingerprint}`;
  const nowIso = new Date().toISOString();

  try {
    const { data: cachedRow, error: cacheReadErr } = await db
      .from("gmail_context_cache")
      .select("email_context,email_lookup_meta,fetched_at,expires_at")
      .eq("cache_key", cacheKey)
      .gt("expires_at", nowIso)
      .maybeSingle();

    if (!cacheReadErr && cachedRow) {
      const cachedContext = sanitizeEmailContext(safeArray<EmailContextItem>(cachedRow.email_context));
      const cachedMeta = (cachedRow.email_lookup_meta && typeof cachedRow.email_lookup_meta === "object")
        ? (cachedRow.email_lookup_meta as Record<string, unknown>)
        : {};

      meta.cached = true;
      meta.query = typeof cachedMeta.query === "string" ? cachedMeta.query : null;
      meta.date_range = typeof cachedMeta.date_range === "string" ? cachedMeta.date_range : null;
      meta.results_count = Number(cachedMeta.results_count || 0) || 0;
      meta.returned_count = cachedContext.length;
      meta.lookup_ms = Date.now() - startedAt;

      return new Response(JSON.stringify({ ok: true, email_context: cachedContext, email_lookup_meta: meta }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (cacheReadErr) {
      warnings.push(`cache_read_failed:${cacheReadErr.message.slice(0, 80)}`);
    }
  } catch (error: unknown) {
    warnings.push(`cache_read_exception:${String((error as Error)?.message || error).slice(0, 80)}`);
  }

  const access = await resolveGmailAccessToken({ env: Deno.env, warnings });
  meta.auth_mode = access.authMode;
  if (!access.token) {
    meta.lookup_ms = Date.now() - startedAt;
    return new Response(JSON.stringify({ ok: true, email_context: [], email_lookup_meta: meta }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const aliasRows: AliasRow[] = [];
  try {
    const { data, error } = await db
      .from("v_project_alias_lookup")
      .select("alias,project_id")
      .limit(2000);
    if (!error && data) {
      for (const row of safeArray<Record<string, unknown>>(data)) {
        const alias = String(row.alias || "").trim();
        if (!alias) continue;
        aliasRows.push({
          alias,
          project_id: row.project_id ? String(row.project_id) : null,
        });
      }
    } else if (error) {
      warnings.push("v_project_alias_lookup_missing");
    }
  } catch {
    warnings.push("v_project_alias_lookup_error");
  }

  const start = new Date(Date.now() - lookbackDays * 24 * 60 * 60 * 1000);
  const end = new Date();
  meta.date_range = `${ymd(start)} to ${ymd(end)}`;

  const clauses = emails.map((email) => `(from:${email} OR to:${email})`);
  const query = `${clauses.length > 1 ? `(${clauses.join(" OR ")})` : clauses[0]} newer_than:${lookbackDays}d`;
  meta.query = clauses.length > 1 ? "from:<vendor> OR to:<vendor>" : clauses[0].replace(/[()]/g, "");

  const effectiveMax = Math.min(requestedMaxResults, MAX_GET_CALLS);
  if (requestedMaxResults > effectiveMax) {
    truncation.push(`max_results_capped_by_api_budget:${requestedMaxResults}->${effectiveMax}`);
  }

  meta.gmail_api_calls += 1;
  const listResp = await gmailApiGetJson({
    token: access.token,
    path: "messages",
    params: {
      q: query,
      maxResults: effectiveMax,
      includeSpamTrash: "false",
      fields: "messages(id,threadId),resultSizeEstimate",
    },
  });

  if (!listResp.ok) {
    warnings.push(
      listResp.status > 0 ? `gmail_list_failed_http_${listResp.status}` : "gmail_list_network_error",
    );
    meta.lookup_ms = Date.now() - startedAt;
    return new Response(JSON.stringify({ ok: true, email_context: [], email_lookup_meta: meta }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const ids = safeArray<Record<string, unknown>>(listResp.json?.messages)
    .map((item) => item?.id)
    .filter(Boolean)
    .map((value) => String(value))
    .slice(0, effectiveMax);

  meta.results_count = Number(listResp.json?.resultSizeEstimate || ids.length) || ids.length;
  const emailContext: EmailContextItem[] = [];

  for (const id of ids) {
    if (meta.gmail_api_calls >= MAX_GMAIL_API_CALLS) {
      truncation.push("gmail_api_call_cap_reached");
      break;
    }

    meta.gmail_api_calls += 1;
    const msgResp = await gmailApiGetJson({
      token: access.token,
      path: `messages/${encodeURIComponent(id)}`,
      params: {
        format: "metadata",
        metadataHeaders: ["Subject", "From", "To", "Date"],
        fields: "id,threadId,internalDate,snippet,payload(headers)",
      },
    });

    if (!msgResp.ok) {
      warnings.push(
        msgResp.status > 0 ? `gmail_get_failed_http_${msgResp.status}` : "gmail_get_network_error",
      );
      continue;
    }

    const message = msgResp.json || {};
    const headers = safeArray<Record<string, unknown>>(message?.payload?.headers);

    const subject = extractHeader(headers, "Subject");
    const from = extractHeader(headers, "From");
    const to = extractHeader(headers, "To");
    const dateHeader = extractHeader(headers, "Date");

    const internalMs = message?.internalDate ? Number(message.internalDate) : null;
    const dateIso = internalMs && Number.isFinite(internalMs)
      ? new Date(internalMs).toISOString()
      : parseDateToIso(dateHeader);

    const snippetRaw = typeof message?.snippet === "string" ? message.snippet : "";
    const snippetForDerivation = snippetRaw.replace(/\s+/g, " ").trim().slice(0, 200);
    const mentionText = `${subject || ""}\n${snippetForDerivation}`.trim();
    const mentions = findMentions(mentionText, aliasRows);

    emailContext.push({
      message_id: String(message.id || id),
      thread_id: message.threadId ? String(message.threadId) : null,
      date: dateIso || null,
      from: from ? from.replace(/\s+/g, " ").trim() : null,
      to: to ? to.replace(/\s+/g, " ").trim() : null,
      subject: subject || null,
      subject_keywords: extractSubjectKeywords(subject, stopwords),
      project_mentions: mentions.project_mentions,
      mentioned_project_ids: mentions.mentioned_project_ids,
      amounts_mentioned: extractAmounts(mentionText),
      evidence_locator: message.threadId
        ? `gmail:thread/${message.threadId}#msg=${message.id || id}`
        : `gmail:msg/${id}`,
    });
  }

  const sanitizedContext = sanitizeEmailContext(emailContext);
  meta.returned_count = sanitizedContext.length;
  meta.lookup_ms = Date.now() - startedAt;

  const expiresAtIso = new Date(Date.now() + cacheTtlSeconds * 1000).toISOString();
  const cacheMeta = {
    query: meta.query,
    date_range: meta.date_range,
    results_count: meta.results_count,
    returned_count: meta.returned_count,
    gmail_api_calls: meta.gmail_api_calls,
    truncation: meta.truncation,
  };

  try {
    const { error: cacheWriteErr } = await db.from("gmail_context_cache").upsert({
      cache_key: cacheKey,
      email_fingerprint: emailFingerprint,
      email_context: sanitizedContext,
      email_lookup_meta: cacheMeta,
      fetched_at: new Date().toISOString(),
      expires_at: expiresAtIso,
      updated_at: new Date().toISOString(),
    }, { onConflict: "cache_key" });
    if (cacheWriteErr) {
      warnings.push(`cache_write_failed:${cacheWriteErr.message.slice(0, 80)}`);
    }
  } catch (error: unknown) {
    warnings.push(`cache_write_exception:${String((error as Error)?.message || error).slice(0, 80)}`);
  }

  return new Response(JSON.stringify({ ok: true, email_context: sanitizedContext, email_lookup_meta: meta }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
