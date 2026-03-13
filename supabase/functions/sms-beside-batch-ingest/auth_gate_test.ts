import { assert } from "https://deno.land/std@0.218.0/assert/mod.ts";

Deno.test("sms-beside-batch-ingest fails closed on missing canonical auth contract", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));

  assert(
    source.includes('if (authResult.error_code === "server_misconfigured")'),
    "Expected sms-beside-batch-ingest to fail closed when the canonical edge-secret contract is missing",
  );
  assert(
    source.includes("resolveEdgeSecretContractEnv"),
    "Expected sms-beside-batch-ingest to resolve canonical secret precedence via the shared auth contract",
  );
  assert(
    source.includes("resolveZapierLegacySecretCandidates"),
    "Expected sms-beside-batch-ingest to reuse the shared legacy Zapier secret env resolution",
  );
});
