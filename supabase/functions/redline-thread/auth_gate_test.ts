import { assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import { runTopLevelEdgeSecretProbe } from "./auth_gate.ts";

Deno.test("top-level gate rejects missing X-Edge-Secret", async () => {
  const req = new Request("https://example.test/functions/v1/redline-thread?action=contacts");
  const resp = runTopLevelEdgeSecretProbe(req, "expected-secret");
  const body = await resp.json();

  assertEquals(resp.status, 401);
  assertEquals(body.error_code, "missing_auth");
});

Deno.test("top-level gate allows valid X-Edge-Secret and source", async () => {
  const req = new Request("https://example.test/functions/v1/redline-thread?action=contacts", {
    headers: {
      "X-Edge-Secret": "expected-secret",
      "X-Source": "redline_ios",
    },
  });
  const resp = runTopLevelEdgeSecretProbe(req, "expected-secret");
  const body = await resp.json();

  assertEquals(resp.status, 200);
  assertEquals(body.ok, true);
});
