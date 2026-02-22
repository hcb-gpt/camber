import { classifyEvidenceTier, rerankCandidates, TIER_WEIGHTS } from "./rrf_reranker.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: expected=${String(expected)} actual=${String(actual)}`);
  }
}

// ============================================================
// classifyEvidenceTier tests
// ============================================================

Deno.test("tier classification: smoking_gun when assigned + strong match + high source_strength", () => {
  const tier = classifyEvidenceTier({
    assigned: true,
    source_strength: 1.5,
    alias_matches: [{ term: "Smith Residence", match_type: "exact_project_name" }],
  });
  assertEquals(tier, "smoking_gun", "should classify as smoking_gun");
});

Deno.test("tier classification: strong when strong match present", () => {
  const tier = classifyEvidenceTier({
    assigned: false,
    source_strength: 0.3,
    alias_matches: [{ term: "123 Main", match_type: "address_fragment" }],
  });
  assertEquals(tier, "strong", "should classify as strong");
});

Deno.test("tier classification: moderate when alias match but weak type", () => {
  const tier = classifyEvidenceTier({
    assigned: false,
    source_strength: 0.1,
    alias_matches: [{ term: "Athens", match_type: "city_or_location" }],
  });
  assertEquals(tier, "moderate", "should classify as moderate");
});

Deno.test("tier classification: weak when only low source_strength", () => {
  const tier = classifyEvidenceTier({
    assigned: false,
    source_strength: 0.05,
    alias_matches: [],
    sources: ["history"],
  });
  assertEquals(tier, "weak", "should classify as weak");
});

Deno.test("tier classification: anti when no positive signal", () => {
  const tier = classifyEvidenceTier({
    assigned: false,
    source_strength: 0,
    alias_matches: [],
  });
  assertEquals(tier, "anti", "should classify as anti");
});

Deno.test("tier classification: respects evidence_tier_label from context-assembly", () => {
  const tier = classifyEvidenceTier({
    evidence_tier_label: "smoking_gun",
    assigned: false,
    source_strength: 0,
    alias_matches: [],
  });
  assertEquals(tier, "smoking_gun", "should use label from context-assembly");
});

Deno.test("tier classification: ignores invalid evidence_tier_label", () => {
  const tier = classifyEvidenceTier({
    evidence_tier_label: "invalid_tier",
    assigned: false,
    source_strength: 0,
    alias_matches: [],
  });
  assertEquals(tier, "anti", "should fall back to computed tier when label is invalid");
});

// ============================================================
// rerankCandidates tests
// ============================================================

Deno.test("reranker: no rrf_score means no reranking", () => {
  const result = rerankCandidates([
    { project_id: "p1", evidence: { source_strength: 1.0, alias_matches: [] } },
    { project_id: "p2", evidence: { source_strength: 0.5, alias_matches: [] } },
  ]);
  assertEquals(result.reranked, false, "should not rerank without rrf_score");
  assertEquals(result.candidates[0].project_id, "p1", "order should be preserved");
});

Deno.test("reranker: candidates sorted by final_score descending", () => {
  const result = rerankCandidates([
    {
      project_id: "p1",
      evidence: {
        rrf_score: 0.5,
        source_strength: 0.1,
        alias_matches: [],
        assigned: false,
      },
    },
    {
      project_id: "p2",
      evidence: {
        rrf_score: 0.3,
        source_strength: 1.5,
        alias_matches: [{ term: "Smith", match_type: "exact_project_name" }],
        assigned: true,
      },
    },
  ]);

  assertEquals(result.reranked, true, "should be reranked");
  // p1: rrf=0.5, tier=weak (no matches, low source), weight=0.5 => final=0.25
  // p2: rrf=0.3, tier=smoking_gun (assigned+strong+high source), weight=5.0 => final=1.5
  assertEquals(result.candidates[0].project_id, "p2", "smoking_gun should rank first");
  assertEquals(result.candidates[1].project_id, "p1", "weak should rank second");
});

Deno.test("reranker: anti tier produces negative final_score", () => {
  const result = rerankCandidates([
    {
      project_id: "p1",
      evidence: {
        rrf_score: 0.5,
        source_strength: 0,
        alias_matches: [],
        assigned: false,
      },
    },
  ]);

  assertEquals(result.reranked, true, "should be reranked");
  assert(result.scores.length === 1, "should have one score entry");
  assertEquals(result.scores[0].tier, "anti", "should be anti tier");
  assert(result.scores[0].final_score < 0, "anti tier should produce negative final_score");
});

Deno.test("reranker: empty candidates handled gracefully", () => {
  const result = rerankCandidates([]);
  assertEquals(result.reranked, false, "should not rerank empty list");
  assertEquals(result.candidates.length, 0, "should return empty list");
});

// Guardrail tests are in rrf_tier_guardrail_test.ts

// ============================================================
// TIER_WEIGHTS validation
// ============================================================

Deno.test("tier weights: all expected tiers are present", () => {
  const expected = ["smoking_gun", "strong", "moderate", "weak", "anti"];
  for (const tier of expected) {
    assert(tier in TIER_WEIGHTS, `TIER_WEIGHTS missing tier: ${tier}`);
  }
});

Deno.test("tier weights: smoking_gun > strong > moderate > weak > anti", () => {
  assert(TIER_WEIGHTS.smoking_gun > TIER_WEIGHTS.strong, "smoking_gun should be > strong");
  assert(TIER_WEIGHTS.strong > TIER_WEIGHTS.moderate, "strong should be > moderate");
  assert(TIER_WEIGHTS.moderate > TIER_WEIGHTS.weak, "moderate should be > weak");
  assert(TIER_WEIGHTS.weak > TIER_WEIGHTS.anti, "weak should be > anti");
  assert(TIER_WEIGHTS.anti < 0, "anti should be negative");
});
