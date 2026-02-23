import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { applyNameContentGuardrail } from "./name_content_guardrail.ts";

// ============================================================
// Test: Permar under-attribution pattern (name coincidence)
// ============================================================

Deno.test("downgrades assign when chosen has low crossref and rival has high crossref", () => {
  const result = applyNameContentGuardrail({
    decision: "assign",
    project_id: "winship-id",
    confidence: 0.80,
    reasoning: "Winship name found in transcript.",
    candidates: [
      {
        project_id: "winship-id",
        project_name: "Winship Residence",
        evidence: {
          claim_crossref_score: 0.05,
          source_strength: 0.30,
          alias_matches: [{ term: "Winship", match_type: "client_name" }],
        },
      },
      {
        project_id: "permar-id",
        project_name: "Permar Residence",
        evidence: {
          claim_crossref_score: 0.90,
          source_strength: 1.22,
          alias_matches: [],
        },
      },
    ],
  });

  assertEquals(result.applied, true);
  assertEquals(result.decision, "review");
  assertEquals(result.reason, "name_content_mismatch");
  assertEquals(result.rival_project_id, "permar-id");
});

// ============================================================
// Test: Correct assignment (chosen has adequate crossref)
// ============================================================

Deno.test("does not trigger when chosen project has sufficient crossref", () => {
  const result = applyNameContentGuardrail({
    decision: "assign",
    project_id: "permar-id",
    confidence: 0.85,
    reasoning: "Content matches Permar claim pointers.",
    candidates: [
      {
        project_id: "permar-id",
        project_name: "Permar Residence",
        evidence: {
          claim_crossref_score: 0.45,
          source_strength: 1.22,
          alias_matches: [],
        },
      },
      {
        project_id: "winship-id",
        project_name: "Winship Residence",
        evidence: {
          claim_crossref_score: 0.05,
          source_strength: 0.10,
          alias_matches: [{ term: "Winship", match_type: "client_name" }],
        },
      },
    ],
  });

  assertEquals(result.applied, false);
  assertEquals(result.decision, "assign");
  assertEquals(result.reason, "chosen_crossref_sufficient");
});

// ============================================================
// Test: No rival has high crossref
// ============================================================

Deno.test("does not trigger when no rival has high crossref", () => {
  const result = applyNameContentGuardrail({
    decision: "assign",
    project_id: "winship-id",
    confidence: 0.80,
    reasoning: "Winship name match.",
    candidates: [
      {
        project_id: "winship-id",
        project_name: "Winship Residence",
        evidence: {
          claim_crossref_score: 0.05,
          source_strength: 0.30,
          alias_matches: [{ term: "Winship", match_type: "client_name" }],
        },
      },
      {
        project_id: "skelton-id",
        project_name: "Skelton Residence",
        evidence: {
          claim_crossref_score: 0.15,
          source_strength: 0.10,
          alias_matches: [],
        },
      },
    ],
  });

  assertEquals(result.applied, false);
  assertEquals(result.decision, "assign");
  assertEquals(result.reason, "rival_crossref_low");
});

// ============================================================
// Test: review decisions are not touched
// ============================================================

Deno.test("does not trigger for review decisions", () => {
  const result = applyNameContentGuardrail({
    decision: "review",
    project_id: "winship-id",
    confidence: 0.50,
    reasoning: "Uncertain.",
    candidates: [
      {
        project_id: "winship-id",
        project_name: "Winship Residence",
        evidence: { claim_crossref_score: 0.02, alias_matches: [] },
      },
      {
        project_id: "permar-id",
        project_name: "Permar Residence",
        evidence: { claim_crossref_score: 0.90, alias_matches: [] },
      },
    ],
  });

  assertEquals(result.applied, false);
  assertEquals(result.decision, "review");
  assertEquals(result.reason, "not_assign");
});

// ============================================================
// Test: Single candidate (no rival possible)
// ============================================================

Deno.test("does not trigger with single candidate", () => {
  const result = applyNameContentGuardrail({
    decision: "assign",
    project_id: "winship-id",
    confidence: 0.80,
    reasoning: "Only candidate.",
    candidates: [
      {
        project_id: "winship-id",
        project_name: "Winship Residence",
        evidence: { claim_crossref_score: 0.02, alias_matches: [] },
      },
    ],
  });

  assertEquals(result.applied, false);
  assertEquals(result.reason, "single_candidate");
});

// ============================================================
// Test: gap too small (both have moderate crossref)
// ============================================================

Deno.test("does not trigger when crossref gap is too small", () => {
  const result = applyNameContentGuardrail({
    decision: "assign",
    project_id: "winship-id",
    confidence: 0.80,
    reasoning: "Close call.",
    candidates: [
      {
        project_id: "winship-id",
        project_name: "Winship Residence",
        evidence: { claim_crossref_score: 0.08, alias_matches: [] },
      },
      {
        project_id: "permar-id",
        project_name: "Permar Residence",
        evidence: { claim_crossref_score: 0.30, alias_matches: [] },
      },
    ],
  });

  // Gap is 0.22 >= 0.20 AND chosen < 0.10 AND rival >= 0.30 => DOES trigger
  assertEquals(result.applied, true);
  assertEquals(result.decision, "review");
});

Deno.test("does not trigger when gap is below minimum", () => {
  const result = applyNameContentGuardrail({
    decision: "assign",
    project_id: "winship-id",
    confidence: 0.80,
    reasoning: "Close scores.",
    candidates: [
      {
        project_id: "winship-id",
        project_name: "Winship Residence",
        evidence: { claim_crossref_score: 0.05, alias_matches: [] },
      },
      {
        project_id: "permar-id",
        project_name: "Permar Residence",
        evidence: { claim_crossref_score: 0.20, alias_matches: [] },
      },
    ],
  });

  // Gap is 0.15 < 0.20 minimum -> does NOT trigger
  assertEquals(result.applied, false);
  assertEquals(result.reason, "rival_crossref_low");
});
