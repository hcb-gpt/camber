import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { buildReviewResolutionPatch, validateResolutionAction } from "./review_resolution.ts";

Deno.test("validateResolutionAction accepts valid actions", () => {
  assertEquals(validateResolutionAction("promote"), true);
  assertEquals(validateResolutionAction("reject"), true);
  assertEquals(validateResolutionAction("skip"), true);
});

Deno.test("validateResolutionAction rejects invalid actions", () => {
  assertEquals(validateResolutionAction("invalid"), false);
  assertEquals(validateResolutionAction(""), false);
  assertEquals(validateResolutionAction(null as unknown as string), false);
});

Deno.test("buildReviewResolutionPatch for promote", () => {
  const patch = buildReviewResolutionPatch("promote");
  assertEquals(patch.decision, "accept_extract");
  assertEquals(patch.review_state, "resolved");
  assertEquals(patch.review_resolution, "accept_extract");
  assertEquals(typeof patch.review_resolved_at_utc, "string");
});

Deno.test("buildReviewResolutionPatch for reject", () => {
  const patch = buildReviewResolutionPatch("reject");
  assertEquals(patch.decision, "reject");
  assertEquals(patch.review_state, "resolved");
  assertEquals(patch.review_resolution, "reject");
});

Deno.test("buildReviewResolutionPatch for skip", () => {
  const patch = buildReviewResolutionPatch("skip");
  assertEquals(patch.decision, "review");
  assertEquals(patch.review_state, "resolved");
  assertEquals(patch.review_resolution, "skip");
});
