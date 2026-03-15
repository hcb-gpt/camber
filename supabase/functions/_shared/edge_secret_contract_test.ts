import { assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import { authorizeEdgeSecretRequest, buildEdgeSecretHealthSnapshot } from "./edge_secret_contract.ts";

function makeReq(secret?: string): Request {
  return new Request("https://example.test/functions/v1/edge", {
    headers: secret ? { "X-Edge-Secret": secret } : {},
  });
}

Deno.test("edge secret contract: missing header returns edge_secret_missing", () => {
  const result = authorizeEdgeSecretRequest(
    makeReq(),
    { EDGE_SHARED_SECRET: "current-secret" },
  );
  assertEquals(result.ok, false);
  if (result.ok) throw new Error("expected auth failure");
  assertEquals(result.status, 401);
  assertEquals(result.error_code, "edge_secret_missing");
});

Deno.test("edge secret contract: bad secret denied with invalid_edge_secret", () => {
  const result = authorizeEdgeSecretRequest(
    makeReq("bad-secret"),
    { EDGE_SHARED_SECRET: "current-secret" },
  );
  assertEquals(result.ok, false);
  if (result.ok) throw new Error("expected auth failure");
  assertEquals(result.status, 403);
  assertEquals(result.error_code, "invalid_edge_secret");
});

Deno.test("edge secret contract: current secret accepted", () => {
  const result = authorizeEdgeSecretRequest(
    makeReq("current-secret"),
    { EDGE_SHARED_SECRET: "current-secret" },
  );
  assertEquals(result.ok, true);
  if (!result.ok) throw new Error("expected auth success");
  assertEquals(result.status, 200);
  assertEquals(result.matched_slot, "current");
});

Deno.test("edge secret contract: rotation overlap accepts next secret before expiry", () => {
  const now = Date.parse("2026-03-04T00:00:00Z");
  const result = authorizeEdgeSecretRequest(
    makeReq("next-secret"),
    {
      EDGE_SHARED_SECRET: "current-secret",
      EDGE_SHARED_SECRET_NEXT: "next-secret",
      EDGE_SHARED_SECRET_NEXT_EXPIRES_AT_UTC: "2026-03-05T00:00:00Z",
    },
    now,
  );
  assertEquals(result.ok, true);
  if (!result.ok) throw new Error("expected auth success");
  assertEquals(result.status, 200);
  assertEquals(result.matched_slot, "next");
});

Deno.test("edge secret contract: expired rotation denies next secret with edge_secret_drift", () => {
  const now = Date.parse("2026-03-06T00:00:00Z");
  const result = authorizeEdgeSecretRequest(
    makeReq("next-secret"),
    {
      EDGE_SHARED_SECRET: "current-secret",
      EDGE_SHARED_SECRET_NEXT: "next-secret",
      EDGE_SHARED_SECRET_NEXT_EXPIRES_AT_UTC: "2026-03-05T00:00:00Z",
    },
    now,
  );
  assertEquals(result.ok, false);
  if (result.ok) throw new Error("expected auth failure");
  assertEquals(result.status, 403);
  assertEquals(result.error_code, "edge_secret_drift");
});

Deno.test("edge secret contract health reports legacy drift without exposing secret values", () => {
  const snapshot = buildEdgeSecretHealthSnapshot({
    EDGE_SHARED_SECRET: "current-secret",
    ZAPIER_INGEST_SECRET: "legacy",
  });
  assertEquals(snapshot.contract_status, "drift");
  assertEquals(snapshot.legacy_secret_envs_set.ZAPIER_INGEST_SECRET, true);
  assertEquals("EDGE_SHARED_SECRET" in (snapshot as Record<string, unknown>), false);
});
