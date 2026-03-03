import { assert } from "https://deno.land/std@0.218.0/assert/mod.ts";

Deno.test("bootstrap-review canonicalizes write auth failures before handler dispatch", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  const routerStart = source.indexOf("Deno.serve");
  assert(routerStart >= 0, "Expected bootstrap-review index.ts to define a Deno.serve router");

  const router = source.slice(routerStart);

  const gateIdx = router.indexOf("Write actions require X-Edge-Secret");
  assert(
    gateIdx >= 0,
    "Expected a write-action auth gate that requires X-Edge-Secret",
  );
  assert(
    router.includes('!topLevelAuthResult.ok || topLevelAuthResult.auth !== "edge_secret"'),
    "Expected gate to canonicalize missing/invalid auth and reject anon bearer",
  );
  assert(
    router.includes('const isWriteAction = req.method === "POST"'),
    "Expected explicit write-action predicate",
  );
  assert(
    router.includes('(action === "resolve" || action === "dismiss" || action === "undo")'),
    "Expected write-action predicate to cover resolve/dismiss/undo",
  );
  assert(
    router.includes('"error_code": "invalid_auth"') || router.includes('error_code: "invalid_auth"'),
    "Expected invalid_auth error_code for rejected writes",
  );
  assert(
    router.includes("Write actions require X-Edge-Secret") && router.includes("403"),
    "Expected canonical 403 write auth message",
  );

  const resolveDispatchIdx = router.indexOf("return await handleResolve", gateIdx);
  assert(resolveDispatchIdx > gateIdx, "Expected resolve handler dispatch after write gate");
  const dismissDispatchIdx = router.indexOf("return await handleDismiss", gateIdx);
  assert(dismissDispatchIdx > gateIdx, "Expected dismiss handler dispatch after write gate");
  const undoDispatchIdx = router.indexOf("return await handleUndo", gateIdx);
  assert(undoDispatchIdx > gateIdx, "Expected undo handler dispatch after write gate");
});
