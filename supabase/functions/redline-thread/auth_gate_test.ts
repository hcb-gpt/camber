import { assert, assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import { runTopLevelEdgeSecretOrAnonKeyProbe, runTopLevelEdgeSecretProbe } from "./auth_gate.ts";

Deno.test("redline-thread keeps auth gate before non-health service-role client create", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  const authCheckIdx = source.indexOf("checkTopLevelEdgeSecret(req)");
  const dbAfterAuthIdx = source.indexOf("const db = createClient", authCheckIdx);

  assert(authCheckIdx >= 0, "Expected index.ts to call checkTopLevelEdgeSecret(req)");
  assert(
    dbAfterAuthIdx > authCheckIdx,
    "Expected non-health service-role DB client creation to happen after auth gate",
  );
});

Deno.test("redline-thread does not allow anon-key bypass for action routes via contact_id param", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));

  assert(
    !source.includes("if (contactIdParam) return true;"),
    "Expected allowAnonKey to NOT whitelist all GETs with contactIdParam (bypass risk)",
  );
  assert(
    source.includes("if (!action && contactIdParam) return true;"),
    "Expected allowAnonKey to only whitelist contactIdParam when no action is present",
  );
});

Deno.test("top-level gate rejects missing X-Edge-Secret", async () => {
  const req = new Request("https://example.test/functions/v1/redline-thread?action=contacts");
  const resp = runTopLevelEdgeSecretProbe(req, "expected-secret", "test-v1");
  const body = await resp.json();

  assertEquals(resp.status, 401);
  assertEquals(body.error_code, "missing_auth");
  assertEquals(body.function_version, "test-v1");
});

Deno.test("top-level gate allows valid X-Edge-Secret and source", async () => {
  const req = new Request("https://example.test/functions/v1/redline-thread?action=contacts", {
    headers: {
      "X-Edge-Secret": "expected-secret",
      "X-Source": "redline_ios",
    },
  });
  const resp = runTopLevelEdgeSecretProbe(req, "expected-secret", "test-v1");
  const body = await resp.json();

  assertEquals(resp.status, 200);
  assertEquals(body.ok, true);
  assertEquals(body.function_version, "test-v1");
});

Deno.test("top-level gate (edge-secret-or-anon) rejects missing auth headers", async () => {
  const req = new Request("https://example.test/functions/v1/redline-thread?action=contacts");
  const resp = await runTopLevelEdgeSecretOrAnonKeyProbe(req, "expected-secret", "expected-anon", undefined, "test-v1");
  const body = await resp.json();

  assertEquals(resp.status, 401);
  assertEquals(body.error_code, "missing_auth");
  assertEquals(body.function_version, "test-v1");
});

Deno.test("top-level gate (edge-secret-or-anon) allows Authorization: Bearer <anonKey>", async () => {
  const req = new Request("https://example.test/functions/v1/redline-thread?action=contacts", {
    headers: {
      Authorization: "Bearer expected-anon",
    },
  });
  const resp = await runTopLevelEdgeSecretOrAnonKeyProbe(req, "expected-secret", "expected-anon", undefined, "test-v1");
  const body = await resp.json();

  assertEquals(resp.status, 200);
  assertEquals(body.ok, true);
  assertEquals(body.auth, "bearer");
  assertEquals(body.function_version, "test-v1");
});

Deno.test("top-level gate (edge-secret-or-anon) rejects junk Bearer tokens", async () => {
  const req = new Request("https://example.test/functions/v1/redline-thread?action=contacts", {
    headers: {
      Authorization: "Bearer foo",
    },
  });
  const resp = await runTopLevelEdgeSecretOrAnonKeyProbe(
    req,
    "expected-secret",
    "expected-anon",
    "https://example.test",
  );
  const body = await resp.json();

  assertEquals(resp.status, 403);
  assertEquals(body.ok, false);
  assertEquals(body.error_code, "invalid_auth");
});

Deno.test("redline-thread allows anon-key for truth_graph action", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  assert(
    source.includes('action === "contacts" || action === "reset_clock" || action === "truth_graph"'),
    "truth_graph MUST be in anon-key whitelist",
  );
});

Deno.test("redline-thread does not allow anon-key bypass for sensitive actions", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  assert(
    !source.includes(
      'action === "contacts" || action === "reset_clock" || action === "truth_graph" || action === "projects"',
    ),
    "projects MUST NOT be in anon-key whitelist",
  );
});
