import { assert } from "https://deno.land/std@0.218.0/assert/mod.ts";

Deno.test("zapier-call-ingest prevents Beside pre-auth bypass", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));

  const authGateIdx = source.indexOf("if (!canonicalValid)");
  const callsRawUpsertIdx = source.indexOf('.from("calls_raw").upsert');

  assert(authGateIdx >= 0, "Expected index.ts to enforce Beside auth gate (canonicalValid)");
  assert(callsRawUpsertIdx >= 0, "Expected index.ts to upsert calls_raw for Beside payloads");
  assert(
    callsRawUpsertIdx > authGateIdx,
    "Expected Beside calls_raw upsert to occur only after auth gate",
  );
});

Deno.test("zapier-call-ingest reuses shared legacy secret candidate resolution", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));

  assert(
    source.includes("resolveZapierLegacySecretCandidates"),
    "Expected zapier-call-ingest to resolve legacy secret candidates via the shared auth contract",
  );
  assert(
    source.includes("legacySecretCandidates.some"),
    "Expected zapier-call-ingest to accept any configured legacy Zapier secret candidate",
  );
});
