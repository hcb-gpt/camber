import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { gmailApiGetJson, resolveGmailAccessToken } from "../_shared/gmail.ts";
import {
  type AliasRow,
  decodeGmailMessageText,
  extractHeader,
  extractReceiptRecord,
  findProjectMatch,
  normalizeVendorName,
} from "./extraction.ts";
import {
  addProfileHit,
  applyTargetAffinity,
  buildProfileGmailQuery,
  type GmailQueryProfile,
  type ListedCandidateMessage,
  matchTargetsToMessage,
  mergeVendorHints,
  type SearchTarget,
  summarizeProfiles,
  summarizeRetrievalCounts,
  summarizeTargets,
} from "./search.ts";
import { classifyCandidate, createClassifierMetrics, type GmailFinanceClassification } from "./classification.ts";
import {
  buildInternalPatterns,
  buildInternalVendorNormals,
  buildRejectSet,
  buildVendorHintList,
  canonicalizeVendorDisplay,
  flagUnknownVendor,
  loadVendorRegistry,
  lookupVendor,
  type VendorRegistryRow,
} from "./vendor_registry.ts";
import { autoPromoteByVendorRegistry } from "./review_resolution.ts";

const FUNCTION_SLUG = "gmail-financial-pipeline";
const FUNCTION_VERSION = "v1.0.0";
const JSON_HEADERS = { "Content-Type": "application/json" };
const DEFAULT_BOOTSTRAP_LOOKBACK_DAYS = 7;
const DEFAULT_CANDIDATE_LIMIT = 100;
const DEFAULT_MAX_TARGETS = 40;
const DEFAULT_OVERLAP_DAYS = 2;
const DEFAULT_PER_PROFILE_MAX_RESULTS = 50;
const DEFAULT_PROFILE_SET = "finance_v1";
const DEFAULT_RUN_MODE = "full";
const HYDRATE_CONCURRENCY_LIMIT = 8;
const MAX_CANDIDATE_LIMIT = 300;
const MAX_MAX_TARGETS = 150;
const MAX_PER_PROFILE_MAX_RESULTS = 100;
const SHADOW_INTEGRITY_MARKER = "shadow_metrics_only_v2";
const SHADOW_REMEDIATION_FUNCTION = "public.remediate_gmail_financial_shadow_state";
const ALLOWED_SOURCES = [
  "cron",
  "gmail-financial-pipeline",
  "gmail-financial-scrape",
  "manual",
  "operator",
  "strat",
];
const KNOWN_VENDOR_HINTS = [
  "Accent Granite",
  "BS&A/Oconee County",
  "Carter Lumber",
  "Fieldstone Center",
  "Georgia Power",
  "Grounded Siteworks",
  "HCB",
  "Joist",
  "Madison Blueprint",
  "QuickBooks",
  "Window Concepts",
];
const INTERNAL_VENDOR_NORMALS = new Set(["hcb", "heartwood custom builders"]);
// Fallback constants — used if vendor_registry table is unavailable
const VENDOR_REJECT_TERMS_FALLBACK = new Set([
  "accounts receivable",
  "accounts payable",
  "billing",
  "no reply",
  "noreply",
  "notification",
  "notifications",
  "quickbooks",
  "system",
]);
const INTERNAL_VENDOR_PATTERNS_FALLBACK: RegExp[] = [/^hcb$/, /^heartwood/];
const INTERNAL_VENDOR_NORMALS_FALLBACK = new Set([
  "hcb",
  "heartwood custom builders",
]);
const GENERIC_PROJECT_ALIAS_STOPLIST = new Set([
  "admin",
  "chad",
  "chris",
  "heartwood",
  "robyn",
  "zack",
]);

type RunMode = "retrieve_only" | "classify_only" | "extract_only" | "full";

interface JsonRecord {
  [key: string]: unknown;
}

interface RunStats {
  candidates_accept_extract: number;
  candidates_accept_non_extract: number;
  candidates_classified: number;
  candidates_retrieved: number;
  candidates_rejected: number;
  candidates_review: number;
  duplicates_seen: number;
  messages_examined: number;
  messages_listed: number;
  receipts_inserted: number;
  skipped_missing_amount: number;
  skipped_missing_date: number;
  skipped_missing_vendor: number;
  skipped_other: number;
}

interface CandidateWorkItem {
  bodyExcerpt: string | null;
  bodyText: string;
  candidateId: string | null;
  classificationState: string | null;
  decision: string | null;
  docType: string | null;
  extractionReceiptId: string | null;
  extractionState: string | null;
  fromHeader: string | null;
  internalDateIso: string | null;
  matchedClassHints: string[];
  matchedProfileSlugs: string[];
  matchedQueryFragments: string[];
  messageId: string;
  priority: number;
  rawHeaders: Array<Record<string, unknown>>;
  snippet: string | null;
  subject: string | null;
  threadId: string | null;
}

interface CandidateAffinitySignals {
  matchedProjectAliases: string[];
  matchedProjectIds: string[];
  matchedProjectNames: string[];
  matchedTargetIds: string[];
  matchedTargetTypes: string[];
  matchedTargets: SearchTarget[];
  matchedVendorNames: string[];
}

interface PipelineDeps {
  db?: any;
  gmailGetJson?: typeof gmailApiGetJson;
  resolveAccessToken?: typeof resolveGmailAccessToken;
}

interface HydrationMetrics {
  concurrencyLimit: number;
  decodeWarnings: number;
  failedMessages: number;
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

function uniqStrings(values: unknown[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    const str = String(value || "").trim();
    if (!str) continue;
    const key = str.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(str);
  }
  return out;
}

function clamp(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

function safeIso(raw: string | null): string | null {
  const parsed = Date.parse(String(raw || ""));
  if (!Number.isFinite(parsed)) return null;
  return new Date(parsed).toISOString();
}

function addDays(date: Date, days: number): Date {
  return new Date(date.getTime() + days * 24 * 60 * 60 * 1000);
}

function normalizeBody(body: unknown): Record<string, unknown> {
  return body && typeof body === "object" ? body as Record<string, unknown> : {};
}

function truncate(value: string, maxLength: number): string {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  if (normalized.length <= maxLength) return normalized;
  return normalized.slice(0, Math.max(0, maxLength)).trim();
}

function resolveRunMode(raw: unknown): RunMode {
  switch (String(raw || "").trim().toLowerCase()) {
    case "retrieve_only":
      return "retrieve_only";
    case "classify_only":
      return "classify_only";
    case "extract_only":
      return "extract_only";
    default:
      return "full";
  }
}

function choosePerProfileMaxResults(candidateLimit: number, raw: unknown): number {
  const fallback = Math.min(
    MAX_PER_PROFILE_MAX_RESULTS,
    Math.max(DEFAULT_PER_PROFILE_MAX_RESULTS, Math.ceil(candidateLimit / 2)),
  );
  return clamp(raw, fallback, 1, MAX_PER_PROFILE_MAX_RESULTS);
}

function parseTimestamp(value: string | null): number {
  const parsed = Date.parse(String(value || ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function incrementCount(store: Record<string, number>, key: string | null | undefined): void {
  const normalized = String(key || "").trim() || "unknown";
  store[normalized] = (store[normalized] || 0) + 1;
}

function isMeaningfulProjectAlias(alias: string | null): boolean {
  const normalized = String(alias || "").trim().toLowerCase();
  if (!normalized) return false;
  if (GENERIC_PROJECT_ALIAS_STOPLIST.has(normalized)) return false;
  return normalized.length >= 5 || /[\s0-9&/_-]/.test(normalized);
}

function isMeaningfulTarget(
  target: SearchTarget,
  internalNormals: Set<string> = INTERNAL_VENDOR_NORMALS,
): boolean {
  const normalizedVendor = normalizeVendorName(target.vendor_name);
  return !!normalizedVendor && !internalNormals.has(normalizedVendor);
}

function resolveMailboxScope(
  profiles: GmailQueryProfile[],
  warnings: string[],
): string | null {
  const scopes = uniqStrings(
    profiles.map((profile) => profile.mailbox_scope).filter(Boolean),
  );
  if (scopes.length > 1) {
    throw new Error(`mixed_mailbox_scope:${scopes.join(",")}`);
  }
  if (scopes.length === 0) {
    warnings.push("mailbox_scope_unspecified");
    return null;
  }
  return scopes[0];
}

function responseForRun(runId: string, stats: RunStats, extra: Record<string, unknown> = {}) {
  return json({
    ok: true,
    function_slug: FUNCTION_SLUG,
    function_version: FUNCTION_VERSION,
    run_id: runId,
    stats,
    ...extra,
  });
}

function nextExtractionState(
  currentState: string | null,
  decision: string | null,
): string {
  if (currentState === "extracted") return "extracted";
  if (decision === "accept_extract" || decision === "review") return "pending";
  return "skipped";
}

function applyCandidateClassificationState(
  candidate: CandidateWorkItem,
  classification: GmailFinanceClassification,
  classificationState: "classified" | "failed",
): void {
  candidate.classificationState = classificationState;
  candidate.decision = classification.decision;
  candidate.docType = classification.docType;
  candidate.extractionState = nextExtractionState(candidate.extractionState, classification.decision);
}

function buildCandidateFailureClassification(reason: string): GmailFinanceClassification {
  return {
    classifierMeta: {
      failure_mode: "candidate_exception",
      failure_reason: reason,
    },
    classifierVersion: "gmail_finance_classifier_failure",
    decision: "review",
    decisionReason: "candidate_processing_failed",
    docType: "unknown",
    financeRelevanceScore: 0.45,
  };
}

function noteClassificationCounts(
  classification: GmailFinanceClassification,
  stats: RunStats,
  classificationCounts: Record<string, number>,
  decisionCounts: Record<string, number>,
): void {
  stats.candidates_classified++;
  incrementCount(classificationCounts, classification.docType);
  incrementCount(decisionCounts, classification.decision);

  if (classification.decision === "accept_extract") stats.candidates_accept_extract++;
  if (classification.decision === "accept_non_extract") stats.candidates_accept_non_extract++;
  if (classification.decision === "review") stats.candidates_review++;
  if (classification.decision === "reject") stats.candidates_rejected++;
}

function shouldSkipClassificationInFullMode(candidate: CandidateWorkItem): boolean {
  return candidate.classificationState === "classified" && !!candidate.decision;
}

async function mapWithConcurrency<T, R>(
  items: T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  if (items.length === 0) return [];
  const results = new Array<R>(items.length);
  let cursor = 0;

  const runWorker = async () => {
    while (true) {
      const index = cursor++;
      if (index >= items.length) return;
      results[index] = await worker(items[index], index);
    }
  };

  const workers = Array.from({ length: Math.min(Math.max(1, concurrency), items.length) }, () => runWorker());
  await Promise.all(workers);
  return results;
}

async function loadAliasRows(db: any): Promise<AliasRow[]> {
  const aliasRows: AliasRow[] = [];

  const { data: projects } = await db
    .from("projects")
    .select("id,name")
    .in("status", ["active", "warranty", "estimating"])
    .eq("project_kind", "client")
    .limit(1000);

  const projectNames = new Map<string, string>();
  for (const row of safeArray<Record<string, unknown>>(projects)) {
    const id = String(row.id || "").trim();
    const name = String(row.name || "").trim();
    if (!id || !name) continue;
    projectNames.set(id, name);
  }

  const { data: aliases } = await db
    .from("v_project_alias_lookup")
    .select("project_id,alias")
    .limit(5000);

  for (const row of safeArray<Record<string, unknown>>(aliases)) {
    const projectId = String(row.project_id || "").trim();
    const alias = String(row.alias || "").trim();
    if (!alias) continue;
    aliasRows.push({
      alias,
      job_name: projectId ? projectNames.get(projectId) || null : null,
      project_id: projectId || null,
    });
  }

  return aliasRows;
}

async function loadSearchTargets(db: any, limit: number): Promise<SearchTarget[]> {
  const { data, error } = await db
    .from("v_gmail_search_targets")
    .select([
      "target_id",
      "target_type",
      "contact_id",
      "project_id",
      "project_name",
      "vendor_name",
      "vendor_name_normalized",
      "email",
      "relation_type",
      "confidence",
      "source",
      "contact_name",
      "company",
      "trade",
      "contact_aliases",
      "company_aliases",
      "priority",
    ].join(","))
    .order("priority", { ascending: false })
    .order("confidence", { ascending: false })
    .limit(limit);

  if (error || !data) return [];

  return safeArray<Record<string, unknown>>(data).map((row) => ({
    company: row.company ? String(row.company) : null,
    company_aliases: safeArray<string>(row.company_aliases).map((value) => String(value || "")).filter(Boolean),
    confidence: row.confidence === null || row.confidence === undefined ? null : Number(row.confidence),
    contact_aliases: safeArray<string>(row.contact_aliases).map((value) => String(value || "")).filter(Boolean),
    contact_id: row.contact_id ? String(row.contact_id) : null,
    contact_name: row.contact_name ? String(row.contact_name) : null,
    email: String(row.email || "").trim().toLowerCase(),
    priority: row.priority === null || row.priority === undefined ? null : Number(row.priority),
    project_id: row.project_id ? String(row.project_id) : null,
    project_name: row.project_name ? String(row.project_name) : null,
    relation_type: row.relation_type ? String(row.relation_type) : null,
    source: row.source ? String(row.source) : null,
    target_id: String(row.target_id || ""),
    target_type: row.target_type ? String(row.target_type) : null,
    trade: row.trade ? String(row.trade) : null,
    vendor_name: String(row.vendor_name || "").trim(),
    vendor_name_normalized: row.vendor_name_normalized ? String(row.vendor_name_normalized) : null,
  })).filter((row) => row.target_id && row.email && row.vendor_name);
}

async function loadQueryProfiles(db: any, profileSet: string): Promise<GmailQueryProfile[]> {
  const { data, error } = await db
    .from("gmail_query_profiles")
    .select([
      "active",
      "class_hint",
      "effective_after_date",
      "gmail_query",
      "label_mirror_name",
      "mailbox_scope",
      "priority",
      "profile_set",
      "profile_slug",
    ].join(","))
    .eq("profile_set", profileSet)
    .eq("active", true)
    .order("priority", { ascending: false })
    .order("profile_slug", { ascending: true });

  if (error || !data) return [];
  return safeArray<Record<string, unknown>>(data).map((row) => ({
    active: row.active === true,
    class_hint: row.class_hint ? String(row.class_hint) : null,
    effective_after_date: row.effective_after_date ? String(row.effective_after_date) : null,
    gmail_query: String(row.gmail_query || "").trim(),
    label_mirror_name: row.label_mirror_name ? String(row.label_mirror_name) : null,
    mailbox_scope: row.mailbox_scope ? String(row.mailbox_scope) : null,
    priority: Number(row.priority || 0),
    profile_set: String(row.profile_set || profileSet),
    profile_slug: String(row.profile_slug || ""),
  })).filter((profile) => profile.profile_slug && profile.gmail_query);
}

function buildCandidateAffinitySignals(
  candidate: CandidateWorkItem,
  aliasRows: AliasRow[],
  searchTargets: SearchTarget[],
  internalNormals?: Set<string>,
): CandidateAffinitySignals {
  const bodyText = candidate.bodyText || candidate.bodyExcerpt || candidate.snippet || "";
  const matchedTargets = searchTargets.length > 0
    ? matchTargetsToMessage(searchTargets, candidate.rawHeaders, bodyText)
    : [];
  const meaningfulTargets = matchedTargets.filter((t) => isMeaningfulTarget(t, internalNormals));
  const subjectProject = findProjectMatch(candidate.subject || "", aliasRows);
  const bodyProject = subjectProject.project_id
    ? { job_name: null, matched_alias: null, project_id: null }
    : findProjectMatch(bodyText, aliasRows);
  const meaningfulProjectMatches = [subjectProject, bodyProject].filter((match) =>
    isMeaningfulProjectAlias(match.matched_alias)
  );

  return {
    matchedProjectAliases: uniqStrings(meaningfulProjectMatches.map((match) => match.matched_alias)),
    matchedProjectIds: uniqStrings([
      ...meaningfulProjectMatches.map((match) => match.project_id),
      ...meaningfulTargets.map((target) => target.project_id),
    ]),
    matchedProjectNames: uniqStrings([
      ...meaningfulProjectMatches.map((match) => match.job_name),
      ...meaningfulTargets.map((target) => target.project_name),
    ]),
    matchedTargetIds: uniqStrings(meaningfulTargets.map((target) => target.target_id)),
    matchedTargetTypes: uniqStrings(meaningfulTargets.map((target) => target.target_type)),
    matchedTargets,
    matchedVendorNames: uniqStrings(meaningfulTargets.map((target) => target.vendor_name)),
  };
}

async function updateRun(
  db: any,
  runId: string,
  patch: Record<string, unknown>,
): Promise<void> {
  const { error } = await db
    .from("gmail_financial_pipeline_runs")
    .update(patch)
    .eq("id", runId);
  if (error) {
    throw new Error(`run_update_failed:${error.message}`);
  }
}

async function listMessagesForProfileRegistry(args: {
  accessToken: string;
  afterDate: Date;
  gmailGetJson: typeof gmailApiGetJson;
  perProfileMaxResults: number;
  profiles: GmailQueryProfile[];
  warnings: string[];
}): Promise<{
  listedMessages: ListedCandidateMessage[];
  profileResultEstimates: Record<string, number>;
  resultEstimateLowerBound: number;
}> {
  const listedById = new Map<string, ListedCandidateMessage>();
  const profileResultEstimates: Record<string, number> = {};

  for (const profile of args.profiles) {
    let pageToken: string | null = null;
    let profileHits = 0;
    const gmailQuery = buildProfileGmailQuery(profile, args.afterDate);

    while (profileHits < args.perProfileMaxResults) {
      const remaining = Math.min(100, args.perProfileMaxResults - profileHits);
      const listResp = await args.gmailGetJson({
        token: args.accessToken,
        path: "messages",
        params: {
          fields: "messages(id,threadId),nextPageToken,resultSizeEstimate",
          includeSpamTrash: "false",
          maxResults: remaining,
          pageToken: pageToken || undefined,
          q: gmailQuery,
        },
      });

      if (!listResp.ok) {
        args.warnings.push(
          listResp.status > 0
            ? `gmail_profile_list_failed:${profile.profile_slug}:http_${listResp.status}`
            : `gmail_profile_list_failed:${profile.profile_slug}:network`,
        );
        break;
      }

      const resultSizeEstimate = Number(listResp.json?.resultSizeEstimate || 0) || 0;
      profileResultEstimates[profile.profile_slug] = Math.max(
        profileResultEstimates[profile.profile_slug] || 0,
        resultSizeEstimate,
      );
      const rows = safeArray<Record<string, unknown>>(listResp.json?.messages);
      for (const row of rows) {
        const id = String(row.id || "").trim();
        if (!id) continue;
        addProfileHit(
          listedById,
          id,
          row.threadId ? String(row.threadId) : null,
          profile,
          gmailQuery,
        );
        profileHits++;
      }

      pageToken = typeof listResp.json?.nextPageToken === "string" ? listResp.json.nextPageToken : null;
      if (!pageToken || rows.length === 0) break;
    }
  }

  const resultEstimateLowerBound = Math.max(
    listedById.size,
    ...Object.values(profileResultEstimates),
  );

  return {
    listedMessages: [...listedById.values()].sort((a, b) => b.priority - a.priority),
    profileResultEstimates,
    resultEstimateLowerBound,
  };
}

async function hydrateListedMessages(args: {
  accessToken: string;
  gmailGetJson: typeof gmailApiGetJson;
  listedMessages: ListedCandidateMessage[];
  stats: RunStats;
  warnings: string[];
  metrics: HydrationMetrics;
}): Promise<{ candidates: CandidateWorkItem[]; maxInternalDateMs: number | null }> {
  const candidates: CandidateWorkItem[] = [];
  let maxInternalDateMs: number | null = null;

  const results = await mapWithConcurrency(args.listedMessages, args.metrics.concurrencyLimit, async (listed) => {
    const localWarnings: string[] = [];
    try {
      const msgResp = await args.gmailGetJson({
        token: args.accessToken,
        path: `messages/${encodeURIComponent(listed.id)}`,
        params: {
          fields: "id,threadId,internalDate,snippet,historyId," +
            "payload(headers,mimeType,filename,body/data,body/attachmentId,body/size," +
            "parts(partId,mimeType,filename,body/data,body/attachmentId,body/size,headers," +
            "parts(partId,mimeType,filename,body/data,body/attachmentId,body/size,headers,parts)))",
          format: "full",
        },
      });

      if (!msgResp.ok) {
        localWarnings.push(
          msgResp.status > 0
            ? `gmail_get_failed:${listed.id}:http_${msgResp.status}`
            : `gmail_get_failed:${listed.id}:network`,
        );
        return {
          candidate: null,
          decodeWarnings: 0,
          examined: 0,
          internalDateMs: null,
          skippedOther: 1,
          warnings: localWarnings,
        };
      }

      const message = normalizeBody(msgResp.json);
      const payload = normalizeBody(message.payload);
      const headers = safeArray<Record<string, unknown>>(payload.headers);
      const subject = extractHeader(headers, "Subject");
      const from = extractHeader(headers, "From");
      const dateHeader = extractHeader(headers, "Date");
      const snippet = String(message.snippet || "").replace(/\s+/g, " ").trim() || null;
      const internalDateMs = Number(message.internalDate || 0);
      const internalDateIso = Number.isFinite(internalDateMs) && internalDateMs > 0
        ? new Date(internalDateMs).toISOString()
        : safeIso(dateHeader);

      const decodeWarnings: string[] = [];
      const decodedBody = decodeGmailMessageText(payload, decodeWarnings);
      for (const warning of decodeWarnings) {
        localWarnings.push(`gmail_message_decode_warning:${listed.id}:${warning}`);
      }
      const bodyText = [snippet || "", decodedBody].filter(Boolean).join("\n\n");

      return {
        candidate: {
          bodyExcerpt: truncate(bodyText, 5000) || null,
          bodyText,
          candidateId: null,
          classificationState: null,
          decision: null,
          docType: null,
          extractionReceiptId: null,
          extractionState: null,
          fromHeader: from,
          internalDateIso,
          matchedClassHints: uniqStrings(listed.class_hints),
          matchedProfileSlugs: uniqStrings(listed.matched_profile_slugs),
          matchedQueryFragments: uniqStrings(listed.query_fragments),
          messageId: listed.id,
          priority: listed.priority,
          rawHeaders: headers,
          snippet,
          subject,
          threadId: listed.threadId || (message.threadId ? String(message.threadId) : null),
        },
        decodeWarnings: decodeWarnings.length,
        examined: 1,
        internalDateMs: Number.isFinite(internalDateMs) && internalDateMs > 0 ? internalDateMs : null,
        skippedOther: 0,
        warnings: localWarnings,
      };
    } catch (error) {
      localWarnings.push(
        `gmail_get_failed:${listed.id}:unexpected:${String((error as Error)?.message || error).slice(0, 80)}`,
      );
      return {
        candidate: null,
        decodeWarnings: 0,
        examined: 0,
        internalDateMs: null,
        skippedOther: 1,
        warnings: localWarnings,
      };
    }
  });

  for (const result of results) {
    args.stats.messages_examined += result.examined;
    args.stats.skipped_other += result.skippedOther;
    args.metrics.decodeWarnings += result.decodeWarnings;
    if (result.skippedOther > 0) args.metrics.failedMessages += result.skippedOther;
    args.warnings.push(...result.warnings);

    if (result.internalDateMs !== null) {
      maxInternalDateMs = maxInternalDateMs === null
        ? result.internalDateMs
        : Math.max(maxInternalDateMs, result.internalDateMs);
    }
    if (result.candidate) candidates.push(result.candidate);
  }

  return { candidates, maxInternalDateMs };
}

async function loadCandidatesForMode(
  db: any,
  runMode: RunMode,
  candidateLimit: number,
): Promise<CandidateWorkItem[]> {
  let query = db
    .from("gmail_financial_candidates")
    .select([
      "id",
      "message_id",
      "thread_id",
      "internal_date",
      "subject",
      "from_header",
      "snippet",
      "body_excerpt",
      "raw_headers",
      "matched_profile_slugs",
      "matched_class_hints",
      "matched_query_fragments",
      "classification_state",
      "decision",
      "doc_type",
      "extraction_state",
      "extraction_receipt_id",
    ].join(","))
    .order("last_retrieved_at_utc", { ascending: false })
    .limit(candidateLimit);

  if (runMode === "classify_only") {
    query = query.in("classification_state", ["pending", "failed"]);
  } else if (runMode === "extract_only") {
    query = query.eq("decision", "accept_extract").in("extraction_state", ["pending", "failed"]);
  }

  const { data, error } = await query;
  if (error || !data) return [];

  return safeArray<Record<string, unknown>>(data).map((row) => ({
    bodyExcerpt: row.body_excerpt ? String(row.body_excerpt) : null,
    bodyText: row.body_excerpt ? String(row.body_excerpt) : String(row.snippet || ""),
    candidateId: row.id ? String(row.id) : null,
    classificationState: row.classification_state ? String(row.classification_state) : null,
    decision: row.decision ? String(row.decision) : null,
    docType: row.doc_type ? String(row.doc_type) : null,
    extractionReceiptId: row.extraction_receipt_id ? String(row.extraction_receipt_id) : null,
    extractionState: row.extraction_state ? String(row.extraction_state) : null,
    fromHeader: row.from_header ? String(row.from_header) : null,
    internalDateIso: safeIso(row.internal_date ? String(row.internal_date) : null),
    matchedClassHints: safeArray<string>(row.matched_class_hints).map((value) => String(value || "")).filter(Boolean),
    matchedProfileSlugs: safeArray<string>(row.matched_profile_slugs).map((value) => String(value || "")).filter(
      Boolean,
    ),
    matchedQueryFragments: safeArray<string>(row.matched_query_fragments).map((value) => String(value || "")).filter(
      Boolean,
    ),
    messageId: String(row.message_id || ""),
    priority: 0,
    rawHeaders: safeArray<Record<string, unknown>>(row.raw_headers),
    snippet: row.snippet ? String(row.snippet) : null,
    subject: row.subject ? String(row.subject) : null,
    threadId: row.thread_id ? String(row.thread_id) : null,
  })).filter((candidate) => candidate.messageId && candidate.candidateId);
}

async function persistCandidateClassification(
  db: any,
  candidate: CandidateWorkItem,
  classification: GmailFinanceClassification,
): Promise<void> {
  if (!candidate.candidateId) return;
  const now = new Date().toISOString();
  const nextState = nextExtractionState(candidate.extractionState, classification.decision);

  const { error } = await db
    .from("gmail_financial_candidates")
    .update({
      classification_state: "classified",
      classifier_meta: classification.classifierMeta,
      classifier_version: classification.classifierVersion,
      decision: classification.decision,
      decision_reason: classification.decisionReason,
      doc_type: classification.docType,
      extraction_state: nextState,
      finance_relevance_score: classification.financeRelevanceScore,
      review_resolution: classification.decision === "review" ? null : classification.decision,
      review_resolved_at_utc: classification.decision === "review" ? null : now,
      review_state: classification.decision === "review" ? "pending" : "resolved",
      updated_at: now,
    })
    .eq("id", candidate.candidateId);

  if (error) {
    throw new Error(`candidate_classification_update_failed:${error.message}`);
  }

  candidate.classificationState = "classified";
  candidate.decision = classification.decision;
  candidate.docType = classification.docType;
  candidate.extractionState = nextState;
}

async function persistCandidateClassificationFailure(
  db: any,
  candidate: CandidateWorkItem,
  classification: GmailFinanceClassification,
  reason: string,
): Promise<void> {
  if (!candidate.candidateId) return;
  const now = new Date().toISOString();

  const { error } = await db
    .from("gmail_financial_candidates")
    .update({
      classification_state: "failed",
      classifier_meta: {
        ...classification.classifierMeta,
        failure_reason: reason,
      },
      classifier_version: classification.classifierVersion,
      decision: classification.decision,
      decision_reason: classification.decisionReason,
      doc_type: classification.docType,
      extraction_state: nextExtractionState(candidate.extractionState, classification.decision),
      finance_relevance_score: classification.financeRelevanceScore,
      review_resolution: null,
      review_resolved_at_utc: null,
      review_state: "pending",
      updated_at: now,
    })
    .eq("id", candidate.candidateId);

  if (error) {
    throw new Error(`candidate_classification_failure_update_failed:${error.message}`);
  }

  applyCandidateClassificationState(candidate, classification, "failed");
}

async function persistCandidateExtraction(
  db: any,
  candidateId: string,
  patch: Record<string, unknown>,
): Promise<void> {
  const { error } = await db
    .from("gmail_financial_candidates")
    .update({
      updated_at: new Date().toISOString(),
      ...patch,
    })
    .eq("id", candidateId);
  if (error) {
    throw new Error(`candidate_extraction_update_failed:${error.message}`);
  }
}

async function pendingReviewCount(db: any): Promise<number> {
  const { count } = await db
    .from("v_gmail_financial_review_queue")
    .select("*", { count: "exact", head: true });
  return Number(count || 0);
}

async function reviewQueueSample(db: any, limit = 10): Promise<Array<Record<string, unknown>>> {
  const { data } = await db
    .from("v_gmail_financial_review_queue")
    .select([
      "candidate_id",
      "message_id",
      "subject",
      "from_header",
      "doc_type",
      "decision_reason",
      "finance_relevance_score",
      "matched_profile_slugs",
      "last_retrieved_at_utc",
    ].join(","))
    .order("last_retrieved_at_utc", { ascending: false })
    .limit(limit);

  return safeArray<Record<string, unknown>>(data);
}

export async function handleRequest(
  req: Request,
  deps: PipelineDeps = {},
): Promise<Response> {
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed", function_slug: FUNCTION_SLUG }, 405);
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) return authErrorResponse(auth.error_code || "auth_failed");

  let db = deps.db;
  if (!db) {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    if (!supabaseUrl || !supabaseKey) {
      return json({ ok: false, error: "missing_supabase_config" }, 500);
    }
    db = createClient(supabaseUrl, supabaseKey);
  }

  const gmailGetJson = deps.gmailGetJson || gmailApiGetJson;
  const resolveAccessToken = deps.resolveAccessToken || resolveGmailAccessToken;

  let body: JsonRecord = {};
  try {
    body = normalizeBody(await req.json());
  } catch {
    body = {};
  }

  const dryRun = body.dry_run === true;
  const profileSet = String(body.profile_set || DEFAULT_PROFILE_SET).trim() || DEFAULT_PROFILE_SET;
  const runMode = resolveRunMode(body.run_mode || DEFAULT_RUN_MODE);
  const reviewOnly = body.review_only === true;
  const candidateLimit = clamp(
    body.candidate_limit ?? body.max_messages,
    DEFAULT_CANDIDATE_LIMIT,
    1,
    MAX_CANDIDATE_LIMIT,
  );
  const maxTargets = clamp(body.max_targets, DEFAULT_MAX_TARGETS, 1, MAX_MAX_TARGETS);
  const overlapDays = clamp(body.overlap_days, DEFAULT_OVERLAP_DAYS, 0, 14);
  const bootstrapLookbackDays = clamp(
    body.bootstrap_lookback_days || Deno.env.get("GMAIL_FINANCIAL_BOOTSTRAP_LOOKBACK_DAYS"),
    DEFAULT_BOOTSTRAP_LOOKBACK_DAYS,
    1,
    365,
  );
  const perProfileMaxResults = choosePerProfileMaxResults(
    candidateLimit,
    body.per_profile_max_results,
  );
  const mirrorLabels = body.mirror_labels === true;
  const legacySearchMode = String(body.search_mode || Deno.env.get("GMAIL_FINANCIAL_SEARCH_MODE") || "")
    .trim()
    .toLowerCase() || null;
  const scheduleSlug = String(body.schedule_slug || "").trim() || null;
  const pipelineKey = String(body.pipeline_key || profileSet).trim() || profileSet;
  const runStartedAt = new Date();
  const warnings: string[] = [];
  const stats: RunStats = {
    candidates_accept_extract: 0,
    candidates_accept_non_extract: 0,
    candidates_classified: 0,
    candidates_retrieved: 0,
    candidates_rejected: 0,
    candidates_review: 0,
    duplicates_seen: 0,
    messages_examined: 0,
    messages_listed: 0,
    receipts_inserted: 0,
    skipped_missing_amount: 0,
    skipped_missing_date: 0,
    skipped_missing_vendor: 0,
    skipped_other: 0,
  };
  const classifierMetrics = createClassifierMetrics();
  const hydrationMetrics: HydrationMetrics = {
    concurrencyLimit: HYDRATE_CONCURRENCY_LIMIT,
    decodeWarnings: 0,
    failedMessages: 0,
  };

  // Action: resolve_reviews — auto-promote review candidates whose vendors are now in the registry
  if (body.action === "resolve_reviews") {
    const promoResult = await autoPromoteByVendorRegistry(db, warnings);
    return json({
      ok: true,
      action: "resolve_reviews",
      ...promoResult,
      warnings,
    });
  }

  if (legacySearchMode) warnings.push(`deprecated_search_mode_used:${legacySearchMode}`);
  if (mirrorLabels) warnings.push("mirror_labels_requested_but_gmail_scope_is_readonly");

  const { data: latestRuns } = await db
    .from("gmail_financial_pipeline_runs")
    .select("finished_at_utc")
    .eq("pipeline_key", pipelineKey)
    .in("status", ["ok", "partial"])
    .order("finished_at_utc", { ascending: false })
    .limit(1);

  let afterDate = addDays(runStartedAt, -bootstrapLookbackDays);
  const latestFinishedAt = String(safeArray<Record<string, unknown>>(latestRuns)[0]?.finished_at_utc || "").trim();
  if (latestFinishedAt) {
    const parsed = Date.parse(latestFinishedAt);
    if (Number.isFinite(parsed)) {
      afterDate = addDays(new Date(parsed), -overlapDays);
    }
  }

  const querySummary = `profile_set:${profileSet} run_mode:${runMode} candidate_limit:${candidateLimit}`;
  const { data: insertedRun, error: runInsertError } = await db
    .from("gmail_financial_pipeline_runs")
    .insert({
      gmail_after_date: afterDate.toISOString().slice(0, 10),
      gmail_query: querySummary,
      label_id: null,
      max_messages: candidateLimit,
      pipeline_key: pipelineKey,
      started_at_utc: runStartedAt.toISOString(),
      status: "running",
    })
    .select("id")
    .single();

  if (runInsertError || !insertedRun?.id) {
    return json({
      ok: false,
      error: "run_insert_failed",
      detail: runInsertError?.message || "unknown",
    }, 500);
  }

  const runId = String(insertedRun.id);
  const doRetrieve = runMode === "retrieve_only" || runMode === "full";
  const doClassify = runMode === "classify_only" || runMode === "full";
  const doExtract = (runMode === "extract_only" || runMode === "full") && !reviewOnly;

  let queryProfiles: GmailQueryProfile[] = [];
  let searchTargets: SearchTarget[] = [];
  let aliasRows: AliasRow[] = [];
  let authMode: string | null = null;
  let mailboxScope: string | null = null;

  try {
    let workCandidates: CandidateWorkItem[] = [];
    let maxInternalDateMs: number | null = null;
    let gmailProfileResultEstimates: Record<string, number> = {};
    let gmailResultEstimateLowerBound = 0;

    if (doRetrieve) {
      queryProfiles = await loadQueryProfiles(db, profileSet);
      if (queryProfiles.length === 0) {
        throw new Error("no_query_profiles");
      }
      mailboxScope = resolveMailboxScope(queryProfiles, warnings);

      const access = await resolveAccessToken({ env: Deno.env, warnings });
      authMode = access.authMode;
      if (!access.token) {
        throw new Error("gmail_auth_unconfigured");
      }

      const listed = await listMessagesForProfileRegistry({
        accessToken: access.token,
        afterDate,
        gmailGetJson,
        perProfileMaxResults,
        profiles: queryProfiles,
        warnings,
      });
      gmailProfileResultEstimates = listed.profileResultEstimates;
      gmailResultEstimateLowerBound = listed.resultEstimateLowerBound;
      stats.messages_listed = listed.listedMessages.length;

      const hydrated = await hydrateListedMessages({
        accessToken: access.token,
        gmailGetJson,
        listedMessages: listed.listedMessages,
        metrics: hydrationMetrics,
        stats,
        warnings,
      });
      maxInternalDateMs = hydrated.maxInternalDateMs;
      workCandidates = hydrated.candidates
        .sort((a, b) => {
          const dateDelta = parseTimestamp(b.internalDateIso) - parseTimestamp(a.internalDateIso);
          if (dateDelta !== 0) return dateDelta;
          return b.priority - a.priority;
        })
        .slice(0, candidateLimit);

      if (hydrated.candidates.length > candidateLimit) {
        warnings.push(`candidate_limit_applied:${candidateLimit}`);
      }

      for (const candidate of workCandidates) {
        const { data, error } = await db.rpc("upsert_gmail_financial_candidate", {
          p_candidate: {
            body_excerpt: candidate.bodyExcerpt,
            from_header: candidate.fromHeader,
            internal_date: candidate.internalDateIso,
            matched_class_hints: candidate.matchedClassHints,
            matched_profile_slugs: candidate.matchedProfileSlugs,
            matched_query_fragments: candidate.matchedQueryFragments,
            message_id: candidate.messageId,
            raw_headers: candidate.rawHeaders,
            run_id: runId,
            snippet: candidate.snippet,
            subject: candidate.subject,
            thread_id: candidate.threadId,
          },
        });

        if (error) {
          warnings.push(`candidate_upsert_failed:${error.message.slice(0, 120)}`);
          continue;
        }

        const row = safeArray<Record<string, unknown>>(data)[0] || {};
        candidate.candidateId = String(row.candidate_id || "").trim() || null;
        candidate.classificationState = row.classification_state ? String(row.classification_state) : null;
        candidate.decision = row.decision ? String(row.decision) : null;
        candidate.extractionState = row.extraction_state ? String(row.extraction_state) : null;
      }

      stats.candidates_retrieved = workCandidates.filter((candidate) => !!candidate.candidateId).length;

      await updateRun(db, runId, {
        gmail_result_estimate: gmailResultEstimateLowerBound,
        max_internal_date_ms: maxInternalDateMs,
      });
    } else {
      workCandidates = await loadCandidatesForMode(db, runMode, candidateLimit);
    }

    let vendorRegistry: VendorRegistryRow[] = [];
    let vendorRejectSet: Set<string> = VENDOR_REJECT_TERMS_FALLBACK;
    let vendorInternalPatterns: RegExp[] = INTERNAL_VENDOR_PATTERNS_FALLBACK;
    let vendorInternalNormals: Set<string> = INTERNAL_VENDOR_NORMALS_FALLBACK;
    let vendorHintNames: string[] = [...KNOWN_VENDOR_HINTS];

    if (doClassify || doExtract) {
      aliasRows = await loadAliasRows(db);
      searchTargets = await loadSearchTargets(db, maxTargets);

      try {
        vendorRegistry = await loadVendorRegistry(db);
        vendorRejectSet = buildRejectSet(vendorRegistry);
        vendorInternalPatterns = buildInternalPatterns(vendorRegistry);
        vendorInternalNormals = buildInternalVendorNormals(vendorRegistry);
        vendorHintNames = buildVendorHintList(vendorRegistry);
        warnings.push(`vendor_registry_loaded:${vendorRegistry.length}_entries`);
      } catch (err) {
        warnings.push(
          `vendor_registry_fallback:${String((err as Error)?.message || err).slice(0, 80)}`,
        );
      }
    }

    const classificationCounts: Record<string, number> = {};
    const decisionCounts: Record<string, number> = {};

    if (doClassify) {
      for (const candidate of workCandidates) {
        if (!candidate.candidateId) continue;
        if (runMode === "full" && shouldSkipClassificationInFullMode(candidate)) continue;
        try {
          const affinity = buildCandidateAffinitySignals(candidate, aliasRows, searchTargets, vendorInternalNormals);
          const classification = await classifyCandidate(
            {
              bodyExcerpt: candidate.bodyExcerpt,
              fromHeader: candidate.fromHeader,
              matchedClassHints: candidate.matchedClassHints,
              matchedProjectAliases: affinity.matchedProjectAliases,
              matchedProjectIds: affinity.matchedProjectIds,
              matchedProjectNames: affinity.matchedProjectNames,
              matchedProfileSlugs: candidate.matchedProfileSlugs,
              matchedTargetIds: affinity.matchedTargetIds,
              matchedTargetTypes: affinity.matchedTargetTypes,
              matchedVendorNames: affinity.matchedVendorNames,
              snippet: candidate.snippet,
              subject: candidate.subject,
            },
            warnings,
            classifierMetrics,
            vendorInternalNormals,
          );

          if (dryRun) {
            applyCandidateClassificationState(candidate, classification, "classified");
          } else {
            await persistCandidateClassification(db, candidate, classification);
          }
          noteClassificationCounts(classification, stats, classificationCounts, decisionCounts);
        } catch (error) {
          const detail = String((error as Error)?.message || error).slice(0, 160);
          warnings.push(`candidate_classification_failed:${candidate.messageId}:${detail}`);
          const failureClassification = buildCandidateFailureClassification(detail);
          if (dryRun) {
            applyCandidateClassificationState(candidate, failureClassification, "failed");
          } else {
            try {
              await persistCandidateClassificationFailure(db, candidate, failureClassification, detail);
            } catch (persistError) {
              warnings.push(
                `candidate_classification_failure_update_failed:${candidate.messageId}:${
                  String((persistError as Error)?.message || persistError).slice(0, 160)
                }`,
              );
            }
          }
          noteClassificationCounts(failureClassification, stats, classificationCounts, decisionCounts);
        }
      }
    } else {
      for (const candidate of workCandidates) {
        incrementCount(classificationCounts, candidate.docType);
        incrementCount(decisionCounts, candidate.decision);
      }
    }

    if (doExtract) {
      const extractableCandidates = workCandidates.filter((candidate) =>
        candidate.candidateId &&
        candidate.decision === "accept_extract" &&
        candidate.extractionState !== "extracted"
      );

      for (const candidate of extractableCandidates) {
        try {
          const affinity = buildCandidateAffinitySignals(candidate, aliasRows, searchTargets, vendorInternalNormals);
          const matchedTargets = affinity.matchedTargets;
          const vendorHints = mergeVendorHints(vendorHintNames, matchedTargets);
          const receipt = applyTargetAffinity(
            extractReceiptRecord({
              aliasRows,
              bodyText: candidate.bodyText || candidate.bodyExcerpt || candidate.snippet || "",
              fallbackIso: candidate.internalDateIso,
              fromHeader: candidate.fromHeader,
              mailboxDomain: mailboxScope,
              registryOverrides: {
                rejectSet: vendorRejectSet,
                internalPatterns: vendorInternalPatterns,
              },
              subject: candidate.subject,
              vendorHints,
            }),
            matchedTargets,
          );

          // Option B: flag unknown vendors for review
          if (receipt.vendor_normalized && vendorRegistry.length > 0) {
            const known = lookupVendor(vendorRegistry, receipt.vendor_normalized);
            if (!known) {
              await flagUnknownVendor(db, {
                vendor_name: receipt.vendor || receipt.vendor_normalized,
                vendor_normalized: receipt.vendor_normalized,
                source_email_from: candidate.fromHeader || null,
                source_candidate_id: candidate.candidateId || null,
              }, warnings);
            }
          }

          // Canonicalize vendor display name via registry
          if (receipt.vendor && receipt.vendor_normalized && vendorRegistry.length > 0) {
            const canonical = canonicalizeVendorDisplay(
              vendorRegistry,
              receipt.vendor_normalized,
              receipt.vendor,
            );
            if (canonical && canonical !== receipt.vendor) {
              receipt.vendor = canonical;
            }
          }

          const evidenceLocator = candidate.threadId
            ? `gmail:thread/${candidate.threadId}#msg=${candidate.messageId}`
            : `gmail:msg/${candidate.messageId}`;
          const vendorSource = receipt.reasons.find((reason) => reason.startsWith("vendor:"))?.split(":")[1] || null;
          const amountSource = receipt.amount.method;
          const extractionMeta = {
            amount_method: receipt.amount.method,
            amount_raw: receipt.amount.raw,
            auth_mode: authMode,
            classifier_decision: candidate.decision,
            classifier_doc_type: candidate.docType,
            function_slug: FUNCTION_SLUG,
            function_version: FUNCTION_VERSION,
            matched_class_hints: candidate.matchedClassHints,
            matched_project_aliases: affinity.matchedProjectAliases,
            matched_project_ids: affinity.matchedProjectIds,
            matched_project_names: affinity.matchedProjectNames,
            matched_profile_slugs: candidate.matchedProfileSlugs,
            matched_query_fragments: candidate.matchedQueryFragments,
            matched_target_ids: matchedTargets.map((target) => target.target_id),
            matched_target_types: uniqStrings(matchedTargets.map((target) => target.target_type)),
            matched_vendor_names: affinity.matchedVendorNames,
            reasons: receipt.reasons,
            retrieval_mode: "profile_registry",
            target_affinity_used: affinity.matchedTargetIds.length > 0 || affinity.matchedProjectIds.length > 0,
            vendor_source: vendorSource,
            amount_source: amountSource,
          };

          if (!receipt.vendor || !receipt.vendor_normalized) {
            stats.skipped_missing_vendor++;
            if (!dryRun) {
              await persistCandidateExtraction(db, candidate.candidateId!, {
                extraction_error: "missing_vendor",
                extraction_meta: extractionMeta,
                extraction_state: "skipped",
              });
            }
            continue;
          }

          if (receipt.amount.total === null) {
            stats.skipped_missing_amount++;
            if (!dryRun) {
              await persistCandidateExtraction(db, candidate.candidateId!, {
                extraction_error: "missing_amount",
                extraction_meta: extractionMeta,
                extraction_state: "skipped",
              });
            }
            continue;
          }

          if (!receipt.receipt_date) {
            stats.skipped_missing_date++;
            if (!dryRun) {
              await persistCandidateExtraction(db, candidate.candidateId!, {
                extraction_error: "missing_date",
                extraction_meta: extractionMeta,
                extraction_state: "skipped",
              });
            }
            continue;
          }

          const rpcPayload = {
            body_excerpt: receipt.body_excerpt,
            evidence_locator: evidenceLocator,
            extraction_confidence: receipt.confidence,
            extraction_meta: extractionMeta,
            gmail_label_id: null,
            invoice_or_transaction: receipt.invoice_or_transaction,
            job_name: receipt.job_name,
            latest_gmail_internal_date: candidate.internalDateIso,
            matched_project_alias: receipt.matched_project_alias,
            project_id: receipt.project_id,
            receipt_date: receipt.receipt_date,
            sample_from: candidate.fromHeader,
            sample_subject: candidate.subject,
            source: "gmail_scrape",
            source_message_ids: [candidate.messageId],
            source_thread_ids: candidate.threadId ? [candidate.threadId] : [],
            total: receipt.amount.total,
            vendor: receipt.vendor,
            vendor_normalized: receipt.vendor_normalized,
          };

          if (dryRun) {
            stats.receipts_inserted++;
            continue;
          }

          const { data: upsertResult, error: upsertError } = await db.rpc("upsert_gmail_financial_receipt", {
            p_receipt: rpcPayload,
          });

          if (upsertError) {
            stats.skipped_other++;
            warnings.push(`gmail_receipt_upsert_failed:${upsertError.message.slice(0, 120)}`);
            await persistCandidateExtraction(db, candidate.candidateId!, {
              extraction_error: upsertError.message.slice(0, 240),
              extraction_meta: extractionMeta,
              extraction_state: "failed",
            });
            continue;
          }

          const resultRow = safeArray<Record<string, unknown>>(upsertResult)[0] || {};
          if (resultRow.is_duplicate === true) {
            stats.duplicates_seen++;
          } else {
            stats.receipts_inserted++;
          }

          await persistCandidateExtraction(db, candidate.candidateId!, {
            extracted_at_utc: new Date().toISOString(),
            extraction_error: null,
            extraction_meta: {
              ...extractionMeta,
              duplicate: resultRow.is_duplicate === true,
            },
            extraction_receipt_id: resultRow.receipt_id || null,
            extraction_state: "extracted",
          });
        } catch (error) {
          stats.skipped_other++;
          const detail = String((error as Error)?.message || error).slice(0, 160);
          warnings.push(`candidate_extraction_failed:${candidate.messageId}:${detail}`);
          if (!dryRun && candidate.candidateId) {
            try {
              await persistCandidateExtraction(db, candidate.candidateId, {
                extraction_error: detail,
                extraction_meta: {
                  classifier_decision: candidate.decision,
                  classifier_doc_type: candidate.docType,
                  function_slug: FUNCTION_SLUG,
                  function_version: FUNCTION_VERSION,
                },
                extraction_state: "failed",
              });
            } catch (persistError) {
              warnings.push(
                `candidate_extraction_failure_update_failed:${candidate.messageId}:${
                  String((persistError as Error)?.message || persistError).slice(0, 160)
                }`,
              );
            }
          }
        }
      }
    }

    const reviewQueueCount = await pendingReviewCount(db);
    const notes = {
      auth_mode: authMode,
      candidate_counts: {
        classified: stats.candidates_classified,
        retrieved: stats.candidates_retrieved,
      },
      classifier_metrics: classifierMetrics,
      classification_counts_by_doc_type: classificationCounts,
      decision_counts: decisionCounts,
      extraction_counts: {
        duplicates_seen: stats.duplicates_seen,
        receipts_inserted: stats.receipts_inserted,
        skipped_missing_amount: stats.skipped_missing_amount,
        skipped_missing_date: stats.skipped_missing_date,
        skipped_missing_vendor: stats.skipped_missing_vendor,
        skipped_other: stats.skipped_other,
      },
      hydration_metrics: {
        concurrency_limit: hydrationMetrics.concurrencyLimit,
        decode_warning_count: hydrationMetrics.decodeWarnings,
        failed_messages: hydrationMetrics.failedMessages,
      },
      legacy_search_mode: legacySearchMode,
      mailbox_scope: mailboxScope,
      gmail_profile_result_estimates: gmailProfileResultEstimates,
      gmail_result_estimate_semantics: "lower_bound_max_profile_or_unique_hits",
      mirror_labels_requested: mirrorLabels,
      pipeline_key: pipelineKey,
      profile_set: profileSet,
      profiles_loaded: summarizeProfiles(queryProfiles, 20),
      retrieval_counts_by_profile: summarizeRetrievalCounts(
        workCandidates.map((candidate) => ({
          class_hints: candidate.matchedClassHints,
          id: candidate.messageId,
          matched_profile_slugs: candidate.matchedProfileSlugs,
          priority: candidate.priority,
          query_fragments: candidate.matchedQueryFragments,
          threadId: candidate.threadId,
        })),
      ),
      review_queue_counts: {
        pending_total: reviewQueueCount,
        produced_this_run: stats.candidates_review,
      },
      run_mode: runMode,
      schedule_slug: scheduleSlug,
      search_targets_loaded: summarizeTargets(searchTargets, 20),
      shadow_integrity: {
        cursor_source_statuses: ["ok", "partial"],
        dry_run_candidate_state: dryRun ? "ephemeral_only" : "persistent_live_mode",
        remediation_function: SHADOW_REMEDIATION_FUNCTION,
        shadow_integrity_marker: SHADOW_INTEGRITY_MARKER,
      },
    };

    const finalStatus = dryRun ? "dry_run" : warnings.length > 0 ? "partial" : "ok";
    await updateRun(db, runId, {
      duplicates_seen: stats.duplicates_seen,
      finished_at_utc: new Date().toISOString(),
      messages_examined: stats.messages_examined,
      messages_listed: stats.messages_listed,
      notes,
      receipts_inserted: stats.receipts_inserted,
      skipped_missing_amount: stats.skipped_missing_amount,
      skipped_missing_date: stats.skipped_missing_date,
      skipped_missing_vendor: stats.skipped_missing_vendor,
      skipped_other: stats.skipped_other,
      status: finalStatus,
      warnings,
    });

    return responseForRun(runId, stats, {
      mailbox_scope: mailboxScope,
      pipeline_key: pipelineKey,
      profile_set: profileSet,
      review_only: reviewOnly,
      review_queue_count: reviewQueueCount,
      review_queue_sample: reviewOnly ? await reviewQueueSample(db, 20) : undefined,
      run_mode: runMode,
      schedule_slug: scheduleSlug,
      status: finalStatus,
      warnings,
    });
  } catch (error: unknown) {
    const detail = String((error as Error)?.message || error || "unknown_error");
    const failureWarnings = [...warnings, detail];
    try {
      await updateRun(db, runId, {
        finished_at_utc: new Date().toISOString(),
        messages_examined: stats.messages_examined,
        messages_listed: stats.messages_listed,
        notes: {
          classifier_metrics: classifierMetrics,
          hydration_metrics: {
            concurrency_limit: hydrationMetrics.concurrencyLimit,
            decode_warning_count: hydrationMetrics.decodeWarnings,
            failed_messages: hydrationMetrics.failedMessages,
          },
          legacy_search_mode: legacySearchMode,
          mailbox_scope: mailboxScope,
          pipeline_key: pipelineKey,
          profile_set: profileSet,
          profiles_loaded: summarizeProfiles(queryProfiles, 20),
          run_mode: runMode,
          schedule_slug: scheduleSlug,
          search_targets_loaded: summarizeTargets(searchTargets, 20),
          shadow_integrity: {
            cursor_source_statuses: ["ok", "partial"],
            dry_run_candidate_state: dryRun ? "ephemeral_only" : "persistent_live_mode",
            remediation_function: SHADOW_REMEDIATION_FUNCTION,
            shadow_integrity_marker: SHADOW_INTEGRITY_MARKER,
          },
        },
        receipts_inserted: stats.receipts_inserted,
        duplicates_seen: stats.duplicates_seen,
        skipped_missing_amount: stats.skipped_missing_amount,
        skipped_missing_date: stats.skipped_missing_date,
        skipped_missing_vendor: stats.skipped_missing_vendor,
        skipped_other: stats.skipped_other,
        status: "failed",
        warnings: failureWarnings,
      });
    } catch (updateError) {
      failureWarnings.push(
        `run_update_failed:${String((updateError as Error)?.message || updateError).slice(0, 160)}`,
      );
    }
    return json({
      ok: false,
      detail,
      error: "pipeline_failed",
      function_slug: FUNCTION_SLUG,
      run_id: runId,
      warnings: failureWarnings,
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve((req) => handleRequest(req));
}
