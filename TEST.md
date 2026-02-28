# TEST.md — Camber Calls CI Test Strategy

## Test Framework

All tests use **Deno.test** with the built-in Deno test runner.

```bash
# Run all tests
deno test --allow-env --allow-net supabase/functions/

# Run tests for a specific function
deno test --allow-env --allow-net supabase/functions/ai-router/

# Run a single test file
deno test --allow-env supabase/functions/segment-llm/segmentation_guardrails_test.ts
```

## Test Naming Convention

Test files live alongside the code they test, named `<module>_test.ts`:

```
supabase/functions/<function-name>/<module>_test.ts
```

## Existing Test Coverage

| Function | Test File(s) | What's Tested |
|---|---|---|
| `_shared` | `id_guard_test.ts`, `junk_call_prefilter_test.ts`, `llm_json_test.ts` | ID validation, junk filtering, LLM JSON parsing |
| `ai-router` | `id_guardrails_test.ts`, `alias_guardrails_test.ts`, `bizdev_guardrails_test.ts`, `bethany_winship_guardrail_test.ts`, `homeowner_override_gate_test.ts`, `world_model_facts_test.ts`, `rrf_reranker_test.ts`, `rrf_tier_guardrail_test.ts`, `name_content_guardrail_test.ts` | Decision guardrails, alias handling, reranking |
| `context-assembly` | `verb_detection_test.ts`, `match_quality_test.ts`, `alias_system_test.ts`, `homeowner_override_test.ts` | Verb roles, match scoring, alias resolution, overrides |
| `gmail-context-lookup` | `extraction_test.ts` | Email context extraction |
| `morning-manifest-ui` | `view_test.ts` | UI view rendering |
| `process-call` | `phone_lookup_test.ts`, `phone_direction_test.ts` | Phone normalization, direction detection |
| `segment-llm` | `segmentation_guardrails_test.ts` | Channel normalization, quote extraction |

## What to Test

Focus tests on **pure logic** that does not require a live Supabase connection:
- Guardrail functions (threshold checks, validation)
- Data transformation / normalization
- Parsing / extraction utilities
- Decision logic (scoring, ranking, filtering)

Avoid testing in CI:
- Live DB queries (use integration tests with a test project instead)
- LLM calls (non-deterministic, rate-limited)
- External API calls (use mocks or skip in CI)

## CI Gate

Tests run on PR via `deno test`. A failing test blocks merge.
See `scripts/CI_GATES.md` for the full gate checklist.
