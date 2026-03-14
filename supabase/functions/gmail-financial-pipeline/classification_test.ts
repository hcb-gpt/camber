import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  classifyCandidate,
  classifyCandidateByRules,
  createClassifierMetrics,
  type GmailFinanceCandidateInput,
} from "./classification.ts";

function makeCandidate(
  overrides: Partial<GmailFinanceCandidateInput> = {},
): GmailFinanceCandidateInput {
  return {
    bodyExcerpt: null,
    fromHeader: '"Vendor" <billing@example.com>',
    matchedClassHints: [],
    matchedProjectAliases: [],
    matchedProjectIds: [],
    matchedProjectNames: [],
    matchedProfileSlugs: ["broad_finance_candidate_net"],
    matchedTargetIds: [],
    matchedTargetTypes: [],
    matchedVendorNames: [],
    snippet: null,
    subject: "Invoice 1042",
    ...overrides,
  };
}

async function withoutOpenAiKey(fn: () => Promise<void>) {
  const previous = Deno.env.get("OPENAI_API_KEY");
  Deno.env.delete("OPENAI_API_KEY");
  try {
    await fn();
  } finally {
    if (previous !== undefined) Deno.env.set("OPENAI_API_KEY", previous);
  }
}

async function withMockClassifierEnv(
  fetchImpl: typeof fetch,
  fn: () => Promise<void>,
) {
  const previousKey = Deno.env.get("OPENAI_API_KEY");
  const previousAttempts = Deno.env.get("GMAIL_FINANCIAL_CLASSIFIER_MAX_ATTEMPTS");
  const previousBackoff = Deno.env.get("GMAIL_FINANCIAL_CLASSIFIER_RETRY_BASE_MS");
  const previousFetch = globalThis.fetch;
  Deno.env.set("OPENAI_API_KEY", "test-openai-key");
  Deno.env.set("GMAIL_FINANCIAL_CLASSIFIER_MAX_ATTEMPTS", "2");
  Deno.env.set("GMAIL_FINANCIAL_CLASSIFIER_RETRY_BASE_MS", "0");
  globalThis.fetch = fetchImpl;
  try {
    await fn();
  } finally {
    if (previousKey === undefined) Deno.env.delete("OPENAI_API_KEY");
    else Deno.env.set("OPENAI_API_KEY", previousKey);
    if (previousAttempts === undefined) Deno.env.delete("GMAIL_FINANCIAL_CLASSIFIER_MAX_ATTEMPTS");
    else Deno.env.set("GMAIL_FINANCIAL_CLASSIFIER_MAX_ATTEMPTS", previousAttempts);
    if (previousBackoff === undefined) Deno.env.delete("GMAIL_FINANCIAL_CLASSIFIER_RETRY_BASE_MS");
    else Deno.env.set("GMAIL_FINANCIAL_CLASSIFIER_RETRY_BASE_MS", previousBackoff);
    globalThis.fetch = previousFetch;
  }
}

Deno.test("classifyCandidateByRules rejects obvious operational noise", () => {
  const classification = classifyCandidateByRules(makeCandidate({
    fromHeader: '"Zapier Alerts" <alerts@zapier.com>',
    subject: "Zapier Alerts: one of your zaps has been paused",
  }));

  assertEquals(classification?.docType, "noise");
  assertEquals(classification?.decision, "reject");
  assertEquals(classification?.decisionReason, "rules_noise_fastpath");
});

Deno.test("classifyCandidateByRules routes invoice-like mail without affinity to review", () => {
  const classification = classifyCandidateByRules(makeCandidate({
    bodyExcerpt: "Amount Due: $12,500.00",
    subject: "QuickBooks: Invoice 1042 for Winship",
  }));

  assertEquals(classification?.docType, "vendor_invoice");
  assertEquals(classification?.decision, "review");
  assertStringIncludes(String(classification?.decisionReason), "affinity_gate_review");
});

Deno.test("classifyCandidateByRules accepts invoice-like mail when project affinity is present", () => {
  const classification = classifyCandidateByRules(makeCandidate({
    bodyExcerpt: "Amount Due: $12,500.00",
    matchedProjectAliases: ["Winship"],
    matchedProjectIds: ["11111111-1111-4111-8111-111111111111"],
    matchedProjectNames: ["Winship Residence"],
    matchedVendorNames: ["Grounded Siteworks"],
    subject: "QuickBooks: Invoice 1042 for Winship",
  }));

  assertEquals(classification?.docType, "vendor_invoice");
  assertEquals(classification?.decision, "accept_extract");
});

Deno.test("classifyCandidateByRules does not treat Heartwood-only vendor affinity as extractable", () => {
  const classification = classifyCandidateByRules(makeCandidate({
    bodyExcerpt: "Amount Due: $95.00",
    matchedProjectIds: [],
    matchedTargetIds: ["target-1"],
    matchedTargetTypes: ["vendor_correspondence"],
    matchedVendorNames: ["Heartwood Custom Builders"],
    subject: "Your Picsart Invoice",
  }));

  assertEquals(classification?.docType, "vendor_invoice");
  assertEquals(classification?.decision, "review");
  assertStringIncludes(String(classification?.decisionReason), "affinity_gate_review");
});

Deno.test("classifyCandidateByRules classifies pay apps and draw requests", () => {
  const payApp = classifyCandidateByRules(makeCandidate({
    matchedProjectAliases: ["Carter"],
    matchedProjectIds: ["22222222-2222-4222-8222-222222222222"],
    subject: "Application for Payment - AIA G702",
  }));
  const drawRequest = classifyCandidateByRules(makeCandidate({
    matchedProjectAliases: ["Carter"],
    matchedProjectIds: ["22222222-2222-4222-8222-222222222222"],
    subject: "Draw request for Carter job",
  }));

  assertEquals(payApp?.docType, "client_pay_app");
  assertEquals(payApp?.decision, "accept_extract");
  assertEquals(drawRequest?.docType, "client_draw_request");
  assertEquals(drawRequest?.decision, "accept_extract");
});

Deno.test("classifyCandidateByRules routes tax forms to accept_non_extract", () => {
  const classification = classifyCandidateByRules(makeCandidate({
    subject: "Updated W-9 attached",
  }));

  assertEquals(classification?.docType, "tax_form");
  assertEquals(classification?.decision, "accept_non_extract");
});

Deno.test("classifyCandidate falls back to review when classifier is unavailable", async () => {
  await withoutOpenAiKey(async () => {
    const warnings: string[] = [];
    const classification = await classifyCandidate(
      makeCandidate({
        matchedProfileSlugs: ["vendor_platform_exception_path"],
        matchedProjectAliases: [],
        matchedProjectIds: [],
        matchedProjectNames: [],
        matchedTargetIds: [],
        matchedTargetTypes: [],
        matchedVendorNames: [],
        subject: "Need this looked at",
        bodyExcerpt: "Please review this thread when you can.",
      }),
      warnings,
    );

    assertEquals(classification.docType, "unknown");
    assertEquals(classification.decision, "review");
    assertStringIncludes(classification.decisionReason, "fallback_review");
    assertEquals(warnings.includes("gmail_finance_classifier_missing_openai_key"), true);
  });
});

Deno.test("classifyCandidate retries retryable LLM failures and records metrics", async () => {
  let callCount = 0;
  await withMockClassifierEnv(() => {
    callCount++;
    if (callCount === 1) {
      return Promise.resolve(new Response("rate limited", { status: 429 }));
    }
    return Promise.resolve(new Response(JSON.stringify({
      choices: [{
        message: {
          content: JSON.stringify({
            decision: "accept_extract",
            decision_reason: "llm_invoice",
            doc_type: "vendor_invoice",
            finance_relevance_score: 0.91,
            signals: ["invoice"],
          }),
        },
      }],
    }), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    }));
  }, async () => {
    const warnings: string[] = [];
    const metrics = createClassifierMetrics();
    const classification = await classifyCandidate(
      makeCandidate({
        bodyExcerpt: "Please review the attached billing package for Winship.",
        matchedProjectAliases: ["Winship"],
        matchedProjectIds: ["11111111-1111-4111-8111-111111111111"],
        matchedProjectNames: ["Winship Residence"],
        matchedVendorNames: ["Grounded Siteworks"],
        subject: "Billing package for Winship",
      }),
      warnings,
      metrics,
    );

    assertEquals(callCount, 2);
    assertEquals(classification.decision, "accept_extract");
    assertEquals(metrics.retries, 1);
    assertEquals(metrics.httpFailures, 1);
    assertEquals(metrics.successes, 1);
    assertEquals(warnings.includes("gmail_finance_classifier_retry_http_429:attempt_1"), true);
  });
});

Deno.test("classifyCandidate records parse failures and falls back to review", async () => {
  await withMockClassifierEnv(() =>
    Promise.resolve(new Response(JSON.stringify({
      choices: [{
        message: {
          content: "{ definitely not valid json",
        },
      }],
    }), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    })), async () => {
    const warnings: string[] = [];
    const metrics = createClassifierMetrics();
    const classification = await classifyCandidate(
      makeCandidate({
        matchedProfileSlugs: ["vendor_platform_exception_path"],
        subject: "Need this looked at",
        bodyExcerpt: "Please review this thread when you can.",
      }),
      warnings,
      metrics,
    );

    assertEquals(classification.decision, "review");
    assertEquals(classification.docType, "unknown");
    assertEquals(metrics.parseFailures, 1);
    assertEquals(metrics.fallbackReviews, 1);
    assertEquals(warnings.some((warning) => warning.startsWith("gmail_finance_classifier_parse_failed:")), true);
  });
});
