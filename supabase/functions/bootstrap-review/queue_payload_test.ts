import { assert } from "https://deno.land/std@0.218.0/assert/mod.ts";

Deno.test("bootstrap-review queue payload coalesces id from review_queue_id", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  const idPattern = /id:\s*rq\.id\s*\?\?\s*rq\.review_queue_id/;

  assert(
    idPattern.test(source),
    "Expected queue mapping to set id via `rq.id ?? rq.review_queue_id`",
  );
});

Deno.test("bootstrap-review queue payload coalesces created_at from queued_at", () => {
  const source = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  const createdAtPattern = /created_at:\s*rq\.created_at\s*\?\?\s*rq\.queued_at/;

  assert(
    createdAtPattern.test(source),
    "Expected queue mapping to set created_at via `rq.created_at ?? rq.queued_at`",
  );
});

