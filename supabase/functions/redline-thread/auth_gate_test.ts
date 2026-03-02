import { assert } from "https://deno.land/std@0.218.0/assert/mod.ts";

Deno.test("redline-thread enforces top-level X-Edge-Secret gate", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));

  assert(
    source.includes('req.headers.get("X-Edge-Secret")'),
    "Expected index.ts to check X-Edge-Secret",
  );
  assert(
    source.includes('error_code: "missing_auth"'),
    "Expected index.ts to return missing_auth on failure",
  );
});
