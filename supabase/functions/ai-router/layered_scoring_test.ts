import { assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import {
  buildSnapshotsFromScores,
  chooseDecisionFromScores,
  combineProjectScores,
  evaluateTranscriptSignal,
  normalizeModelCandidateScores,
} from "./layered_scoring.ts";

Deno.test("normalizeModelCandidateScores dedupes and keeps the strongest score", () => {
  const scores = normalizeModelCandidateScores(
    [
      { project_id: "a", confidence: 0.4 },
      { project_id: "a", confidence: 0.6 },
      { project_id: "b", confidence: 0.3 },
    ],
    null,
    null,
  );

  assertEquals(scores, [
    { project_id: "a", confidence: 0.6, anchor_type: null },
    { project_id: "b", confidence: 0.3, anchor_type: null },
  ]);
});

Deno.test("evaluateTranscriptSignal assigns when top score is 2x runner-up", () => {
  const result = evaluateTranscriptSignal([
    { project_id: "a", confidence: 0.62 },
    { project_id: "b", confidence: 0.3 },
  ], { min_confidence: 0.5, review_threshold: 0.25 });

  assertEquals(result.project_id, "a");
  assertEquals(result.decision, "assign");
  assertEquals(result.runner_up_confidence, 0.3);
});

Deno.test("combineProjectScores boosts confidence when multiple layers agree", () => {
  const combined = combineProjectScores([
    { project_id: "a", confidence: 0.6, layer: "transcript", rule_name: "span_model_direct" },
    { project_id: "a", confidence: 0.7, layer: "same_day", rule_name: "site_day_rule" },
    { project_id: "b", confidence: 0.55, layer: "recency", rule_name: "floater_recency_7d" },
  ]);

  assertEquals(combined[0].project_id, "a");
  assertEquals(combined[0].confidence, 0.8);

  const snapshots = buildSnapshotsFromScores({
    scores: combined,
    chosen_project_id: "a",
    chosen_confidence: 0.8,
    chosen_anchor_type: "site_day_rule",
  });

  assertEquals(snapshots.runner_up_confidence, 0.55);
  assertEquals(snapshots.candidate_count, 2);

  const decision = chooseDecisionFromScores(combined, {
    assign_threshold: 0.75,
    review_threshold: 0.25,
  });

  assertEquals(decision, {
    project_id: "a",
    confidence: 0.8,
    decision: "assign",
    runner_up_confidence: 0.55,
  });
});
