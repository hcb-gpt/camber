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
