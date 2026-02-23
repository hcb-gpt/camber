import { assertEquals, assertStringIncludes } from "jsr:@std/assert";
import { applyNameVsContentGuardrail } from "./name_vs_content_guardrail.ts";

Deno.test("name-vs-content guardrail: overrides to evidence-leading candidate on large delta", () => {
  const out = applyNameVsContentGuardrail({
    decision: "assign",
    project_id: "skelton",
    confidence: 0.78,
    reasoning: "Model preferred named project mention.",
    candidates: [
      {
        project_id: "permar",
        evidence: {
          source_strength: 0.95,
          affinity_weight: 0.2,
          alias_matches: [],
          assigned: false,
        },
      },
      {
        project_id: "skelton",
        evidence: {
          source_strength: 0.1,
          affinity_weight: 0.05,
          alias_matches: [],
          assigned: false,
        },
      },
    ],
  });

  assertEquals(out.applied, true);
  assertEquals(out.project_id, "permar");
  assertEquals(out.decision, "assign");
  assertEquals(out.reason_code, "name_vs_content_weighting_override");
  assertStringIncludes(out.reasoning, "name_vs_content_guardrail");
  assertEquals(out.from_project_id, "skelton");
  assertEquals(out.to_project_id, "permar");
});

Deno.test("name-vs-content guardrail: no-op when chosen is already top evidence candidate", () => {
  const out = applyNameVsContentGuardrail({
    decision: "assign",
    project_id: "permar",
    confidence: 0.82,
    reasoning: "Already on top evidence candidate.",
    candidates: [
      {
        project_id: "permar",
        evidence: {
          source_strength: 0.88,
          affinity_weight: 0.2,
          alias_matches: [{}, {}],
          assigned: true,
        },
      },
      {
        project_id: "skelton",
        evidence: {
          source_strength: 0.2,
          affinity_weight: 0.05,
          alias_matches: [],
          assigned: false,
        },
      },
    ],
  });

  assertEquals(out.applied, false);
  assertEquals(out.project_id, "permar");
  assertEquals(out.decision, "assign");
});

Deno.test("name-vs-content guardrail: no-op when confidence delta is below threshold", () => {
  const out = applyNameVsContentGuardrail({
    decision: "assign",
    project_id: "proj-b",
    confidence: 0.79,
    reasoning: "Close candidates.",
    candidates: [
      {
        project_id: "proj-a",
        evidence: {
          source_strength: 0.78,
          affinity_weight: 0.2,
          alias_matches: [{}],
          assigned: false,
        },
      },
      {
        project_id: "proj-b",
        evidence: {
          source_strength: 0.7,
          affinity_weight: 0.2,
          alias_matches: [{}],
          assigned: false,
        },
      },
    ],
  });

  assertEquals(out.applied, false);
  assertEquals(out.project_id, "proj-b");
});

Deno.test("name-vs-content guardrail: switches to review when winner is medium confidence", () => {
  const out = applyNameVsContentGuardrail({
    decision: "assign",
    project_id: "proj-b",
    confidence: 0.76,
    reasoning: "Model selected low-evidence project.",
    candidates: [
      {
        project_id: "proj-a",
        evidence: {
          source_strength: 0.68,
          affinity_weight: 0.1,
          alias_matches: [],
          assigned: false,
        },
      },
      {
        project_id: "proj-b",
        evidence: {
          source_strength: 0.1,
          affinity_weight: 0.05,
          alias_matches: [],
          assigned: false,
        },
      },
    ],
  });

  assertEquals(out.applied, true);
  assertEquals(out.project_id, "proj-a");
  assertEquals(out.decision, "review");
});
