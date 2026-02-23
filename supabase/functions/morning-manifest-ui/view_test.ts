import { assert, assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import { renderManifestHtml, type ManifestResponse, wantsHtmlResponse } from "./view.ts";

function samplePayload(): ManifestResponse {
  return {
    ok: true,
    function_version: "v0.test",
    generated_at: "2026-02-23T01:30:00Z",
    ms: 42,
    user: {
      id: "user_1",
      email: "test@example.com",
      role: "authenticated",
    },
    summary: {
      project_row_count: 2,
      pending_review_count: 13,
      review_queue_warning: null,
    },
    manifest: [
      {
        project_name: "Low Queue Project",
        project_id: "proj_low",
        new_calls: 9,
        new_journal_entries: 2,
        new_belief_claims: 1,
        new_striking_signals: 0,
        pending_reviews: 1,
        newly_resolved_reviews: 5,
      },
      {
        project_name: "High Queue <Project>",
        project_id: "proj_high",
        new_calls: 1,
        new_journal_entries: 3,
        new_belief_claims: 4,
        new_striking_signals: 2,
        pending_reviews: 12,
        newly_resolved_reviews: 0,
      },
    ],
  };
}

Deno.test("wantsHtmlResponse: format=html forces HTML", () => {
  const req = new Request("https://example.test/functions/v1/morning-manifest-ui?format=html");
  const url = new URL(req.url);
  assertEquals(wantsHtmlResponse(req, url), true);
});

Deno.test("wantsHtmlResponse: format=json overrides HTML Accept header", () => {
  const req = new Request("https://example.test/functions/v1/morning-manifest-ui?format=json", {
    headers: { Accept: "text/html,application/json" },
  });
  const url = new URL(req.url);
  assertEquals(wantsHtmlResponse(req, url), false);
});

Deno.test("wantsHtmlResponse: HTML Accept header enables HTML when no format given", () => {
  const req = new Request("https://example.test/functions/v1/morning-manifest-ui", {
    headers: { Accept: "text/html" },
  });
  const url = new URL(req.url);
  assertEquals(wantsHtmlResponse(req, url), true);
});

Deno.test("renderManifestHtml: sorts by pending reviews and escapes HTML entities", () => {
  const html = renderManifestHtml(samplePayload(), 50);

  const highIndex = html.indexOf("High Queue &lt;Project&gt;");
  const lowIndex = html.indexOf("Low Queue Project");
  assert(highIndex >= 0);
  assert(lowIndex >= 0);
  assert(highIndex < lowIndex);
});

Deno.test("renderManifestHtml: renders empty-state message", () => {
  const payload = samplePayload();
  payload.manifest = [];
  payload.summary.project_row_count = 0;

  const html = renderManifestHtml(payload, 50);
  assert(html.includes("No manifest rows returned."));
});
