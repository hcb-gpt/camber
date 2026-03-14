import { parseLlmJson } from "../_shared/llm_json.ts";
import { normalizeVendorName } from "./extraction.ts";

export type GmailFinanceDocType =
  | "vendor_invoice"
  | "vendor_receipt"
  | "client_pay_app"
  | "client_draw_request"
  | "statement"
  | "reminder"
  | "tax_form"
  | "noise"
  | "unknown";

export type GmailFinanceDecision =
  | "accept_extract"
  | "accept_non_extract"
  | "review"
  | "reject";

export interface GmailFinanceCandidateInput {
  bodyExcerpt: string | null;
  fromHeader: string | null;
  matchedClassHints: string[];
  matchedProjectAliases: string[];
  matchedProjectIds: string[];
  matchedProjectNames: string[];
  matchedProfileSlugs: string[];
  matchedTargetIds: string[];
  matchedTargetTypes: string[];
  matchedVendorNames: string[];
  snippet: string | null;
  subject: string | null;
}

export interface GmailFinanceClassification {
  classifierMeta: Record<string, unknown>;
  classifierVersion: string;
  decision: GmailFinanceDecision;
  decisionReason: string;
  docType: GmailFinanceDocType;
  financeRelevanceScore: number;
}

export interface ClassifierMetrics {
  fallbackReviews: number;
  httpFailures: number;
  missingOpenAiKey: number;
  networkFailures: number;
  parseFailures: number;
  retries: number;
  successes: number;
  timeouts: number;
  attempts: number;
}

interface RawLlmClassification {
  decision?: string;
  decision_reason?: string;
  doc_type?: string;
  finance_relevance_score?: number | string;
  signals?: string[];
}

const CLASSIFIER_VERSION = "gmail_finance_classifier_v2";
const DEFAULT_MODEL = Deno.env.get("GMAIL_FINANCIAL_CLASSIFIER_MODEL") || "gpt-4o-mini";
const HEARTWOOD_CONTEXT_PATTERNS = [
  /heartwood custom builders/i,
  /@heartwoodcustombuilders\.com/i,
  /@hcb\.llc/i,
];
const INTERNAL_VENDOR_NORMALS = new Set(["hcb", "heartwood custom builders"]);
const GENERIC_PROJECT_ALIAS_STOPLIST = new Set([
  "admin",
  "chad",
  "chris",
  "heartwood",
  "robyn",
  "zack",
]);

const NOISE_PATTERNS = [
  /zapier alerts?/i,
  /one of your zaps has been paused/i,
  /possible error on your sms send/i,
  /do-not-reply@gong\.io/i,
  /mailer-daemon/i,
  /\bundeliverable\b/i,
  /\bdelivery status notification\b/i,
  /\bcost to complete\b/i,
  /\bseptic records\b/i,
  /\bpermit application\b/i,
];

const RECEIPT_PATTERNS = [
  /\breceipt\b/i,
  /payment confirmation/i,
  /payment received/i,
  /your receipt/i,
  /receipt for payment/i,
];

const INVOICE_PATTERNS = [
  /\binvoice\b/i,
  /\binvoices\b/i,
  /\binv[\s#:-]/i,
  /amount due/i,
  /balance due/i,
  /payment due/i,
  /view invoice/i,
  /pay invoice/i,
];

const PAY_APP_PATTERNS = [
  /application for payment/i,
  /\bpay app\b/i,
  /progress billing/i,
  /progress bill/i,
  /\baia g702\b/i,
  /\bg703\b/i,
];

const DRAW_PATTERNS = [
  /draw request/i,
  /request for payment/i,
];

const STATEMENT_PATTERNS = [
  /\bstatement\b/i,
  /statement of account/i,
];

const REMINDER_PATTERNS = [
  /\bpast due\b/i,
  /\boverdue\b/i,
  /\breminder\b/i,
];

const TAX_FORM_PATTERNS = [
  /\b1099\b/i,
  /\bw-9\b/i,
  /\btax form\b/i,
];

const DEFAULT_CLASSIFIER_TIMEOUT_MS = 20_000;
const DEFAULT_CLASSIFIER_MAX_ATTEMPTS = 3;
const DEFAULT_CLASSIFIER_RETRY_BASE_MS = 400;

export function createClassifierMetrics(): ClassifierMetrics {
  return {
    attempts: 0,
    fallbackReviews: 0,
    httpFailures: 0,
    missingOpenAiKey: 0,
    networkFailures: 0,
    parseFailures: 0,
    retries: 0,
    successes: 0,
    timeouts: 0,
  };
}

function classifierTimeoutMs(): number {
  const value = Number(Deno.env.get("GMAIL_FINANCIAL_CLASSIFIER_TIMEOUT_MS") || DEFAULT_CLASSIFIER_TIMEOUT_MS);
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_CLASSIFIER_TIMEOUT_MS;
}

function classifierMaxAttempts(): number {
  const value = Number(Deno.env.get("GMAIL_FINANCIAL_CLASSIFIER_MAX_ATTEMPTS") || DEFAULT_CLASSIFIER_MAX_ATTEMPTS);
  return Number.isFinite(value) && value >= 1 ? Math.floor(value) : DEFAULT_CLASSIFIER_MAX_ATTEMPTS;
}

function classifierRetryBaseMs(): number {
  const value = Number(Deno.env.get("GMAIL_FINANCIAL_CLASSIFIER_RETRY_BASE_MS") || DEFAULT_CLASSIFIER_RETRY_BASE_MS);
  return Number.isFinite(value) && value >= 0 ? Math.floor(value) : DEFAULT_CLASSIFIER_RETRY_BASE_MS;
}

async function sleep(ms: number): Promise<void> {
  if (ms <= 0) return;
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function isRetryableClassifierStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

function clampScore(value: unknown, fallback: number): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(0, Math.min(1, parsed));
}

function normalizeDocType(value: unknown): GmailFinanceDocType {
  switch (String(value || "").trim().toLowerCase()) {
    case "vendor_invoice":
      return "vendor_invoice";
    case "vendor_receipt":
      return "vendor_receipt";
    case "client_pay_app":
      return "client_pay_app";
    case "client_draw_request":
      return "client_draw_request";
    case "statement":
      return "statement";
    case "reminder":
      return "reminder";
    case "tax_form":
      return "tax_form";
    case "noise":
      return "noise";
    default:
      return "unknown";
  }
}

function extractableDocType(docType: GmailFinanceDocType): boolean {
  return [
    "vendor_invoice",
    "vendor_receipt",
    "client_pay_app",
    "client_draw_request",
    "statement",
    "reminder",
  ].includes(docType);
}

function hasHeartwoodContextSignal(candidate: GmailFinanceCandidateInput): boolean {
  const combined = [
    candidate.subject || "",
    candidate.fromHeader || "",
    candidate.snippet || "",
    candidate.bodyExcerpt || "",
  ].join("\n");
  return HEARTWOOD_CONTEXT_PATTERNS.some((pattern) => pattern.test(combined));
}

function hasMeaningfulProjectAlias(alias: string): boolean {
  const normalized = String(alias || "").trim().toLowerCase();
  if (!normalized) return false;
  if (GENERIC_PROJECT_ALIAS_STOPLIST.has(normalized)) return false;
  return normalized.length >= 5 || /[\s0-9&/_-]/.test(normalized);
}

function hasAutoExtractAffinity(
  candidate: GmailFinanceCandidateInput,
  docType: GmailFinanceDocType,
): boolean {
  if (candidate.matchedProjectAliases.some(hasMeaningfulProjectAlias)) return true;
  if (
    candidate.matchedVendorNames.some((name) => {
      const normalized = normalizeVendorName(name);
      return !!normalized && !INTERNAL_VENDOR_NORMALS.has(normalized);
    })
  ) {
    return true;
  }
  if (candidate.matchedProjectIds.length > 0) return true;
  if ((docType === "client_pay_app" || docType === "client_draw_request") && hasHeartwoodContextSignal(candidate)) {
    return true;
  }
  return false;
}

function chooseDecision(
  candidate: GmailFinanceCandidateInput,
  docType: GmailFinanceDocType,
  requestedDecision: unknown,
  score: number,
): GmailFinanceDecision {
  const normalized = String(requestedDecision || "").trim().toLowerCase();
  if (docType === "noise" || score <= 0.2) return "reject";
  if (docType === "tax_form") return "accept_non_extract";
  if (docType === "unknown" || score < 0.55) return "review";
  if (normalized === "review") return "review";
  if (normalized === "accept_non_extract") return "review";
  if (extractableDocType(docType)) {
    return hasAutoExtractAffinity(candidate, docType) ? "accept_extract" : "review";
  }
  return "review";
}

function buildClassification(
  candidate: GmailFinanceCandidateInput,
  docType: GmailFinanceDocType,
  score: number,
  reason: string,
  requestedDecision: unknown,
  classifierVersion: string,
  classifierMeta: Record<string, unknown>,
): GmailFinanceClassification {
  const affinityGatePassed = !extractableDocType(docType) || hasAutoExtractAffinity(candidate, docType);
  const decision = chooseDecision(candidate, docType, requestedDecision, score);
  return {
    classifierMeta: {
      ...classifierMeta,
      affinity_gate: affinityGatePassed ? "passed" : "review",
      matched_project_aliases: candidate.matchedProjectAliases,
      matched_project_ids: candidate.matchedProjectIds,
      matched_project_names: candidate.matchedProjectNames,
      matched_target_ids: candidate.matchedTargetIds,
      matched_target_types: candidate.matchedTargetTypes,
      matched_vendor_names: candidate.matchedVendorNames,
    },
    classifierVersion,
    decision,
    decisionReason: !affinityGatePassed && extractableDocType(docType)
      ? `${reason}_affinity_gate_review`
      : reason,
    docType,
    financeRelevanceScore: score,
  };
}

function fastPathReason(
  text: string,
  patterns: RegExp[],
  reason: string,
): string | null {
  return patterns.find((pattern) => pattern.test(text)) ? reason : null;
}

export function classifyCandidateByRules(
  candidate: GmailFinanceCandidateInput,
): GmailFinanceClassification | null {
  const combined = [
    candidate.subject || "",
    candidate.fromHeader || "",
    candidate.snippet || "",
    candidate.bodyExcerpt || "",
  ].join("\n");

  const noiseReason = fastPathReason(combined, NOISE_PATTERNS, "rules_noise_fastpath");
  if (noiseReason) {
    return buildClassification(
      candidate,
      "noise",
      0.01,
      noiseReason,
      "reject",
      `${CLASSIFIER_VERSION}_rules`,
      { fast_path: noiseReason, matched_profiles: candidate.matchedProfileSlugs },
    );
  }

  const taxReason = fastPathReason(combined, TAX_FORM_PATTERNS, "rules_tax_form_fastpath");
  if (taxReason) {
    return buildClassification(
      candidate,
      "tax_form",
      0.92,
      taxReason,
      "accept_non_extract",
      `${CLASSIFIER_VERSION}_rules`,
      { fast_path: taxReason, matched_profiles: candidate.matchedProfileSlugs },
    );
  }

  const payAppReason = fastPathReason(combined, PAY_APP_PATTERNS, "rules_pay_app_fastpath");
  if (payAppReason) {
    return buildClassification(
      candidate,
      "client_pay_app",
      0.9,
      payAppReason,
      "accept_extract",
      `${CLASSIFIER_VERSION}_rules`,
      { fast_path: payAppReason, matched_profiles: candidate.matchedProfileSlugs },
    );
  }

  const drawReason = fastPathReason(combined, DRAW_PATTERNS, "rules_draw_request_fastpath");
  if (drawReason) {
    return buildClassification(
      candidate,
      "client_draw_request",
      0.88,
      drawReason,
      "accept_extract",
      `${CLASSIFIER_VERSION}_rules`,
      { fast_path: drawReason, matched_profiles: candidate.matchedProfileSlugs },
    );
  }

  const receiptReason = fastPathReason(combined, RECEIPT_PATTERNS, "rules_receipt_fastpath");
  if (receiptReason && !/thank you for your payment/i.test(combined)) {
    return buildClassification(
      candidate,
      "vendor_receipt",
      0.82,
      receiptReason,
      "accept_extract",
      `${CLASSIFIER_VERSION}_rules`,
      { fast_path: receiptReason, matched_profiles: candidate.matchedProfileSlugs },
    );
  }

  const reminderReason = fastPathReason(combined, REMINDER_PATTERNS, "rules_reminder_fastpath");
  if (reminderReason) {
    return buildClassification(
      candidate,
      "reminder",
      0.78,
      reminderReason,
      "accept_extract",
      `${CLASSIFIER_VERSION}_rules`,
      { fast_path: reminderReason, matched_profiles: candidate.matchedProfileSlugs },
    );
  }

  const statementReason = fastPathReason(combined, STATEMENT_PATTERNS, "rules_statement_fastpath");
  if (statementReason) {
    return buildClassification(
      candidate,
      "statement",
      0.78,
      statementReason,
      "accept_extract",
      `${CLASSIFIER_VERSION}_rules`,
      { fast_path: statementReason, matched_profiles: candidate.matchedProfileSlugs },
    );
  }

  const invoiceReason = fastPathReason(combined, INVOICE_PATTERNS, "rules_invoice_fastpath");
  if (invoiceReason) {
    return buildClassification(
      candidate,
      "vendor_invoice",
      0.76,
      invoiceReason,
      "accept_extract",
      `${CLASSIFIER_VERSION}_rules`,
      {
        fast_path: invoiceReason,
        matched_class_hints: candidate.matchedClassHints,
        matched_profiles: candidate.matchedProfileSlugs,
      },
    );
  }

  return null;
}

function buildPrompt(candidate: GmailFinanceCandidateInput): string {
  return [
    "Classify this Gmail finance candidate into a strict JSON object.",
    "Return only JSON with keys: doc_type, finance_relevance_score, decision, decision_reason, signals.",
    "Allowed doc_type values: vendor_invoice, vendor_receipt, client_pay_app, client_draw_request, statement, reminder, tax_form, noise, unknown.",
    "Allowed decision values: accept_extract, accept_non_extract, review, reject.",
    "Use reject for clear noise, accept_non_extract for real finance mail that should not create a receipt row, review for uncertain cases, and accept_extract only for extractable finance documents.",
    "Be conservative: generic invoice-like mail without HCB, vendor, target, or project affinity should be review, not accept_extract.",
    "",
    `matched_profile_slugs: ${JSON.stringify(candidate.matchedProfileSlugs)}`,
    `matched_class_hints: ${JSON.stringify(candidate.matchedClassHints)}`,
    `matched_target_ids: ${JSON.stringify(candidate.matchedTargetIds)}`,
    `matched_target_types: ${JSON.stringify(candidate.matchedTargetTypes)}`,
    `matched_vendor_names: ${JSON.stringify(candidate.matchedVendorNames)}`,
    `matched_project_ids: ${JSON.stringify(candidate.matchedProjectIds)}`,
    `matched_project_names: ${JSON.stringify(candidate.matchedProjectNames)}`,
    `matched_project_aliases: ${JSON.stringify(candidate.matchedProjectAliases)}`,
    `from_header: ${JSON.stringify(candidate.fromHeader || "")}`,
    `subject: ${JSON.stringify(candidate.subject || "")}`,
    `snippet: ${JSON.stringify(candidate.snippet || "")}`,
    `body_excerpt: ${JSON.stringify((candidate.bodyExcerpt || "").slice(0, 5000))}`,
  ].join("\n");
}

async function classifyCandidateWithLlm(
  candidate: GmailFinanceCandidateInput,
  warnings: string[],
  metrics: ClassifierMetrics,
): Promise<GmailFinanceClassification | null> {
  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) {
    metrics.missingOpenAiKey++;
    warnings.push("gmail_finance_classifier_missing_openai_key");
    return null;
  }

  const maxAttempts = classifierMaxAttempts();
  const retryBaseMs = classifierRetryBaseMs();

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    metrics.attempts++;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), classifierTimeoutMs());
    try {
      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        signal: controller.signal,
        headers: {
          "Authorization": `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: DEFAULT_MODEL,
          temperature: 0,
          max_tokens: 300,
          response_format: { type: "json_object" },
          messages: [
            {
              role: "system",
              content:
                "You classify Gmail finance candidates. Output strict JSON only. Be conservative: route uncertain messages to review and obvious operational/admin noise to reject.",
            },
            {
              role: "user",
              content: buildPrompt(candidate),
            },
          ],
        }),
      });

      if (!response.ok) {
        const errorText = await response.text().catch(() => "");
        metrics.httpFailures++;
        if (attempt < maxAttempts && isRetryableClassifierStatus(response.status)) {
          metrics.retries++;
          warnings.push(`gmail_finance_classifier_retry_http_${response.status}:attempt_${attempt}`);
          await sleep(retryBaseMs * (2 ** (attempt - 1)));
          continue;
        }
        warnings.push(`gmail_finance_classifier_http_${response.status}:${errorText.slice(0, 120)}`);
        return null;
      }

      const json = await response.json().catch(() => null);
      const rawContent = String(json?.choices?.[0]?.message?.content || "").trim();
      if (!rawContent) {
        warnings.push("gmail_finance_classifier_empty_response");
        return null;
      }

      let parsed;
      try {
        parsed = parseLlmJson<RawLlmClassification>(rawContent);
      } catch (error) {
        metrics.parseFailures++;
        warnings.push(`gmail_finance_classifier_parse_failed:${String((error as Error)?.message || error).slice(0, 120)}`);
        return null;
      }

      const docType = normalizeDocType(parsed.value.doc_type);
      const score = clampScore(parsed.value.finance_relevance_score, 0.5);
      metrics.successes++;
      return buildClassification(
        candidate,
        docType,
        score,
        String(parsed.value.decision_reason || "llm_classification"),
        parsed.value.decision,
        `${CLASSIFIER_VERSION}_llm`,
        {
          llm_model: DEFAULT_MODEL,
          matched_class_hints: candidate.matchedClassHints,
          matched_profiles: candidate.matchedProfileSlugs,
          parse_mode: parsed.parseMode,
          signals: Array.isArray(parsed.value.signals) ? parsed.value.signals : [],
        },
      );
    } catch (error) {
      const detail = String((error as Error)?.message || error).slice(0, 120);
      const aborted = error instanceof DOMException && error.name === "AbortError";
      if (aborted) {
        metrics.timeouts++;
        if (attempt < maxAttempts) {
          metrics.retries++;
          warnings.push(`gmail_finance_classifier_retry_timeout:attempt_${attempt}`);
          await sleep(retryBaseMs * (2 ** (attempt - 1)));
          continue;
        }
        warnings.push(`gmail_finance_classifier_timeout:${detail}`);
        return null;
      }

      metrics.networkFailures++;
      if (attempt < maxAttempts) {
        metrics.retries++;
        warnings.push(`gmail_finance_classifier_retry_network:attempt_${attempt}`);
        await sleep(retryBaseMs * (2 ** (attempt - 1)));
        continue;
      }
      warnings.push(`gmail_finance_classifier_error:${detail}`);
      return null;
    } finally {
      clearTimeout(timeout);
    }
  }

  return null;
}

export async function classifyCandidate(
  candidate: GmailFinanceCandidateInput,
  warnings: string[],
  metrics: ClassifierMetrics = createClassifierMetrics(),
): Promise<GmailFinanceClassification> {
  const fastPath = classifyCandidateByRules(candidate);
  if (fastPath) return fastPath;

  const llmResult = await classifyCandidateWithLlm(candidate, warnings, metrics);
  if (llmResult) return llmResult;
  metrics.fallbackReviews++;

  return buildClassification(
    candidate,
    "unknown",
    0.45,
    "fallback_review_classifier_unavailable",
    "review",
    `${CLASSIFIER_VERSION}_fallback`,
    {
      matched_class_hints: candidate.matchedClassHints,
      matched_profiles: candidate.matchedProfileSlugs,
    },
  );
}
