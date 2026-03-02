import { assert } from "https://deno.land/std@0.218.0/assert/mod.ts";

Deno.test("redline-thread repair endpoint enforces an auth gate", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));

  assert(
    /async function handleRepair[\s\S]*requireEdgeSecret\(req/.test(source),
    "Expected handleRepair to call requireEdgeSecret(req, ...)",
  );
});

