export interface AliasRow {
  alias: string;
  job_name: string | null;
  project_id: string | null;
}

export interface ParsedAmount {
  method: string | null;
  raw: string | null;
  total: number | null;
}

export interface ParsedProjectMatch {
  job_name: string | null;
  matched_alias: string | null;
  project_id: string | null;
}

export interface ParsedReceipt {
  amount: ParsedAmount;
  body_excerpt: string;
  confidence: number;
  invoice_or_transaction: string | null;
  job_name: string | null;
  matched_project_alias: string | null;
  project_id: string | null;
  receipt_date: string | null;
  reasons: string[];
  vendor: string | null;
  vendor_normalized: string | null;
}

function safeArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : [];
}

function normalizeWhitespace(value: string): string {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function base64UrlToBase64(value: string): string {
  const raw = String(value || "").replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  if (!raw) return "";
  const padLength = (4 - (raw.length % 4)) % 4;
  return `${raw}${"=".repeat(padLength)}`;
}

function decodeBase64UrlUtf8(value: string, warnings?: string[]): string {
  const normalized = base64UrlToBase64(value);
  if (!normalized) return "";
  try {
    const binary = atob(normalized);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder().decode(bytes);
  } catch (error) {
    warnings?.push(`base64_decode_failed:${String((error as Error)?.message || error).slice(0, 80)}`);
    return "";
  }
}

function stripHtml(value: string): string {
  return normalizeWhitespace(
    String(value || "")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p>/gi, "\n")
      .replace(/<\/div>/gi, "\n")
      .replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;/gi, " ")
      .replace(/&amp;/gi, "&")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">"),
  );
}

function parseMoney(raw: string | null): number | null {
  const normalized = normalizeWhitespace(String(raw || ""));
  if (!normalized) return null;

  const negativeByParens = /^\(\s*\$?.*\)$/.test(normalized);
  const unsigned = normalized.replace(/[\s,$()]/g, "");
  const negativeByMinus = unsigned.startsWith("-");
  const magnitude = negativeByMinus ? unsigned.slice(1) : unsigned;

  if (!magnitude || !/^[0-9]+(\.[0-9]+)?$/.test(magnitude)) return null;

  const parsed = Number(magnitude);
  if (!Number.isFinite(parsed)) return null;

  const signed = negativeByParens || negativeByMinus ? -parsed : parsed;
  return Math.round(signed * 100) / 100;
}

function parseDateCandidate(raw: string | null): string | null {
  const value = normalizeWhitespace(String(raw || ""));
  if (!value) return null;

  const toIsoDate = (year: number, month: number, day: number): string | null => {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    const parsed = new Date(Date.UTC(year, month - 1, day));
    if (
      parsed.getUTCFullYear() !== year ||
      parsed.getUTCMonth() + 1 !== month ||
      parsed.getUTCDate() !== day
    ) {
      return null;
    }
    return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  };

  const isoCandidate = value.match(/\b(20\d{2})-(\d{1,2})-(\d{1,2})\b/);
  if (isoCandidate) {
    const year = Number(isoCandidate[1]);
    const month = Number(isoCandidate[2]);
    const day = Number(isoCandidate[3]);
    const parsed = toIsoDate(year, month, day);
    if (parsed) return parsed;
    return null;
  }

  const slashCandidate = value.match(/\b(\d{1,2})\/(\d{1,2})\/(20\d{2}|\d{2})\b/);
  if (slashCandidate) {
    const month = Number(slashCandidate[1]);
    const day = Number(slashCandidate[2]);
    const year = slashCandidate[3].length === 2 ? Number(`20${slashCandidate[3]}`) : Number(slashCandidate[3]);
    const parsed = toIsoDate(year, month, day);
    if (parsed) return parsed;
    return null;
  }

  const longDate = Date.parse(value);
  if (Number.isFinite(longDate)) {
    return new Date(longDate).toISOString().slice(0, 10);
  }
  return null;
}

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

    if (!isWordChar(before) && (after === "'" || after === "\u2019")) {
      const nextIdx = afterIdx + 1;
      if (nextIdx < textLower.length && textLower[nextIdx].toLowerCase() === "s") {
        const afterS = nextIdx + 1;
        if (afterS >= textLower.length || !isWordChar(textLower[afterS])) return idx;
      }
    }

    startPos = idx + 1;
  }
  return -1;
}

function longestAliasFirst(rows: AliasRow[]): AliasRow[] {
  return [...rows].sort((a, b) => String(b.alias || "").length - String(a.alias || "").length);
}

function extractEmailDisplayName(fromHeader: string | null): string | null {
  const raw = normalizeWhitespace(String(fromHeader || ""));
  if (!raw) return null;

  const angle = raw.match(/^"?([^"<]+?)"?\s*<[^>]+>$/);
  if (angle) {
    return normalizeWhitespace(angle[1].replace(/^"+|"+$/g, ""));
  }

  const emailOnly = raw.match(/<?([^<>\s]+@[^<>\s]+)>?/);
  if (emailOnly) {
    const localPart = String(emailOnly[1]).split("@")[0] || "";
    return normalizeWhitespace(localPart.replace(/[._-]+/g, " "));
  }

  return raw;
}

export function extractHeader(headers: unknown, name: string): string | null {
  const wanted = String(name || "").toLowerCase();
  for (const header of safeArray<Record<string, unknown>>(headers)) {
    if (String(header?.name || "").toLowerCase() !== wanted) continue;
    const value = normalizeWhitespace(String(header?.value || ""));
    return value || null;
  }
  return null;
}

export function decodeGmailMessageText(payload: unknown, warnings: string[] = []): string {
  const plainParts: string[] = [];
  const htmlParts: string[] = [];

  function walk(part: unknown): void {
    if (!part || typeof part !== "object") return;
    const typed = part as Record<string, unknown>;
    const mimeType = String(typed.mimeType || "").toLowerCase();
    const filename = normalizeWhitespace(String(typed.filename || ""));
    const body = (typed.body && typeof typed.body === "object") ? typed.body as Record<string, unknown> : {};
    const data = typeof body?.data === "string" ? body.data : "";

    if (data && !filename) {
      const decoded = decodeBase64UrlUtf8(data, warnings);
      if (mimeType.startsWith("text/plain")) {
        plainParts.push(decoded);
      } else if (mimeType.startsWith("text/html")) {
        htmlParts.push(decoded);
      }
    }

    for (const child of safeArray<unknown>(typed.parts)) {
      walk(child);
    }
  }

  walk(payload);

  const plain = normalizeWhitespace(plainParts.join("\n"));
  if (plain) return plain;

  const html = stripHtml(htmlParts.join("\n"));
  return html;
}

export function normalizeVendorName(raw: string | null): string | null {
  const normalized = normalizeWhitespace(String(raw || "").toLowerCase())
    .replace(/\b(invoice|payment|llc|inc|co|corp|company|department|dept)\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\bqb\b/g, "quickbooks")
    .replace(/\bquickbooks\s+online\b/g, "quickbooks")
    .replace(/\bhcb\s+homes?\b/g, "hcb")
    .replace(/\bbs\s*&\s*a\b/g, "bsa")
    .replace(/\bocon(?:ee)?\s+county\b/g, "oconee county")
    .replace(/\s+/g, " ")
    .trim();
  return normalized || null;
}

export function extractVendor(
  fromHeader: string | null,
  subject: string | null,
  bodyText: string,
  vendorHints: string[],
): { vendor: string | null; vendor_normalized: string | null; source: string | null } {
  const combined = `${subject || ""}\n${fromHeader || ""}\n${bodyText}`.toLowerCase();
  const normalizedHints = vendorHints
    .map((hint) => ({
      raw: hint,
      normalized: normalizeVendorName(hint),
    }))
    .filter((item) => item.normalized);

  const matchingHints = normalizedHints
    .sort((a, b) => String(b.raw).length - String(a.raw).length)
    .filter((hint) => findTermInText(combined, hint.raw.toLowerCase()) >= 0);

  const preferredHint = matchingHints.find((hint) => hint.normalized !== "hcb") ||
    matchingHints[0];
  if (preferredHint) {
    return { vendor: preferredHint.raw, vendor_normalized: preferredHint.normalized, source: "vendor_hint" };
  }

  const display = extractEmailDisplayName(fromHeader);
  const displayNormalized = normalizeVendorName(display);
  if (display && displayNormalized) {
    if (displayNormalized === "quickbooks" && combined.includes("hcb")) {
      return { vendor: "HCB", vendor_normalized: "hcb", source: "quickbooks_hcb_override" };
    }
    return { vendor: display, vendor_normalized: displayNormalized, source: "from_header" };
  }

  return { vendor: null, vendor_normalized: null, source: null };
}

export function extractAmount(text: string): ParsedAmount {
  const hay = String(text || "");
  const moneyPattern = String.raw`(\(\s*(?:\$\s*[0-9][0-9,]*(?:\.\d{2})?|[0-9][0-9,]*\.\d{2})\s*\)|-\s*(?:\$\s*[0-9][0-9,]*(?:\.\d{2})?|[0-9][0-9,]*\.\d{2})|\$\s*[0-9][0-9,]*(?:\.\d{2})?|[0-9][0-9,]*\.\d{2})`;
  const contextualPatterns = [
    new RegExp(
      String.raw`\b(?:grand total|invoice total|total amount|total due|amount due|balance due|payment due|total)\b[\s:]*${moneyPattern}`,
      "ig",
    ),
    new RegExp(
      String.raw`\b(?:paid amount|amount)\b[\s:]*${moneyPattern}`,
      "ig",
    ),
  ];

  for (const pattern of contextualPatterns) {
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(hay)) !== null) {
      const total = parseMoney(match[1] || null);
      if (total !== null) {
        return { total, raw: match[1], method: "contextual_total" };
      }
    }
  }

  const amountMatches = Array.from(hay.matchAll(new RegExp(moneyPattern, "g")))
    .map((match) => ({
      raw: match[1],
      total: parseMoney(match[1]),
    }))
    .filter((item) => item.total !== null) as Array<{ raw: string; total: number }>;

  if (amountMatches.length > 0) {
    amountMatches.sort((a, b) => b.total - a.total);
    return {
      total: amountMatches[0].total,
      raw: amountMatches[0].raw,
      method: "largest_dollar_amount",
    };
  }

  return { total: null, raw: null, method: null };
}

export function extractInvoiceOrTransaction(subject: string | null, text: string): string | null {
  const hay = `${subject || ""}\n${text}`;
  const patterns = [
    /\b(?:invoice|inv)\b(?:\s+(?:number|no)\b)?\s*(?:#|:|-)\s*([A-Z0-9-]{3,})\b/i,
    /\b(?:invoice|inv)\b\s+(?:number|no)\s+([A-Z0-9-]{3,})\b/i,
    /\btransaction\s*(?:id|number|#)?\s*[:#-]?\s*([A-Z0-9-]{3,})\b/i,
    /\bref(?:erence)?\s*(?:id|number|#)?\s*[:#-]?\s*([A-Z0-9-]{3,})\b/i,
  ];

  for (const pattern of patterns) {
    const match = hay.match(pattern);
    if (!match) continue;
    const value = normalizeWhitespace(match[1] || "");
    if (value) return value;
  }

  return null;
}

export function extractReceiptDate(text: string, fallbackIso: string | null): string | null {
  const patterns = [
    /\b(?:invoice date|statement date|date issued|issued on|receipt date|date)\b[\s:]*([A-Za-z]{3,9}\s+\d{1,2},\s+\d{4}|\d{1,2}\/\d{1,2}\/(?:20\d{2}|\d{2})|20\d{2}-\d{1,2}-\d{1,2})/i,
  ];

  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (!match) continue;
    const parsed = parseDateCandidate(match[1] || null);
    if (parsed) return parsed;
  }

  if (fallbackIso) return fallbackIso.slice(0, 10);
  return null;
}

export function findProjectMatch(text: string, aliasRows: AliasRow[]): ParsedProjectMatch {
  const hay = String(text || "").toLowerCase();
  for (const row of longestAliasFirst(aliasRows)) {
    const alias = normalizeWhitespace(row.alias);
    if (!alias || alias.length < 3) continue;
    if (findTermInText(hay, alias.toLowerCase()) < 0) continue;
    return {
      job_name: row.job_name,
      matched_alias: alias,
      project_id: row.project_id,
    };
  }

  return {
    job_name: null,
    matched_alias: null,
    project_id: null,
  };
}

function truncate(value: string, maxLength: number): string {
  const normalized = normalizeWhitespace(value);
  if (normalized.length <= maxLength) return normalized;
  return `${normalized.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

export function extractReceiptRecord(input: {
  aliasRows: AliasRow[];
  bodyText: string;
  fallbackIso: string | null;
  fromHeader: string | null;
  subject: string | null;
  vendorHints: string[];
}): ParsedReceipt {
  const bodyText = normalizeWhitespace(input.bodyText);
  const subjectProject = findProjectMatch(input.subject || "", input.aliasRows);
  const bodyProject = subjectProject.project_id ? null : findProjectMatch(bodyText, input.aliasRows);
  const project = subjectProject.project_id ? subjectProject : (bodyProject || {
    job_name: null,
    matched_alias: null,
    project_id: null,
  });
  const vendor = extractVendor(input.fromHeader, input.subject, bodyText, input.vendorHints);
  const amount = extractAmount(`${input.subject || ""}\n${bodyText}`);
  const invoice = extractInvoiceOrTransaction(input.subject, bodyText);
  const receiptDate = extractReceiptDate(bodyText, input.fallbackIso);

  const reasons: string[] = [];
  if (vendor.vendor) reasons.push(`vendor:${vendor.source || "derived"}`);
  if (amount.total !== null) reasons.push(`amount:${amount.method || "derived"}`);
  if (subjectProject.project_id) {
    reasons.push("project:subject_alias_match");
  } else if (project.project_id) {
    reasons.push("project:alias_match");
  }
  if (invoice) reasons.push("invoice_or_transaction:pattern");
  if (receiptDate) reasons.push("receipt_date:resolved");

  let confidence = 0.2;
  if (vendor.vendor) confidence += 0.2;
  if (amount.total !== null) confidence += 0.3;
  if (project.project_id) confidence += 0.2;
  if (invoice) confidence += 0.1;
  if (receiptDate) confidence += 0.1;
  confidence = Math.min(0.95, Math.max(0, confidence));

  return {
    amount,
    body_excerpt: truncate(bodyText, 500),
    confidence,
    invoice_or_transaction: invoice,
    job_name: project.job_name,
    matched_project_alias: project.matched_alias,
    project_id: project.project_id,
    receipt_date: receiptDate,
    reasons,
    vendor: vendor.vendor,
    vendor_normalized: vendor.vendor_normalized,
  };
}
