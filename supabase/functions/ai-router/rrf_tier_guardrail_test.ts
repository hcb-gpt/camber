import { applyRrfTierGuardrail } from "./rrf_tier_guardrail.ts";

function assertEquals<T>(actual: T, expected: T, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: expected=${String(expected)} actual=${String(actual)}`);
  }
}

// ============================================================
// PASSTHROUGH CASES
// ============================================================

Deno.test("passthrough: null project_id", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: null,
    confidence: 0.90,
    candidates: [],
  });
  assertEquals(result.decision, "assign", "decision unchanged");
  assertEquals(result.downgraded, false, "not downgraded");
  assertEquals(result.boosted, false, "not boosted");
  assertEquals(result.chosen_tier, null, "no tier");
});

Deno.test("passthrough: project not in candidates", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.80,
    candidates: [
      { project_id: "proj-2", evidence: { rrf_score: 0.90, evidence_tier_label: "strong" } },
    ],
  });
  assertEquals(result.decision, "assign", "decision unchanged");
  assertEquals(result.downgraded, false, "not downgraded");
  assertEquals(result.chosen_tier, null, "no tier for missing candidate");
});

Deno.test("passthrough: no tier label on chosen candidate", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.80,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.70 } },
    ],
  });
  assertEquals(result.decision, "assign", "decision unchanged without tier");
  assertEquals(result.downgraded, false, "not downgraded");
  assertEquals(result.chosen_rrf_score, 0.70, "rrf_score still reported");
});

Deno.test("passthrough: unrecognized tier label", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.80,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.50, evidence_tier_label: "unknown_tier" } },
    ],
  });
  assertEquals(result.decision, "assign", "unrecognized tier passes through");
  assertEquals(result.downgraded, false, "not downgraded");
});

Deno.test("passthrough: moderate tier does not change assign", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.80,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.45, evidence_tier_label: "moderate" } },
    ],
  });
  assertEquals(result.decision, "assign", "moderate tier preserves assign");
  assertEquals(result.downgraded, false, "not downgraded");
  assertEquals(result.boosted, false, "not boosted");
  assertEquals(result.chosen_tier, "moderate", "tier reported");
});

Deno.test("passthrough: strong tier does not change assign", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.82,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.70, evidence_tier_label: "strong" } },
    ],
  });
  assertEquals(result.decision, "assign", "strong tier preserves assign");
  assertEquals(result.confidence, 0.82, "confidence unchanged");
  assertEquals(result.chosen_tier, "strong", "tier reported");
});

// ============================================================
// DOWNGRADE CASES
// ============================================================

Deno.test("downgrade: assign + weak tier -> review", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.78,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.20, evidence_tier_label: "weak" } },
    ],
  });
  assertEquals(result.decision, "review", "weak tier downgrades assign to review");
  assertEquals(result.downgraded, true, "downgraded flag set");
  assertEquals(result.reason_code, "rrf_tier_weak_downgrade", "correct reason code");
  assertEquals(result.chosen_tier, "weak", "tier reported");
  assertEquals(result.chosen_rrf_score, 0.20, "rrf score reported");
});

Deno.test("downgrade: assign + anti tier -> review", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.80,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.05, evidence_tier_label: "anti" } },
    ],
  });
  assertEquals(result.decision, "review", "anti tier downgrades assign to review");
  assertEquals(result.downgraded, true, "downgraded flag set");
  assertEquals(result.reason_code, "rrf_tier_anti_downgrade", "correct reason code");
});

Deno.test("no downgrade: review + weak tier stays review", () => {
  const result = applyRrfTierGuardrail({
    decision: "review",
    project_id: "proj-1",
    confidence: 0.55,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.18, evidence_tier_label: "weak" } },
    ],
  });
  assertEquals(result.decision, "review", "already review, stays review");
  assertEquals(result.downgraded, false, "not downgraded (was already review)");
});

Deno.test("no downgrade: none + anti tier stays none", () => {
  const result = applyRrfTierGuardrail({
    decision: "none",
    project_id: "proj-1",
    confidence: 0.20,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.02, evidence_tier_label: "anti" } },
    ],
  });
  assertEquals(result.decision, "none", "none stays none");
  assertEquals(result.downgraded, false, "not downgraded");
});

// ============================================================
// BOOST CASES
// ============================================================

Deno.test("boost: smoking_gun tier raises confidence to 0.85", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.76,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.92, evidence_tier_label: "smoking_gun" } },
    ],
  });
  assertEquals(result.decision, "assign", "assign preserved");
  assertEquals(result.confidence, 0.85, "confidence boosted to 0.85");
  assertEquals(result.boosted, true, "boosted flag set");
  assertEquals(result.reason_code, "rrf_tier_smoking_gun_boost", "correct reason code");
  assertEquals(result.chosen_tier, "smoking_gun", "tier reported");
});

Deno.test("no boost: smoking_gun tier with confidence already >= 0.85", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.92,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.95, evidence_tier_label: "smoking_gun" } },
    ],
  });
  assertEquals(result.decision, "assign", "assign preserved");
  assertEquals(result.confidence, 0.92, "confidence unchanged (already above floor)");
  assertEquals(result.boosted, false, "not boosted (already above floor)");
  assertEquals(result.chosen_tier, "smoking_gun", "tier reported");
});

Deno.test("no boost: smoking_gun on review decision", () => {
  const result = applyRrfTierGuardrail({
    decision: "review",
    project_id: "proj-1",
    confidence: 0.60,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.88, evidence_tier_label: "smoking_gun" } },
    ],
  });
  assertEquals(result.decision, "review", "review preserved");
  assertEquals(result.confidence, 0.85, "confidence still boosted for review");
  assertEquals(result.boosted, true, "boosted flag set");
});

// ============================================================
// EDGE CASES
// ============================================================

Deno.test("edge: empty candidates array", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.80,
    candidates: [],
  });
  assertEquals(result.decision, "assign", "assign unchanged with empty candidates");
  assertEquals(result.chosen_tier, null, "no tier");
});

Deno.test("edge: candidate with null rrf_score", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-1",
    confidence: 0.80,
    candidates: [
      { project_id: "proj-1", evidence: { evidence_tier_label: "strong" } },
    ],
  });
  assertEquals(result.decision, "assign", "assign preserved");
  assertEquals(result.chosen_rrf_score, null, "null rrf_score reported as null");
  assertEquals(result.chosen_tier, "strong", "tier still reported");
});

Deno.test("edge: multiple candidates, correct one selected", () => {
  const result = applyRrfTierGuardrail({
    decision: "assign",
    project_id: "proj-2",
    confidence: 0.78,
    candidates: [
      { project_id: "proj-1", evidence: { rrf_score: 0.90, evidence_tier_label: "smoking_gun" } },
      { project_id: "proj-2", evidence: { rrf_score: 0.12, evidence_tier_label: "weak" } },
      { project_id: "proj-3", evidence: { rrf_score: 0.60, evidence_tier_label: "strong" } },
    ],
  });
  assertEquals(result.decision, "review", "proj-2 is weak, downgraded");
  assertEquals(result.downgraded, true, "downgraded flag set");
  assertEquals(result.chosen_tier, "weak", "correct candidate tier selected");
  assertEquals(result.chosen_rrf_score, 0.12, "correct candidate rrf_score selected");
});
