import { normalizeVendorName, type ParsedReceipt } from "./extraction.ts";

export interface SearchTarget {
  company: string | null;
  company_aliases: string[];
  confidence: number | null;
  contact_aliases: string[];
  contact_id: string | null;
  contact_name: string | null;
  email: string;
  priority: number | null;
  project_id: string | null;
  project_name: string | null;
  relation_type: string | null;
  source: string | null;
  target_id: string;
  target_type: string | null;
  trade: string | null;
  vendor_name: string;
  vendor_name_normalized: string | null;
}

export interface GmailQueryProfile {
  active: boolean;
  class_hint: string | null;
  effective_after_date: string | null;
  gmail_query: string;
  label_mirror_name: string | null;
  mailbox_scope: string | null;
  priority: number;
  profile_set: string;
  profile_slug: string;
}

export interface ListedCandidateMessage {
  class_hints: string[];
  id: string;
  matched_profile_slugs: string[];
  priority: number;
  query_fragments: string[];
  threadId: string | null;
}

function uniqStrings(values: unknown[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    const raw = String(value || "").trim();
    if (!raw) continue;
    const key = raw.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(raw);
  }
  return out;
}

function pushReason(reasons: string[], reason: string): void {
  if (!reasons.includes(reason)) reasons.push(reason);
}

function normalizeGmailDate(date: Date): string {
  return `${date.getUTCFullYear()}/${String(date.getUTCMonth() + 1).padStart(2, "0")}/${
    String(date.getUTCDate()).padStart(2, "0")
  }`;
}

function pickHighestConfidence(targets: SearchTarget[]): SearchTarget | null {
  if (targets.length === 0) return null;
  return [...targets].sort((a, b) => Number(b.confidence || 0) - Number(a.confidence || 0))[0];
}

function profileEffectiveAfterDate(profile: GmailQueryProfile, fallbackAfterDate: Date): Date {
  const raw = String(profile.effective_after_date || "").trim();
  if (!raw) return fallbackAfterDate;
  const parsed = Date.parse(raw);
  if (!Number.isFinite(parsed)) return fallbackAfterDate;
  return parsed > fallbackAfterDate.getTime() ? new Date(parsed) : fallbackAfterDate;
}

function extractEmails(raw: string | null): string[] {
  const values = String(raw || "").match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) || [];
  return uniqStrings(values.map((value) => value.toLowerCase()));
}

export function buildProfileGmailQuery(
  profile: GmailQueryProfile,
  fallbackAfterDate: Date,
): string {
  const effectiveAfter = profileEffectiveAfterDate(profile, fallbackAfterDate);
  return [`after:${normalizeGmailDate(effectiveAfter)}`, profile.gmail_query]
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

export function addProfileHit(
  listedById: Map<string, ListedCandidateMessage>,
  id: string,
  threadId: string | null,
  profile: GmailQueryProfile,
  queryFragment: string,
): void {
  const existing = listedById.get(id);
  if (existing) {
    existing.threadId = existing.threadId || threadId;
    existing.priority = Math.max(existing.priority, Number(profile.priority || 0));
    if (queryFragment && !existing.query_fragments.includes(queryFragment)) {
      existing.query_fragments.push(queryFragment);
    }
    if (profile.profile_slug && !existing.matched_profile_slugs.includes(profile.profile_slug)) {
      existing.matched_profile_slugs.push(profile.profile_slug);
    }
    if (profile.class_hint && !existing.class_hints.includes(profile.class_hint)) {
      existing.class_hints.push(profile.class_hint);
    }
    return;
  }

  listedById.set(id, {
    class_hints: profile.class_hint ? [profile.class_hint] : [],
    id,
    matched_profile_slugs: profile.profile_slug ? [profile.profile_slug] : [],
    priority: Number(profile.priority || 0),
    query_fragments: queryFragment ? [queryFragment] : [],
    threadId,
  });
}

export function summarizeProfiles(
  profiles: GmailQueryProfile[],
  limit = 20,
): Array<Record<string, unknown>> {
  return profiles.slice(0, Math.max(0, limit)).map((profile) => ({
    active: profile.active,
    class_hint: profile.class_hint,
    effective_after_date: profile.effective_after_date,
    label_mirror_name: profile.label_mirror_name,
    mailbox_scope: profile.mailbox_scope,
    priority: profile.priority,
    profile_set: profile.profile_set,
    profile_slug: profile.profile_slug,
  }));
}

export function summarizeRetrievalCounts(
  candidates: ListedCandidateMessage[],
): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const candidate of candidates) {
    for (const slug of candidate.matched_profile_slugs) {
      counts[slug] = (counts[slug] || 0) + 1;
    }
  }
  return counts;
}

export function matchTargetsToMessage(
  targets: SearchTarget[],
  rawHeaders: Array<Record<string, unknown>>,
  bodyText = "",
): SearchTarget[] {
  const participantEmails = new Set<string>();
  const relevantHeaders = new Set(["from", "to", "cc", "bcc", "reply-to", "delivered-to"]);

  for (const header of rawHeaders || []) {
    const name = String(header?.name || "").toLowerCase();
    if (!relevantHeaders.has(name)) continue;
    for (const email of extractEmails(String(header?.value || ""))) {
      participantEmails.add(email);
    }
  }

  for (const email of extractEmails(bodyText)) {
    participantEmails.add(email);
  }

  return targets.filter((target) => participantEmails.has(String(target.email || "").toLowerCase()));
}

export function buildTargetQueryFragment(
  target: SearchTarget,
  outboundSender: string | null,
): string {
  const email = String(target.email || "").trim().toLowerCase();
  if (!email) return "";

  if (target.target_type === "client_outbound") {
    const clauses = [`to:${email}`];
    const sender = String(outboundSender || "").trim().toLowerCase();
    if (sender) clauses.push(`from:${sender}`);
    return clauses.join(" ");
  }

  return `(from:${email} OR to:${email})`;
}

export function mergeVendorHints(
  baseHints: string[],
  matchedTargets: SearchTarget[],
): string[] {
  const values: unknown[] = [...baseHints];

  for (const target of matchedTargets) {
    if (target.target_type === "client_outbound") continue;
    values.push(
      target.vendor_name,
      target.contact_name,
      target.company,
      ...(target.contact_aliases || []),
      ...(target.company_aliases || []),
    );
  }

  return uniqStrings(values);
}

export function applyTargetAffinity(
  receipt: ParsedReceipt,
  matchedTargets: SearchTarget[],
): ParsedReceipt {
  if (matchedTargets.length === 0) return receipt;

  const next: ParsedReceipt = {
    ...receipt,
    reasons: [...receipt.reasons],
  };

  const clientTargets = matchedTargets.filter((target) => target.target_type === "client_outbound");
  const vendorTargets = matchedTargets.filter((target) => target.target_type !== "client_outbound");
  const clientTargetNormals = uniqStrings(
    clientTargets.map((target) => target.vendor_name_normalized || normalizeVendorName(target.vendor_name)),
  ).filter(Boolean);

  let confidenceBoost = 0;

  const projectTargets = matchedTargets.filter((target) => target.project_id);
  const uniqueProjectIds = uniqStrings(projectTargets.map((target) => target.project_id)).filter(Boolean);
  if (uniqueProjectIds.length === 1) {
    const preferredProjectTarget = pickHighestConfidence(
      projectTargets.filter((target) => target.project_id === uniqueProjectIds[0]),
    );
    if (preferredProjectTarget && !next.project_id) {
      next.project_id = preferredProjectTarget.project_id;
      next.job_name = next.job_name || preferredProjectTarget.project_name;
      next.matched_project_alias = next.matched_project_alias || "camber_target";
      pushReason(next.reasons, "project:target_affinity");
      confidenceBoost += 0.12;
    } else if (preferredProjectTarget && next.project_id === preferredProjectTarget.project_id) {
      pushReason(next.reasons, "project:target_affinity_confirmed");
      confidenceBoost += 0.04;
    }
  }

  if (clientTargets.length > 0 && (!next.vendor_normalized || clientTargetNormals.includes(next.vendor_normalized))) {
    next.vendor = "HCB";
    next.vendor_normalized = "hcb";
    pushReason(next.reasons, "vendor:client_outbound_default");
    confidenceBoost += 0.08;
  } else {
    const vendorTargetNormals = uniqStrings(
      vendorTargets.map((target) => target.vendor_name_normalized || normalizeVendorName(target.vendor_name)),
    ).filter(Boolean);

    if (!next.vendor && vendorTargetNormals.length === 1) {
      const preferredVendorTarget = pickHighestConfidence(
        vendorTargets.filter((target) =>
          (target.vendor_name_normalized || normalizeVendorName(target.vendor_name)) === vendorTargetNormals[0]
        ),
      );
      if (preferredVendorTarget) {
        next.vendor = preferredVendorTarget.vendor_name;
        next.vendor_normalized = preferredVendorTarget.vendor_name_normalized ||
          normalizeVendorName(preferredVendorTarget.vendor_name);
        pushReason(next.reasons, "vendor:target_affinity");
        confidenceBoost += 0.08;
      }
    } else if (next.vendor_normalized && vendorTargetNormals.includes(next.vendor_normalized)) {
      pushReason(next.reasons, "vendor:target_affinity_confirmed");
      confidenceBoost += 0.03;
    }
  }

  next.confidence = Math.min(0.98, Math.max(0, next.confidence + confidenceBoost));
  return next;
}

export function summarizeTargets(
  targets: SearchTarget[],
  limit = 20,
): Array<Record<string, unknown>> {
  return targets.slice(0, Math.max(0, limit)).map((target) => ({
    confidence: target.confidence,
    email: target.email,
    project_name: target.project_name,
    relation_type: target.relation_type,
    source: target.source,
    target_type: target.target_type,
    vendor_name: target.vendor_name,
  }));
}
