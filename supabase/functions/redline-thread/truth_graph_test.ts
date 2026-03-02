import { assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import { computeTruthGraph } from "./truth_graph.ts";

function hydratedAll(overrides: Partial<Parameters<typeof computeTruthGraph>[1]> = {}) {
  return {
    calls_raw: true,
    interactions: true,
    conversation_spans: true,
    evidence_events: true,
    span_attributions: true,
    journal_claims: true,
    review_queue: false,
    ...overrides,
  };
}

Deno.test("truth_graph: lane=process-call when interactions missing", () => {
  const out = computeTruthGraph("cll_123", hydratedAll({ interactions: false }));
  assertEquals(out.lane, "process-call");
  assertEquals(out.suggested_repairs[0]?.action, "repair_process_call");
});

Deno.test("truth_graph: lane=segment-call when spans missing", () => {
  const out = computeTruthGraph("cll_123", hydratedAll({ conversation_spans: false }));
  assertEquals(out.lane, "segment-call");
  assertEquals(out.suggested_repairs[0]?.action, "repair_process_call");
});

Deno.test("truth_graph: lane=ai-router when attributions missing", () => {
  const out = computeTruthGraph("cll_123", hydratedAll({ span_attributions: false }));
  assertEquals(out.lane, "ai-router");
  assertEquals(out.suggested_repairs[0]?.action, "repair_ai_router");
});

Deno.test("truth_graph: lane=sms-ingest for sms_thread interactions", () => {
  const out = computeTruthGraph("sms_thread_7065559876_1710000000", hydratedAll({ calls_raw: false }));
  assertEquals(out.lane, "sms-ingest");
  assertEquals(out.suggested_repairs.length, 0);
});
