import { assert } from "https://deno.land/std@0.218.0/assert/mod.ts";

Deno.test("redline-thread enforces top-level X-Edge-Secret gate", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  const authHeaderIdx = source.indexOf('req.headers.get("X-Edge-Secret")');
  const dbAfterAuthIdx = source.indexOf("const db = createClient", authHeaderIdx);

  assert(authHeaderIdx >= 0, "Expected index.ts to check X-Edge-Secret");
  assert(
    source.includes('error_code: "missing_auth"'),
    "Expected index.ts to return missing_auth on failure",
  );
  assert(
    dbAfterAuthIdx > authHeaderIdx,
    "Expected non-health service-role DB client creation to happen after auth gate",
  );
});
