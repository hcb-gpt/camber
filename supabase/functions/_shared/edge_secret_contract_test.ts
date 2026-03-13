import { assert, assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";

import {
  authorizeEdgeSecretRequest,
  evaluateEdgeSecretContract,
  resolveEdgeSecretContractEnv,
  resolveZapierLegacySecretCandidates,
} from "./edge_secret_contract.ts";

Deno.test("resolveEdgeSecretContractEnv prefers EDGE_SHARED_SECRET and flags alias drift", () => {
  const env = {
    EDGE_SHARED_SECRET: "canonical-secret",
    X_EDGE_SECRET: "alias-secret",
  };

  const resolved = resolveEdgeSecretContractEnv(env);
  assertEquals(resolved.currentSecret, "canonical-secret");
  assertEquals(resolved.currentSecretSource, "EDGE_SHARED_SECRET");
  assertEquals(resolved.currentAliasMismatch, true);

  const contract = evaluateEdgeSecretContract(env, Date.parse("2026-03-12T18:00:00Z"));
  assertEquals(contract.status, "drift");
  assert(contract.drift_reasons.includes("current_secret_alias_mismatch"));
});

Deno.test("authorizeEdgeSecretRequest rejects alias value when canonical secret differs", () => {
  const env = {
    EDGE_SHARED_SECRET: "canonical-secret",
    X_EDGE_SECRET: "alias-secret",
  };
  const req = new Request("https://example.test", {
    headers: { "X-Edge-Secret": "alias-secret" },
  });

  const result = authorizeEdgeSecretRequest(req, env, Date.parse("2026-03-12T18:00:00Z"));
  assertEquals(result.ok, false);
  if (result.ok) {
    throw new Error("Expected canonical secret mismatch to be rejected");
  }

  assertEquals(result.error_code, "invalid_edge_secret");
  assertEquals(result.current_secret, "canonical-secret");
  assertEquals(result.contract.status, "drift");
});

Deno.test("resolveZapierLegacySecretCandidates keeps both env names and dedupes identical values", () => {
  assertEquals(
    resolveZapierLegacySecretCandidates({
      ZAPIER_INGEST_SECRET: "legacy-a",
      ZAPIER_SECRET: "legacy-b",
    }),
    ["legacy-a", "legacy-b"],
  );

  assertEquals(
    resolveZapierLegacySecretCandidates({
      ZAPIER_INGEST_SECRET: "shared-legacy",
      ZAPIER_SECRET: "shared-legacy",
    }),
    ["shared-legacy"],
  );
});
