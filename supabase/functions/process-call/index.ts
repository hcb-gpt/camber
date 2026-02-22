/**
 * process-call Edge Function v4.3.8
 * Full v3.6 pipeline in Supabase - Ported from v4.0.22 context_assembly
 *
 * @version 4.3.8
 * @date 2026-02-15
 * @port context_assembly v4.0.22 - 6-source ranking, word boundaries, speaker stripping
 *
 * PR-12 HARDENING:
 * - JWT + edge-secret gate
 * - project_kind='client' + status filters on all candidate sources
 * - No silent OK paths
 *
 * v4.2.0 CHANGES (attribution gap fix):
 * - Write candidate_projects to interactions
 * - (auto_assign_project RPC removed in v4.3.6 -- Stopline 1 violation)
 *
 * v4.3.2 CHANGES (lineage persistence):
 * - Persist zapier_zap_id and zapier_run_id from _zapier_ingest_meta into calls_raw.
 *
 * v4.3.8 CHANGES (segment-call runtime reliability hardening):
 * - Adds bounded timeout + transient retry for segment-call chaining.
 * - Reduces dropped attribution chains during short-lived downstream failures.
 *
 * v4.3.7 CHANGES (junk-call prefilter handoff):
 * - Adds conservative junk-call prefilter on interaction writes.
 * - Sets interactions.needs_review=false with junk_call_filtered reason when low-signal junk is detected.
 *
 * v4.3.5 CHANGES (inbound owner phone + quality warnings):
 * - Accept normalized fields (`to_phone_norm` / `from_phone_norm`) for party role mapping.
 * - Flatten nested signal payload fields for direction + phone normalization.
 * - Surface STRAT-visible warnings when direction/owner_phone are missing.
 *
 * v4.3.4 CHANGES (phone role mapping fix):
 * - Resolve owner/other-party phones by explicit fields first.
 * - Apply direction-aware fallback from from_phone/to_phone:
 *   inbound => owner=to_phone, other_party=from_phone
 *   outbound => owner=from_phone, other_party=to_phone
 *
 * v4.3.5 CHANGES (empty-transcript terminalization):
 * - Empty transcript interactions are terminalized (needs_review=false, terminal reason)
 *   instead of creating pending null-span review_queue pressure.
 * - Legacy pending null-span review_queue rows for empty transcript interactions are auto-dismissed.
 *
 * v4.3.3 CHANGES (shadow replay support):
 * - Persist `is_shadow` on calls_raw + interactions.
 * - Normalize provenance source via ALLOWED_PROVENANCE_SOURCES (includes `shadow`).
 *
 * v4.3.1 CHANGES (auth hardening):
 * - X-Edge-Secret path no longer gates on payload provenance source.
 *   If EDGE_SHARED_SECRET matches, request is authenticated.
 *
 * v4.3.0 CHANGES (pipeline chain fix):
 * - Chain to segment-call after successful ingestion (fire-and-forget)
 * - Only fires when transcript >= 10 chars and gate decision is PASS
 * - Closes the attribution gap: calls now flow through full pipeline
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { evaluateJunkCallPrefilter, normalizeDurationSeconds } from "../_shared/junk_call_prefilter.ts";
import { normalizePhoneForLookup } from "./phone_lookup.ts";
import { resolveCallPartyPhones } from "./phone_direction.ts";

const PROCESS_CALL_VERSION = "v4.3.8"; // adds bounded timeout + transient retry for segment-call chaining
const GATE = { PASS: "PASS", SKIP: "SKIP", NEEDS_REVIEW: "NEEDS_REVIEW" };
const ID_PATTERN = /^cll_[a-zA-Z0-9_]+$/;
const SEGMENT_CALL_TIMEOUT_MS = Number(Deno.env.get("PROCESS_CALL_SEGMENT_TIMEOUT_MS") || "6000");
const SEGMENT_CALL_MAX_ATTEMPTS = Math.min(
  3,
  Math.max(1, Number(Deno.env.get("PROCESS_CALL_SEGMENT_MAX_ATTEMPTS") || "2")),
);
const RETRYABLE_HTTP_STATUS = new Set([408, 429, 500, 502, 503, 504]);
const ALLOWED_PROVENANCE_SOURCES = [
  "openphone",
  "zapier",
  "admin-reseed",
  "shadow",
  "edge",
  "process-call",
  "segment-call",
];

function normalizeProvenanceSource(source: unknown): string {
  const raw = String(source || "edge").trim().toLowerCase();
  if (!raw) return "edge";
  return ALLOWED_PROVENANCE_SOURCES.includes(raw) ? raw : "edge";
}

type SegmentCallInvokeResult = {
  attempts: number;
  status: number | null;
  warnings: string[];
};

async function invokeSegmentCallWithRetry(
  url: string,
  edgeSecret: string,
  payload: Record<string, unknown>,
): Promise<SegmentCallInvokeResult> {
  const warnings: string[] = [];
  let status: number | null = null;
  let attempts = 0;

  for (let attempt = 1; attempt <= SEGMENT_CALL_MAX_ATTEMPTS; attempt++) {
    attempts = attempt;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort("segment-call-timeout"), SEGMENT_CALL_TIMEOUT_MS);

    try {
      const segResp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": edgeSecret,
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      status = segResp.status;

      if (segResp.ok) {
        clearTimeout(timeout);
        return { attempts, status, warnings };
      }

      const errBody = await segResp.text().catch(() => "unknown");
      warnings.push(`segment_call_http_${segResp.status}_attempt_${attempt}: ${errBody.slice(0, 200)}`);

      if (!RETRYABLE_HTTP_STATUS.has(segResp.status) || attempt === SEGMENT_CALL_MAX_ATTEMPTS) {
        clearTimeout(timeout);
        return { attempts, status, warnings };
      }
    } catch (e: any) {
      const msg = String(e?.message || e);
      if (msg.toLowerCase().includes("aborted")) {
        warnings.push(`segment_call_timeout_attempt_${attempt}: ${SEGMENT_CALL_TIMEOUT_MS}ms`);
      } else {
        warnings.push(`segment_call_exception_attempt_${attempt}: ${msg}`);
      }
      if (attempt === SEGMENT_CALL_MAX_ATTEMPTS) {
        clearTimeout(timeout);
        return { attempts, status, warnings };
      }
    } finally {
      clearTimeout(timeout);
    }

    await new Promise((resolve) => setTimeout(resolve, 150 * attempt));
  }

  return { attempts, status, warnings };
}

// ============================================================
// PROJECT FILTERS (PR-11/PR-12: Only client projects with valid status)
// ============================================================
const VALID_PROJECT_STATUSES = ["active", "warranty", "estimating"];
const VALID_PROJECT_KIND = "client";

// ============================================================
// ADMIN ALLOWLIST (PR-12 hardening)
// Hard-coded admin user IDs as second-layer gate
// ============================================================
const ADMIN_USER_IDS: string[] = [
  // Add Supabase auth.users.id values here
  // Example: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
];

// ============================================================
// V3 PORTED UTILITIES (from context_assembly v4.0.22)
// ============================================================

/** Strip speaker labels from transcript to avoid false alias matches
 * e.g., "Zachary Sittler:" should NOT match "Sittler" project */
function stripSpeakerLabels(text: string): string {
  return (text || "").replace(
    /(^|\n)\s*[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\s*:/g,
    "$1",
  );
}

/** Word-boundary-aware term search - scans ALL occurrences, not just first */
function findTermInText(textLower: string, termLower: string): number {
  const isWordChar = (ch: string) => /[a-z0-9]/i.test(ch);
  let startPos = 0;
  while (startPos < textLower.length) {
    const idx = textLower.indexOf(termLower, startPos);
    if (idx < 0) return -1;
    const before = idx === 0 ? " " : textLower[idx - 1];
    const afterIdx = idx + termLower.length;
    const after = afterIdx >= textLower.length ? " " : textLower[afterIdx];
    if (!isWordChar(before) && !isWordChar(after)) return idx;
    // Handle possessive 's / \u2019s — treat as valid word boundary
    if (!isWordChar(before) && (after === "'" || after === "\u2019")) {
      const nextIdx = afterIdx + 1;
      if (
        nextIdx < textLower.length &&
        textLower[nextIdx].toLowerCase() === "s"
      ) {
        const afterS = nextIdx + 1;
        if (afterS >= textLower.length || !isWordChar(textLower[afterS])) {
          return idx; // possessive — valid match
        }
      }
    }
    startPos = idx + 1;
  }
  return -1;
}

/** Normalize alias terms (dedupe, min length) */
function normalizeAliasTerms(terms: string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const t0 of terms) {
    const t = (t0 || "").trim();
    if (!t) continue;
    const low = t.toLowerCase();
    if (seen.has(low)) continue;
    if (low.length < 4) continue;
    seen.add(low);
    out.push(t);
  }
  return out;
}

// ============================================================
// PHONETIC-ADJACENT-ONLY: Match quality classification
// ============================================================
/** Classify whether an alias match is strong or weak.
 *  - "strong": exact project name, explicit address fragment, multi-word alias, last-name match
 *  - "weak": single short first-name-only token (< 6 chars) with no corroboration
 *  Rule: first-name-only phonetic = "possible" only, never auto-merge */
function classifyMatchStrength(
  term: string,
  matchType: string,
  projectName: string,
): "strong" | "weak" {
  const termLower = term.toLowerCase();
  const nameLower = projectName.toLowerCase();

  // Exact project name match is always strong
  if (termLower === nameLower || matchType === "name_match") return "strong";

  const isExplicitAddress = /\d/.test(termLower) ||
    /\b(?:st|street|ave|avenue|blvd|boulevard|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|pkwy|parkway|way)\b/
      .test(termLower);

  // Location matches are weak (city-only corroboration) unless explicitly address-like
  if (matchType === "location_match" || matchType === "city_or_location") {
    if (isExplicitAddress) return "strong";
    return "weak";
  }

  // Multi-word terms are strong (full name, addresses, etc.)
  if (term.trim().includes(" ")) return "strong";

  // Check if this is a last-name component match (strong)
  const nameParts = nameLower.split(/\s+/);
  if (nameParts.length >= 2) {
    const lastName = nameParts[nameParts.length - 1];
    if (termLower === lastName) return "strong";
  }

  // Single-word alias match >= 6 chars is strong (distinctive enough)
  if (term.length >= 6 && matchType === "alias_match") return "strong";

  // Everything else (short single-word, first-name-only, db_scan short tokens) = weak
  return "weak";
}

// ============================================================
// CANDIDATE TYPES
// ============================================================
type CandidateProject = {
  project_id: string;
  project_name: string;
  assigned: boolean;
  affinity_weight: number;
  sources: string[];
  alias_matches: { term: string; match_type: string }[];
  rank_score: number;
  weak_only: boolean; // true if ALL alias evidence is weak (first-name-only, short token)
};

// ============================================================
// ORIGINAL HELPERS
// ============================================================
function m1(raw: any) {
  const a = { ...raw };
  const signal = a.signal && typeof a.signal === "object" ? a.signal : {};
  const rawEvent = signal.raw_event && typeof signal.raw_event === "object" ? signal.raw_event : {};
  if (a.transcript_text && !a.transcript) a.transcript = a.transcript_text;
  if (signal.transcript && !a.transcript) a.transcript = signal.transcript;
  if (!a.interaction_id && a.call_id) a.interaction_id = a.call_id;
  if (!a.interaction_id && signal.interaction_id) {
    a.interaction_id = signal.interaction_id;
  }
  if (!a.direction && signal.direction) a.direction = signal.direction;
  if (!a.direction && rawEvent.direction) a.direction = rawEvent.direction;
  if (!a.from_phone_norm && signal.from_phone_norm) {
    a.from_phone_norm = signal.from_phone_norm;
  }
  if (!a.to_phone_norm && signal.to_phone_norm) {
    a.to_phone_norm = signal.to_phone_norm;
  }
  if (!a.from_phone_norm && rawEvent.from_phone_norm) {
    a.from_phone_norm = rawEvent.from_phone_norm;
  }
  if (!a.to_phone_norm && rawEvent.to_phone_norm) {
    a.to_phone_norm = rawEvent.to_phone_norm;
  }
  if (!a.from_phone && a.from_phone_norm) a.from_phone = a.from_phone_norm;
  if (!a.to_phone && a.to_phone_norm) a.to_phone = a.to_phone_norm;
  if (!a.owner_phone && signal.owner_phone_norm) {
    a.owner_phone = signal.owner_phone_norm;
  }
  if (!a.other_party_phone && signal.other_party_phone_norm) {
    a.other_party_phone = signal.other_party_phone_norm;
  }
  return a;
}

function m4(n: any) {
  const r: string[] = [];
  if (n.interaction_id && !ID_PATTERN.test(n.interaction_id)) {
    r.push("G1_ID_MALFORMED");
  }
  if ((n.transcript || "").length < 10) r.push("G4_EMPTY_TRANSCRIPT");
  if (!n.event_at_utc && !n.call_start_utc) r.push("G4_TIMESTAMP_MISSING");
  return { decision: r.length > 0 ? GATE.NEEDS_REVIEW : GATE.PASS, reasons: r };
}

function isTerminalEmptyTranscript(gateReasons: string[], transcript: string | null | undefined): boolean {
  const hasEmptyTranscriptGate = gateReasons.includes("G4_EMPTY_TRANSCRIPT");
  const transcriptLen = (transcript || "").length;
  const nonTerminalReasons = gateReasons.filter((reason) =>
    reason !== "G4_EMPTY_TRANSCRIPT" && reason !== "G4_TIMESTAMP_MISSING"
  );
  return hasEmptyTranscriptGate && transcriptLen < 10 && nonTerminalReasons.length === 0;
}

function readDurationSeconds(raw: any, normalized: any): number | null {
  const candidates = [
    normalized?.duration_seconds,
    normalized?.duration_sec,
    normalized?.call_duration_seconds,
    normalized?.call_duration_sec,
    normalized?.duration,
    normalized?.signal?.duration_seconds,
    normalized?.signal?.duration_sec,
    normalized?.signal?.raw_event?.duration_seconds,
    normalized?.signal?.raw_event?.duration_sec,
    normalized?.signal?.raw_event?.duration,
    raw?.duration_seconds,
    raw?.duration_sec,
    raw?.call_duration_seconds,
    raw?.call_duration_sec,
    raw?.duration,
    raw?.signal?.duration_seconds,
    raw?.signal?.duration_sec,
    raw?.signal?.raw_event?.duration_seconds,
    raw?.signal?.raw_event?.duration_sec,
    raw?.signal?.raw_event?.duration,
  ];
  for (const value of candidates) {
    const seconds = normalizeDurationSeconds(value);
    if (seconds != null) return seconds;
  }
  return null;
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();
  const run_id = `run_${t0}_${Math.random().toString(36).slice(2, 8)}`;

  // ============================================================
  // REQUEST VALIDATION
  // ============================================================
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  let raw: any;
  try {
    raw = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  // ============================================================
  // AUTHENTICATION GATE (PR-12 / STRAT TURN21)
  // Two-layer: JWT user auth OR X-Edge-Secret header
  // ============================================================
  const authHeader = req.headers.get("Authorization");
  const edgeSecret = req.headers.get("X-Edge-Secret");
  // Check edge secret first (for pipeline machine-to-machine calls).
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  const hasValidEdgeSecret = expectedSecret &&
    edgeSecret === expectedSecret;

  // If no valid edge secret, require JWT auth
  if (!hasValidEdgeSecret) {
    if (!authHeader) {
      return new Response(
        JSON.stringify({
          error: "missing_auth",
          hint: "Authorization: Bearer <token> or X-Edge-Secret required",
        }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    // Validate JWT
    const anonClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authErr } = await anonClient.auth.getUser();

    if (authErr || !user) {
      return new Response(
        JSON.stringify({ error: "invalid_token", hint: authErr?.message }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    const userId = user.id;
    const userEmail = user.email || "";

    // AUTHORIZATION GATE
    const allowedEmails = (Deno.env.get("ALLOWED_EMAILS") || "").split(",").map(
      (e) => e.trim().toLowerCase(),
    ).filter((e) => e.length > 0);

    const isAdmin = ADMIN_USER_IDS.length > 0 && ADMIN_USER_IDS.includes(userId);
    const isAllowedEmail = allowedEmails.length > 0 && allowedEmails.includes(userEmail.toLowerCase());

    if (ADMIN_USER_IDS.length === 0 && allowedEmails.length === 0) {
      return new Response(
        JSON.stringify({
          error: "config_error",
          hint: "Neither ADMIN_USER_IDS nor ALLOWED_EMAILS configured",
        }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    if (!isAdmin && !isAllowedEmail) {
      return new Response(
        JSON.stringify({ error: "forbidden", hint: "User not authorized" }),
        { status: 403, headers: { "Content-Type": "application/json" } },
      );
    }
  }

  // ============================================================
  // SERVICE ROLE CLIENT (for DB writes)
  // ============================================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const provenance_source = normalizeProvenanceSource(raw.source);
  const iid = raw.interaction_id || raw.call_id || `unknown_${run_id}`;
  const id_gen = !raw.interaction_id && !raw.call_id;
  const is_shadow = raw.is_shadow === true || iid.startsWith("cll_SHADOW_") || provenance_source === "shadow";

  let audit_id: number | null = null, cr_uuid: string | null = null;
  let contact_id: string | null = null, contact_name: string | null = null;
  let project_id: string | null = null, project_name: string | null = null;
  let project_source: string | null = null;
  let project_confidence: number | null = null;

  // v4.3.0: segment-call chain tracking
  let segment_call_fired = false;
  let segment_call_status: number | null = null;
  let segment_call_attempts = 0;

  // V3 ported: candidate tracking
  const candidatesById = new Map<string, {
    project_id: string;
    assigned: boolean;
    affinity_weight: number;
    sources: string[];
    alias_matches: { term: string; match_type: string }[];
  }>();
  const sources_used: string[] = [];
  const warnings: string[] = [];
  const raw_source = String(raw.source || "edge").trim().toLowerCase();
  if (raw_source && raw_source !== provenance_source) {
    warnings.push(`source_normalized:${raw_source}->${provenance_source}`);
  }
  const normalizedPreview = m1(raw);
  const previewGate = m4(normalizedPreview);
  const previewTerminalEmptyTranscript = isTerminalEmptyTranscript(
    previewGate.reasons,
    normalizedPreview.transcript,
  );

  try {
    // IDEMPOTENCY
    if (!id_gen) {
      const { error } = await db.from("idempotency_keys").insert({
        key: iid,
        interaction_id: iid,
        source: provenance_source,
        router_version: PROCESS_CALL_VERSION,
      });
      if (
        error &&
        (error.message?.includes("duplicate") ||
          error.message?.includes("23505"))
      ) {
        if (previewTerminalEmptyTranscript) {
          const { error: interactionUpdateErr } = await db
            .from("interactions")
            .update({
              needs_review: false,
              review_reasons: ["terminal_empty_transcript", ...previewGate.reasons],
              transcript_chars: normalizedPreview.transcript?.length || 0,
            })
            .eq("interaction_id", iid);
          if (interactionUpdateErr) {
            warnings.push(`duplicate_terminalize_interaction_error: ${interactionUpdateErr.message}`);
          }

          const { error: terminalizeErr } = await db
            .from("review_queue")
            .update({
              status: "dismissed",
              resolved_at: new Date().toISOString(),
              resolved_by: "process-call",
              resolution_action: "auto_dismiss",
              resolution_notes: "terminal_empty_transcript",
            })
            .eq("interaction_id", iid)
            .eq("status", "pending")
            .is("span_id", null);
          if (terminalizeErr) {
            warnings.push(`duplicate_terminalize_review_queue_error: ${terminalizeErr.message}`);
          }
        }

        await db.from("event_audit").insert({
          interaction_id: iid,
          gate_status: "SKIP",
          gate_reasons: previewTerminalEmptyTranscript
            ? ["G1_DUPLICATE_EXACT", "G4_EMPTY_TRANSCRIPT_TERMINALIZED"]
            : ["G1_DUPLICATE_EXACT"],
          source_system: `edge_${PROCESS_CALL_VERSION}`,
          source_run_id: run_id,
          pipeline_version: PROCESS_CALL_VERSION,
        });
        return new Response(
          JSON.stringify({
            ok: true,
            run_id,
            decision: "SKIP",
            reason: "duplicate",
            interaction_id: iid,
            terminalized_empty_transcript: previewTerminalEmptyTranscript,
            warnings,
            ms: Date.now() - t0,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
    }

    // AUDIT STARTED
    const { data: ad } = await db.from("event_audit").insert({
      interaction_id: iid,
      gate_status: "STARTED",
      gate_reasons: [],
      source_system: `edge_${PROCESS_CALL_VERSION}`,
      source_run_id: run_id,
      pipeline_version: PROCESS_CALL_VERSION,
      processed_by: "process-call",
      persisted_to_calls_raw: false,
      i1_phone_present: !!(
        raw.from_phone ||
        raw.to_phone ||
        raw.from_phone_norm ||
        raw.to_phone_norm ||
        raw.owner_phone ||
        raw.other_party_phone ||
        raw.contact_phone
      ),
      i2_unique_id: !id_gen,
    }).select("id").single();
    if (ad) audit_id = ad.id;

    // M1: Normalize input
    const n = normalizedPreview;
    const partyPhones = resolveCallPartyPhones(n);
    const persistedDirection = partyPhones.direction === "unknown" ? n.direction || null : partyPhones.direction;
    const lookupPhone = normalizePhoneForLookup(partyPhones.otherPartyPhone);
    if (partyPhones.direction === "unknown") {
      warnings.push("data_quality_missing_direction");
    }
    if (!partyPhones.ownerPhone) {
      warnings.push("data_quality_missing_owner_phone");
    }

    // ========================================
    // CONTACT RESOLUTION
    // ========================================
    if (lookupPhone) {
      const { data } = await db.rpc("lookup_contact_by_phone", {
        p_phone: lookupPhone,
      });
      if (data?.[0]) {
        contact_id = data[0].contact_id;
        contact_name = data[0].contact_name;
        sources_used.push("lookup_contact_by_phone");
      }
    }

    // ========================================
    // V3 PORTED: 6-SOURCE CANDIDATE COLLECTION
    // PR-12: All sources now filter by project_kind + status
    // ========================================

    // Helper to add/update candidate
    const addCandidate = (pid: string, source: string, weight = 0) => {
      if (!pid) return;
      const cur = candidatesById.get(pid) || {
        project_id: pid,
        assigned: false,
        affinity_weight: 0,
        sources: [],
        alias_matches: [],
      };
      if (!cur.sources.includes(source)) cur.sources.push(source);
      if (weight > 0) {
        cur.affinity_weight = Math.max(cur.affinity_weight, weight);
      }
      candidatesById.set(pid, cur);
    };

    // SOURCE 1: project_contacts (direct assignment)
    // PR-12: Join projects to filter by status + project_kind
    if (contact_id) {
      const { data: pcRows } = await db
        .from("project_contacts")
        .select("project_id, projects!inner(status, project_kind)")
        .eq("contact_id", contact_id)
        .in("projects.status", VALID_PROJECT_STATUSES)
        .eq("projects.project_kind", VALID_PROJECT_KIND);

      if (pcRows?.length) {
        sources_used.push("project_contacts");
        for (const r of pcRows) {
          if (r.project_id) {
            const cur = candidatesById.get(r.project_id) || {
              project_id: r.project_id,
              assigned: true,
              affinity_weight: 0,
              sources: ["project_contacts"],
              alias_matches: [],
            };
            cur.assigned = true;
            if (!cur.sources.includes("project_contacts")) {
              cur.sources.push("project_contacts");
            }
            candidatesById.set(r.project_id, cur);
          }
        }
      }
    }

    // SOURCE 2: correspondent_project_affinity (historical call frequency)
    // PR-12: Join projects to filter by status + project_kind
    if (contact_id) {
      const { data: affRows } = await db
        .from("correspondent_project_affinity")
        .select("project_id, weight, projects!inner(status, project_kind)")
        .eq("contact_id", contact_id)
        .in("projects.status", VALID_PROJECT_STATUSES)
        .eq("projects.project_kind", VALID_PROJECT_KIND);

      if (affRows?.length) {
        sources_used.push("correspondent_project_affinity");
        for (const r of affRows) {
          if (r.project_id) {
            addCandidate(
              r.project_id,
              "correspondent_project_affinity",
              r.weight || 0,
            );
          }
        }
      }
    }

    // SOURCE 3: existing_project from interactions (replay fallback)
    // PR-12: Validate project still meets filters before using
    {
      const { data: irows } = await db
        .from("interactions")
        .select("project_id")
        .eq("interaction_id", iid)
        .limit(1);

      if (irows?.[0]?.project_id) {
        // Validate existing project still qualifies
        const { data: pcheck } = await db
          .from("projects")
          .select("id")
          .eq("id", irows[0].project_id)
          .in("status", VALID_PROJECT_STATUSES)
          .eq("project_kind", VALID_PROJECT_KIND)
          .limit(1);

        if (pcheck?.length) {
          addCandidate(irows[0].project_id, "interactions_existing_project");
          sources_used.push("interactions_existing_project");
        } else {
          warnings.push("existing_project_filtered_out");
        }
      }
    }

    // SOURCE 4-6: Transcript-based sources
    if (n.transcript) {
      // Clean transcript for matching (strip speaker labels)
      const transcriptClean = stripSpeakerLabels(n.transcript);
      const transcriptLower = transcriptClean.toLowerCase();

      // PR-12: Fetch only client projects with valid status
      const { data: projects } = await db
        .from("projects")
        .select("id, name, aliases, city, address")
        .in("status", VALID_PROJECT_STATUSES)
        .eq("project_kind", VALID_PROJECT_KIND);

      const { data: aliasRows } = await db.from("v_project_alias_lookup")
        .select("project_id, alias");

      // Build alias map (only for valid projects)
      const validProjectIds = new Set((projects || []).map((p) => p.id));
      const aliasByProject = new Map<string, string[]>();
      for (const r of (aliasRows || [])) {
        if (!r.project_id || !r.alias) continue;
        if (!validProjectIds.has(r.project_id)) continue; // PR-12: Skip non-client projects
        if (!aliasByProject.has(r.project_id)) {
          aliasByProject.set(r.project_id, []);
        }
        aliasByProject.get(r.project_id)!.push(r.alias);
      }

      // SOURCE 4: Name/alias/location matches in transcript (with word boundaries)
      if (projects) {
        sources_used.push("transcript_scan");
        for (const p of projects) {
          if (!p.id || !p.name) continue;

          // Collect all searchable terms for this project
          const terms: string[] = [p.name];
          const fromAliasTable = aliasByProject.get(p.id) || [];
          terms.push(...fromAliasTable);
          if (Array.isArray(p.aliases)) terms.push(...p.aliases);
          if (p.city) terms.push(p.city);
          if (p.address) terms.push(p.address);

          const normalizedTerms = normalizeAliasTerms(terms);

          for (const term of normalizedTerms) {
            const termLower = term.toLowerCase();
            const idx = findTermInText(transcriptLower, termLower);
            if (idx >= 0) {
              // Found a match with word boundaries!
              const matchType = fromAliasTable.some((a) => a.toLowerCase() === termLower)
                ? "alias_match"
                : (p.name.toLowerCase() === termLower ? "name_match" : "location_match");

              const cur: {
                project_id: string;
                assigned: boolean;
                affinity_weight: number;
                sources: string[];
                alias_matches: { term: string; match_type: string }[];
              } = candidatesById.get(p.id) || {
                project_id: p.id,
                assigned: false,
                affinity_weight: 0,
                sources: [],
                alias_matches: [],
              };
              if (!cur.sources.includes("transcript_scan")) {
                cur.sources.push("transcript_scan");
              }
              cur.alias_matches.push({ term, match_type: matchType });
              candidatesById.set(p.id, cur);
            }
          }
        }
      }

      // SOURCE 5: Try RPC scan_transcript_for_projects (if available)
      // Note: RPC should be updated to filter by project_kind + status internally
      try {
        const { data: scanData, error: scanErr } = await db.rpc(
          "scan_transcript_for_projects",
          {
            transcript_text: n.transcript,
            similarity_threshold: 0.4,
          },
        );

        if (!scanErr && scanData?.length) {
          sources_used.push("rpc_scan_transcript_for_projects");
          for (const r of scanData) {
            const pid = r.project_id || r.projectId;
            if (pid && validProjectIds.has(pid)) { // PR-12: Filter
              const score = Number(r.score || r.similarity || 0) || 0;
              addCandidate(pid, "rpc_scan_transcript_for_projects", score);

              // Add as alias match evidence
              const cur = candidatesById.get(pid);
              if (cur && r.matched_term) {
                cur.alias_matches.push({
                  term: r.matched_term,
                  match_type: "db_scan",
                });
              }
            }
          }
        }
      } catch { /* RPC may not exist, ignore */ }

      // SOURCE 6: Try RPC expand_candidates_from_mentions (non-floater contacts)
      // Note: RPC should be updated to filter by project_kind + status internally
      try {
        const { data: mentionData, error: mentionErr } = await db.rpc(
          "expand_candidates_from_mentions",
          {
            transcript_text: n.transcript,
          },
        );

        if (!mentionErr && mentionData?.length) {
          sources_used.push("rpc_expand_candidates_from_mentions");
          for (const r of mentionData) {
            const pid = r.project_id || r.projectId;
            if (pid && validProjectIds.has(pid)) { // PR-12: Filter
              const affinity = Number(r.contact_affinity || r.affinity || 0.9) || 0.9;
              addCandidate(pid, "mentioned_contact_affinity", affinity);

              // Add as alias match evidence
              const cur = candidatesById.get(pid);
              if (cur && r.mentioned_contact) {
                cur.alias_matches.push({
                  term: r.mentioned_contact,
                  match_type: "mentioned_contact_affinity",
                });
              }
            }
          }
        }
      } catch { /* RPC may not exist, ignore */ }
    }

    // ========================================
    // V3 PORTED: RANKING FORMULA
    // ========================================
    // Fetch project names for candidates (already filtered, just need names)
    const candidateIds = Array.from(candidatesById.keys());
    const projectNameById = new Map<string, string>();

    if (candidateIds.length) {
      const { data: prows } = await db
        .from("projects")
        .select("id, name")
        .in("id", candidateIds);

      if (prows) {
        for (const p of prows) {
          if (p.id && p.name) projectNameById.set(p.id, p.name);
        }
      }
    }

    // Calculate rank scores and sort
    const rankedCandidates: CandidateProject[] = [];

    for (const [pid, meta] of candidatesById) {
      const pName = projectNameById.get(pid) || pid;
      const isExistingProject = meta.sources.includes(
        "interactions_existing_project",
      );
      const hasMentionedContact = meta.sources.includes(
        "mentioned_contact_affinity",
      );
      const hasAliasEvidence = meta.alias_matches.length > 0;

      // PHONETIC-ADJACENT-ONLY: Classify each alias match
      const hasStrongMatch = meta.alias_matches.some(
        (m) => classifyMatchStrength(m.term, m.match_type, pName) === "strong",
      );
      const weakOnly = hasAliasEvidence && !hasStrongMatch && !meta.assigned;

      // V3 ranking formula (from context_assembly v4.0.22)
      // - assigned via project_contacts: +100
      // - existing_project with evidence: +80, without evidence: +20
      // - mentioned non-floater contact: +40
      // - affinity weight: +min(weight*10, 50)
      // - alias/name matches: +min(count*20, 60)
      //   PHONETIC-ADJACENT-ONLY: weak-only matches capped at +10 per match (was +20)
      const aliasScore = weakOnly
        ? Math.min(meta.alias_matches.length * 10, 30) // Weak: capped lower
        : Math.min(meta.alias_matches.length * 20, 60); // Strong: original

      const rank_score = (meta.assigned ? 100 : 0) +
        (isExistingProject ? (hasAliasEvidence ? 80 : 20) : 0) +
        (hasMentionedContact ? 40 : 0) +
        Math.min(Math.max(meta.affinity_weight * 10, 0), 50) +
        aliasScore;

      rankedCandidates.push({
        project_id: pid,
        project_name: pName,
        assigned: meta.assigned,
        affinity_weight: meta.affinity_weight,
        sources: meta.sources,
        alias_matches: meta.alias_matches,
        rank_score,
        weak_only: weakOnly,
      });
    }

    // Sort: assigned first, then by alias matches, then affinity, then rank_score
    rankedCandidates.sort((a, b) => {
      if (a.assigned !== b.assigned) {
        return (b.assigned ? 1 : 0) - (a.assigned ? 1 : 0);
      }
      if (b.alias_matches.length !== a.alias_matches.length) {
        return b.alias_matches.length - a.alias_matches.length;
      }
      if (b.affinity_weight !== a.affinity_weight) {
        return b.affinity_weight - a.affinity_weight;
      }
      return b.rank_score - a.rank_score;
    });

    // ========================================
    // SELECT WINNER (for candidates, NOT for direct assignment)
    // PHONETIC-ADJACENT-ONLY: weak-only winners get capped confidence
    // ========================================
    if (rankedCandidates.length > 0) {
      const winner = rankedCandidates[0];
      project_id = winner.project_id;
      project_name = winner.project_name;
      project_source = winner.sources.join("+");

      // Confidence based on evidence strength
      const maxScore = 100 + 80 + 40 + 50 + 60; // 330 theoretical max
      project_confidence = Math.min(winner.rank_score / maxScore, 0.99);

      // Boost confidence if multiple sources agree
      if (winner.sources.length >= 3) {
        project_confidence = Math.min(project_confidence + 0.1, 0.99);
      }
      if (winner.alias_matches.length >= 2) {
        project_confidence = Math.min(project_confidence + 0.05, 0.99);
      }

      // PHONETIC-ADJACENT-ONLY: Cap confidence for weak-only winners
      // First-name-only or short-token-only matches = "possible", never high confidence
      if (winner.weak_only) {
        project_confidence = Math.min(project_confidence, 0.35);
        warnings.push("weak_alias_evidence_only");
        project_source = project_source + "+weak_only";
      }
    }

    // GATE
    const g = previewGate;
    const terminalEmptyTranscript = isTerminalEmptyTranscript(g.reasons, n.transcript);
    const junkFilter = evaluateJunkCallPrefilter({
      transcript: n.transcript || "",
      durationSeconds: readDurationSeconds(raw, n),
    });
    const junkCallFiltered = !terminalEmptyTranscript && g.decision === "PASS" && junkFilter.isJunk;
    if (junkCallFiltered) {
      warnings.push(`junk_call_filtered:${junkFilter.signalSummary.join(",")}`);
    }

    // CALLS_RAW (primary storage - includes candidate info)
    const { data: cr } = await db.from("calls_raw").upsert({
      interaction_id: iid,
      channel: "call",
      direction: persistedDirection,
      owner_phone: partyPhones.ownerPhone,
      other_party_phone: partyPhones.otherPartyPhone,
      event_at_utc: n.event_at_utc || null,
      transcript: n.transcript || null,
      recording_url: n.recording_url || n.beside_note_url || null,
      pipeline_version: PROCESS_CALL_VERSION,
      is_shadow,
      zapier_zap_id: raw._zapier_ingest_meta?.zap_id || null,
      zapier_run_id: raw._zapier_ingest_meta?.run_id || null,
      raw_snapshot_json: {
        run_id,
        v: PROCESS_CALL_VERSION,
        source: provenance_source,
        is_shadow,
        gate: g.decision,
        contact_id,
        // PR-12: Store candidate info but DO NOT assign to interactions.project_id
        candidate_project_id: project_id,
        candidate_project_source: project_source,
        candidate_project_confidence: project_confidence,
        candidate_count: rankedCandidates.length,
        top_candidates: rankedCandidates.slice(0, 5).map((c) => ({
          id: c.project_id,
          name: c.project_name,
          score: c.rank_score,
          sources: c.sources,
          matches: c.alias_matches.length,
          weak_only: c.weak_only,
        })),
        sources_used,
        warnings,
      },
    }, { onConflict: "interaction_id" }).select("id").single();
    if (cr) cr_uuid = cr.id;

    // ========================================
    // v4.2.0: Build candidate_projects JSON for interactions
    // ========================================
    const candidateProjectsJson = rankedCandidates.slice(0, 5).map((c) => ({
      id: c.project_id,
      name: c.project_name,
      score: c.rank_score,
      confidence: c.rank_score / (100 + 80 + 40 + 50 + 60),
      sources: c.sources,
      matches: c.alias_matches.length,
      weak_only: c.weak_only,
    }));

    // ========================================
    // INTERACTIONS
    // v4.2.0: Write candidate_projects for downstream pipeline visibility
    // ========================================
    if (g.decision === "PASS" || g.decision === "NEEDS_REVIEW") {
      const interactionNeedsReview = terminalEmptyTranscript || junkCallFiltered ? false : true;
      const interactionReviewReasons = terminalEmptyTranscript
        ? ["terminal_empty_transcript", ...g.reasons]
        : junkCallFiltered
        ? Array.from(new Set([...g.reasons, ...junkFilter.reasonCodes]))
        : [...g.reasons, "ai_candidate_only"];
      const { error: interactionsErr } = await db.from("interactions").upsert({
        interaction_id: iid,
        channel: "call",
        contact_id: contact_id || null,
        contact_name: contact_name || null,
        contact_phone: partyPhones.otherPartyPhone,
        owner_phone: partyPhones.ownerPhone,
        candidate_projects: candidateProjectsJson.length > 0 ? candidateProjectsJson : null,
        event_at_utc: n.event_at_utc || null,
        needs_review: interactionNeedsReview,
        review_reasons: interactionReviewReasons,
        project_attribution_confidence: project_confidence,
        transcript_chars: n.transcript?.length || 0,
        is_shadow,
      }, { onConflict: "interaction_id" });

      // Stopline 3: Fail closed on required writes — interactions row is a
      // prerequisite for context-assembly contact resolution.
      if (interactionsErr) {
        console.error(JSON.stringify({
          error: "interactions_write_failed",
          interaction_id: iid,
          run_id,
          version: PROCESS_CALL_VERSION,
          detail: interactionsErr.message,
          code: interactionsErr.code,
        }));
        if (audit_id) {
          await db.from("event_audit").update({
            gate_status: "ERROR",
            gate_reasons: ["interactions_write_failed", interactionsErr.message],
          }).eq("id", audit_id);
        }
        return new Response(
          JSON.stringify({
            ok: false,
            run_id,
            version: PROCESS_CALL_VERSION,
            interaction_id: iid,
            error_code: "interactions_write_failed",
            error: interactionsErr.message,
            ms: Date.now() - t0,
          }),
          { status: 500, headers: { "Content-Type": "application/json" } },
        );
      }

      if (terminalEmptyTranscript) {
        // Terminalize legacy null-span pending rows for this interaction.
        const { error: terminalizeErr } = await db
          .from("review_queue")
          .update({
            status: "dismissed",
            resolved_at: new Date().toISOString(),
            resolved_by: "process-call",
            resolution_action: "auto_dismiss",
            resolution_notes: "terminal_empty_transcript",
          })
          .eq("interaction_id", iid)
          .eq("status", "pending")
          .is("span_id", null);
        if (terminalizeErr) {
          warnings.push(`terminalize_empty_transcript_review_queue_error: ${terminalizeErr.message}`);
        }
      }

      // ========================================
      // v4.2.0 AUTO-ASSIGN PROJECT -- REMOVED in v4.3.6 (Stopline 1 violation)
      // auto_assign_project wrote to interactions.project_id, which is not AI truth.
      // SSOT for routing output is span_attributions; ai-router handles attribution.
      // ========================================

      // ========================================
      // v4.3.0: CHAIN TO SEGMENT-CALL
      // Fire segment-call for full attribution pipeline:
      //   segment-call → segment-llm → context-assembly → ai-router → span_attributions
      // Only when we have a real transcript (>= 10 chars) and gate PASS.
      // Fire-and-forget: segment-call failures do NOT block process-call response.
      // ========================================
      const transcriptLen = n.transcript?.length || 0;
      if (!terminalEmptyTranscript && g.decision === "PASS" && transcriptLen >= 10) {
        const edgeSecretVal = Deno.env.get("EDGE_SHARED_SECRET");
        const segmentCallUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/segment-call`;
        if (edgeSecretVal) {
          try {
            const segInvoke = await invokeSegmentCallWithRetry(
              segmentCallUrl,
              edgeSecretVal,
              {
                interaction_id: iid,
                transcript: n.transcript,
                source: "process-call",
              },
            );
            segment_call_fired = true;
            segment_call_status = segInvoke.status;
            segment_call_attempts = segInvoke.attempts;
            warnings.push(...segInvoke.warnings);
          } catch (e: any) {
            segment_call_fired = true;
            warnings.push(`segment_call_exception: ${e.message}`);
          }
        } else {
          warnings.push("segment_call_skipped: EDGE_SHARED_SECRET not set");
        }
      }
    }

    // CONTACT STATS (optional, ignore errors)
    if (contact_id) {
      try {
        await db.rpc("update_contact_interaction_stats", {
          p_contact_id: contact_id,
        });
      } catch { /* ignore */ }
    }

    // AUDIT FINAL
    if (audit_id) {
      await db.from("event_audit").update({
        gate_status: g.decision,
        gate_reasons: g.reasons,
        persisted_to_calls_raw: !!cr_uuid,
        calls_raw_uuid: cr_uuid,
      }).eq("id", audit_id);
    }

    // RUNTIME LINEAGE EVIDENCE (fire-and-forget)
    // Emits edges for operations that actually executed this invocation.
    // DB trigger upserts system_lineage_edges (last_seen_at_utc, seen_count).
    try {
      const lineageEdges: { from: string; to: string; type: string }[] = [
        { from: "edge:process-call", to: "table:public.calls_raw", type: "writes" },
        { from: "edge:process-call", to: "table:public.interactions", type: "writes" },
        { from: "edge:process-call", to: "table:public.event_audit", type: "writes" },
        { from: "edge:process-call", to: "table:public.idempotency_keys", type: "writes" },
        { from: "edge:process-call", to: "table:public.project_contacts", type: "reads" },
        { from: "edge:process-call", to: "table:public.projects", type: "reads" },
        { from: "edge:process-call", to: "table:public.correspondent_project_affinity", type: "reads" },
      ];
      if (terminalEmptyTranscript) {
        lineageEdges.push({ from: "edge:process-call", to: "table:public.review_queue", type: "writes" });
      }
      if (segment_call_fired) {
        lineageEdges.push({ from: "edge:process-call", to: "edge:segment-call", type: "calls" });
      }
      const { error: lineageErr } = await db.from("evidence_events").insert({
        source_type: "lineage",
        source_id: iid,
        source_run_id: run_id,
        transcript_variant: `process-call_${run_id}`,
        metadata: { edges: lineageEdges, pipeline_version: PROCESS_CALL_VERSION },
      });
      if (lineageErr) warnings.push(`lineage_emit: ${lineageErr.message}`);
    } catch { /* lineage emission must never block the response */ }

    return new Response(
      JSON.stringify({
        ok: true,
        run_id,
        version: PROCESS_CALL_VERSION,
        interaction_id: iid,
        decision: g.decision,
        reasons: g.reasons,
        contact_id,
        contact_name,
        candidate_project_id: project_id,
        candidate_project_name: project_name,
        candidate_project_source: project_source,
        candidate_project_confidence: project_confidence,
        candidate_count: rankedCandidates.length,
        top_candidates: rankedCandidates.slice(0, 3).map((c) => ({
          id: c.project_id,
          name: c.project_name,
          score: c.rank_score,
        })),
        // v4.2.0: auto-assign removed (Stopline 1); field kept null for backward compat
        auto_assign: null,
        // v4.3.0: segment-call chain
        segment_call: {
          fired: segment_call_fired,
          status: segment_call_status,
          attempts: segment_call_attempts,
        },
        junk_prefilter: {
          applied: junkCallFiltered,
          reason_codes: junkFilter.reasonCodes,
          signal_summary: junkFilter.signalSummary,
        },
        sources_used,
        warnings,
        audit_id,
        cr_uuid,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e: any) {
    // PR-12: No silent OK - errors return 500
    if (audit_id) {
      await db.from("event_audit").update({
        gate_status: "ERROR",
        gate_reasons: [e.message || "unknown"],
      }).eq("id", audit_id);
    }
    return new Response(
      JSON.stringify({
        ok: false,
        run_id,
        version: PROCESS_CALL_VERSION,
        interaction_id: iid,
        error: e.message,
        ms: Date.now() - t0,
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
