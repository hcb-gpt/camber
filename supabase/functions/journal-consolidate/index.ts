/**
 * journal-consolidate Edge Function v1.0.3
 * Compares new claims against existing project knowledge to determine relationships
 *
 * @version 1.0.3
 * @date 2026-02-22
 * @purpose D1 deliverable - world model consolidation layer
 *
 * Input: { project_id } or { claim_ids: [...] } or { run_id }
 * Process: LLM compares new claims against existing active claims for the same project
 * Output: updated relationship fields, conflict records, review queue entries
 *
 * v1.0.2: Fix journal_runs status='success' (constraint requires 'success' not 'completed')
 * v1.0.3: Hotfix - remove confirmed-only filter from existing-claims read path.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "v1.0.3";
const PROMPT_VERSION = "journal-consolidate-v1";
const MAX_TOKENS = 4096;
const DEFAULT_MODEL = "claude-sonnet-4-5-20250929";
const DEFAULT_TIMEOUT_MS = 60000;
const MAX_CLAIMS_PER_BATCH = 20;
const MAX_EXISTING_CLAIMS_CONTEXT = 100;

const VALID_RELATIONSHIPS = ["new", "supersedes", "corroborates", "conflicts"] as const;
type Relationship = typeof VALID_RELATIONSHIPS[number];

interface ConsolidationJudgment {
  claim_id: string;
  relationship: Relationship;
  related_claim_id: string | null;
  confidence: number;
  reasoning: string;
  conflict_type: string | null;
  warrant_level_update: string | null;
}

interface ConsolidationResponse {
  judgments: ConsolidationJudgment[];
  cross_project_signals: Array<{
    claim_id: string;
    implied_project_hint: string;
    reasoning: string;
  }>;
}

function stripCodeFences(raw: string): string {
  return (raw || "").replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
}

function parseConsolidationJson(raw: string): ConsolidationResponse {
  const cleaned = stripCodeFences(raw);
  const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
  const jsonStr = jsonMatch ? jsonMatch[0] : cleaned;
  const parsed = JSON.parse(jsonStr);

  const judgments: ConsolidationJudgment[] = [];
  for (const j of (Array.isArray(parsed.judgments) ? parsed.judgments : [])) {
    if (!j.claim_id) continue;
    const relationship = VALID_RELATIONSHIPS.includes(j.relationship) ? j.relationship : "new";
    judgments.push({
      claim_id: String(j.claim_id),
      relationship,
      related_claim_id: j.related_claim_id ? String(j.related_claim_id) : null,
      confidence: typeof j.confidence === "number" ? Math.min(1, Math.max(0, j.confidence)) : 0.5,
      reasoning: String(j.reasoning || "").slice(0, 1000),
      conflict_type: j.conflict_type ? String(j.conflict_type).slice(0, 100) : null,
      warrant_level_update: j.warrant_level_update || null,
    });
  }

  const cross_project_signals = Array.isArray(parsed.cross_project_signals)
    ? parsed.cross_project_signals.map((s: any) => ({
      claim_id: String(s.claim_id || ""),
      implied_project_hint: String(s.implied_project_hint || "").slice(0, 200),
      reasoning: String(s.reasoning || "").slice(0, 500),
    }))
    : [];

  return { judgments, cross_project_signals };
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  let timeoutHandle: number | undefined;
  const timeoutPromise = new Promise<T>((_, reject) => {
    timeoutHandle = setTimeout(() => reject(new Error(`${label}_timeout`)), timeoutMs);
  });
  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    if (timeoutHandle !== undefined) clearTimeout(timeoutHandle);
  }
}

const SYSTEM_PROMPT =
  `You are a construction project knowledge consolidation engine for HCB (Heartwood Custom Builders).

You receive:
1. NEW CLAIMS - recently extracted from phone call transcripts
2. EXISTING CLAIMS - the current active knowledge base for this project

Your job is to compare each new claim against existing claims and determine the relationship.

RELATIONSHIP TYPES:
- "new" - This claim adds genuinely new information not covered by any existing claim.
- "supersedes" - This claim updates or replaces an existing claim. The old information is now outdated. Example: "Framing starts Monday" supersedes "Framing starts next Thursday" if from a later call.
- "corroborates" - This claim confirms or reinforces an existing claim. The same information from a different source or time strengthens confidence. Example: Two different people saying the window order is $47K.
- "conflicts" - This claim directly contradicts an existing claim and both could be current. Example: One call says "permits approved" while another says "still waiting on permits." Conflicts require human review.

JUDGMENT RULES:
1. Temporal priority: Later calls generally supersede earlier calls for the same topic.
2. Same-call duplicates: If a new claim is nearly identical to another claim from the same call, it "corroborates" (likely a duplicate extraction).
3. Be conservative with "conflicts" - only flag true contradictions, not just different aspects of the same topic.
4. For "supersedes", identify WHICH existing claim is superseded (related_claim_id).
5. For "corroborates", identify which existing claim is corroborated and whether warrant_level should increase.
6. For "conflicts", specify the conflict_type: "factual" (different facts), "schedule" (different dates/timelines), "decision" (different decisions), "cost" (different numbers).

CONFIDENCE SCORING (0-1):
- 0.9-1.0: Very clear relationship, no ambiguity
- 0.7-0.89: Likely relationship with minor ambiguity
- 0.5-0.69: Possible relationship, needs context
- Below 0.5: Uncertain, default to "new"

CROSS-PROJECT SIGNALS:
If any new claim mentions another project by name or implies work moving between projects, flag it in cross_project_signals. Example: "We're pulling the framing crew off Moss" implies a cross-project resource move.

OUTPUT FORMAT (JSON only, no markdown):
{
  "judgments": [
    {
      "claim_id": "<uuid of the new claim>",
      "relationship": "new|supersedes|corroborates|conflicts",
      "related_claim_id": "<uuid of the existing claim, or null if new>",
      "confidence": 0.85,
      "reasoning": "Brief explanation of the judgment",
      "conflict_type": null,
      "warrant_level_update": null
    }
  ],
  "cross_project_signals": [
    {
      "claim_id": "<uuid>",
      "implied_project_hint": "name or description of the other project",
      "reasoning": "why this implies a cross-project relationship"
    }
  ]
}`;

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const edgeSecret = req.headers.get("X-Edge-Secret") || req.headers.get("x-edge-secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");

  const secretOk = expectedSecret && edgeSecret === expectedSecret;

  if (!secretOk) {
    return new Response(
      JSON.stringify({ error: "unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    return new Response(
      JSON.stringify({ ok: false, error: "missing_anthropic_key" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const model = Deno.env.get("JOURNAL_CONSOLIDATE_MODEL") || DEFAULT_MODEL;
  const timeoutMs = Number(Deno.env.get("JOURNAL_CONSOLIDATE_TIMEOUT_MS")) || DEFAULT_TIMEOUT_MS;
  const dry_run = body.dry_run === true;

  let run_id = "";

  try {
    let newClaims: any[] = [];
    let project_id: string | null = body.project_id || null;

    if (body.claim_ids && Array.isArray(body.claim_ids) && body.claim_ids.length > 0) {
      const { data, error } = await db
        .from("journal_claims")
        .select("*")
        .in("claim_id", body.claim_ids.slice(0, MAX_CLAIMS_PER_BATCH));
      if (error) throw new Error(`fetch_claims: ${error.message}`);
      newClaims = data || [];
      if (newClaims.length > 0 && !project_id) {
        project_id = newClaims[0].project_id;
      }
    } else if (body.run_id) {
      const { data, error } = await db
        .from("journal_claims")
        .select("*")
        .eq("run_id", body.run_id)
        .eq("relationship", "new")
        .limit(MAX_CLAIMS_PER_BATCH);
      if (error) throw new Error(`fetch_run_claims: ${error.message}`);
      newClaims = data || [];
      if (newClaims.length > 0 && !project_id) {
        project_id = newClaims[0].project_id;
      }
    } else if (project_id) {
      const { data, error } = await db
        .from("journal_claims")
        .select("*")
        .eq("project_id", project_id)
        .eq("relationship", "new")
        .eq("active", true)
        .order("created_at", { ascending: true })
        .limit(MAX_CLAIMS_PER_BATCH);
      if (error) throw new Error(`fetch_project_claims: ${error.message}`);
      newClaims = data || [];
    } else {
      return new Response(
        JSON.stringify({ error: "provide project_id, claim_ids, or run_id" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    if (newClaims.length === 0) {
      return new Response(
        JSON.stringify({ ok: true, claims_processed: 0, reason: "no_claims_to_consolidate", ms: Date.now() - t0 }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    const newClaimIds = newClaims.map((c: any) => c.claim_id);
    const { data: existingClaims, error: existErr } = await db
      .from("journal_claims")
      .select("claim_id, call_id, claim_type, claim_text, epistemic_status, warrant_level, relationship, created_at")
      .eq("project_id", project_id)
      .eq("active", true)
      .not("claim_id", "in", `(${newClaimIds.join(",")})`)
      .order("created_at", { ascending: true })
      .limit(MAX_EXISTING_CLAIMS_CONTEXT);

    if (existErr) throw new Error(`fetch_existing: ${existErr.message}`);

    run_id = crypto.randomUUID();
    if (!dry_run) {
      await db.from("journal_runs").insert({
        run_id,
        call_id: newClaims[0].call_id,
        project_id,
        status: "running",
        config: {
          model,
          prompt_version: PROMPT_VERSION,
          function_version: FUNCTION_VERSION,
          mode: "consolidate",
          new_claim_count: newClaims.length,
          existing_claim_count: (existingClaims || []).length,
        },
      });
    }

    const existingBlock = (existingClaims || []).map((c: any) =>
      `- [${c.claim_id}] (${c.claim_type}, ${c.warrant_level}, call:${c.call_id}, ${c.created_at}) "${c.claim_text}"`
    ).join("\n");

    const newBlock = newClaims.map((c: any) =>
      `- [${c.claim_id}] (${c.claim_type}, ${c.warrant_level}, call:${c.call_id}, ${c.created_at}) "${c.claim_text}"`
    ).join("\n");

    const userPrompt = `PROJECT KNOWLEDGE BASE (${(existingClaims || []).length} existing active claims):
${existingBlock || "(no existing claims - all new claims will be marked 'new')"}

NEW CLAIMS TO CONSOLIDATE (${newClaims.length} claims):
${newBlock}

For each new claim, determine its relationship to the existing knowledge base.
If there are no existing claims, mark everything as "new" with confidence 1.0.`;

    const llmT0 = Date.now();
    const resp = await withTimeout(
      fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": anthropicKey,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model,
          max_tokens: MAX_TOKENS,
          temperature: 0,
          system: SYSTEM_PROMPT,
          messages: [{ role: "user", content: userPrompt }],
        }),
      }),
      timeoutMs,
      "anthropic_consolidate",
    );
    const inference_ms = Date.now() - llmT0;

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`anthropic_${resp.status}: ${errText.slice(0, 200)}`);
    }

    const payload = await resp.json();
    const textBlock = (payload?.content || []).find((b: any) => b?.type === "text");
    const rawContent = textBlock?.text || "";
    const tokens_used = (payload?.usage?.input_tokens || 0) + (payload?.usage?.output_tokens || 0);

    const result = parseConsolidationJson(rawContent);

    let superseded = 0;
    let corroborated = 0;
    let conflicts_detected = 0;
    let remained_new = 0;
    let review_queue_entries = 0;
    let human_override_skips = 0;
    let promotion_result: any = null;

    if (!dry_run) {
      for (const j of result.judgments) {
        if (!newClaimIds.includes(j.claim_id)) continue;

        if (j.relationship === "supersedes" && j.related_claim_id) {
          // Stopline 2 guard: AI must never override human-confirmed claims
          const { data: targetClaim } = await db.from("journal_claims")
            .select("claim_confirmation_state")
            .eq("claim_id", j.related_claim_id)
            .single();
          if (targetClaim?.claim_confirmation_state === "confirmed") {
            console.warn(
              `[journal-consolidate] Stopline 2: skipping AI supersede of human-confirmed claim ${j.related_claim_id} (attempted by new claim ${j.claim_id})`,
            );
            human_override_skips++;
            remained_new++;
            continue;
          }
          await db.from("journal_claims")
            .update({ relationship: "supersedes", supersedes_claim_id: j.related_claim_id })
            .eq("claim_id", j.claim_id);
          await db.from("journal_claims")
            .update({ active: false })
            .eq("claim_id", j.related_claim_id);
          superseded++;
        } else if (j.relationship === "corroborates" && j.related_claim_id) {
          await db.from("journal_claims")
            .update({ relationship: "corroborates" })
            .eq("claim_id", j.claim_id);
          if (j.warrant_level_update && ["high", "medium", "low"].includes(j.warrant_level_update)) {
            // Stopline 2 guard: AI must never modify human-confirmed claims
            const { data: targetClaim } = await db.from("journal_claims")
              .select("claim_confirmation_state")
              .eq("claim_id", j.related_claim_id)
              .single();
            if (targetClaim?.claim_confirmation_state === "confirmed") {
              console.warn(
                `[journal-consolidate] Stopline 2: skipping AI warrant_level update on human-confirmed claim ${j.related_claim_id}`,
              );
              human_override_skips++;
            } else {
              await db.from("journal_claims")
                .update({ warrant_level: j.warrant_level_update })
                .eq("claim_id", j.related_claim_id);
            }
          }
          corroborated++;
        } else if (j.relationship === "conflicts" && j.related_claim_id) {
          await db.from("journal_claims")
            .update({ relationship: "conflicts" })
            .eq("claim_id", j.claim_id);
          await db.from("journal_conflicts").insert({
            run_id,
            claim_a_id: j.related_claim_id,
            claim_b_id: j.claim_id,
            conflict_type: j.conflict_type || "factual",
            resolved: false,
          });
          const claimA = (existingClaims || []).find((c: any) => c.claim_id === j.related_claim_id);
          const claimB = newClaims.find((c: any) => c.claim_id === j.claim_id);
          await db.from("journal_review_queue").insert({
            run_id,
            item_type: "conflict",
            item_id: j.claim_id,
            call_id: claimB?.call_id || null,
            project_id,
            reason: `Conflict detected: ${j.conflict_type || "factual"}`,
            data: {
              claim_a: {
                claim_id: j.related_claim_id,
                claim_text: claimA?.claim_text || "(unknown)",
                call_id: claimA?.call_id || null,
                created_at: claimA?.created_at || null,
              },
              claim_b: {
                claim_id: j.claim_id,
                claim_text: claimB?.claim_text || "(unknown)",
                call_id: claimB?.call_id || null,
                created_at: claimB?.created_at || null,
              },
              conflict_type: j.conflict_type,
              llm_reasoning: j.reasoning,
              confidence: j.confidence,
            },
            status: "pending",
          });
          conflicts_detected++;
          review_queue_entries++;
        } else {
          remained_new++;
        }
      }

      for (const signal of result.cross_project_signals) {
        if (!signal.claim_id) continue;
        const sourceClaim = newClaims.find((c: any) => c.claim_id === signal.claim_id);
        await db.from("journal_review_queue").insert({
          run_id,
          item_type: "cross_project",
          item_id: signal.claim_id,
          call_id: sourceClaim?.call_id || null,
          project_id,
          reason: `Cross-project signal: ${signal.implied_project_hint}`,
          data: {
            claim_id: signal.claim_id,
            claim_text: sourceClaim?.claim_text || "(unknown)",
            implied_project_hint: signal.implied_project_hint,
            reasoning: signal.reasoning,
          },
          status: "pending",
        });
        review_queue_entries++;
      }

      // Use 'success' per journal_runs_status_check constraint
      await db.from("journal_runs").update({
        status: "success",
        completed_at: new Date().toISOString(),
        claims_extracted: newClaims.length,
        conflicts_detected,
        routed_to_review: review_queue_entries,
      }).eq("run_id", run_id);

      // Promotion bridge:
      // When journal-consolidate is triggered from journal-extract (body.run_id),
      // immediately run promotion for that extraction run so belief_claims stays live.
      if (body.run_id) {
        const { data: promoteData, error: promoteErr } = await db.rpc(
          "promote_journal_claims_to_belief",
          { p_run_id: body.run_id },
        );
        if (promoteErr) {
          throw new Error(`promote_belief_failed: ${promoteErr.message}`);
        }
        promotion_result = promoteData || null;
      }
    }

    if (dry_run) {
      for (const j of result.judgments) {
        if (!newClaimIds.includes(j.claim_id)) continue;
        if (j.relationship === "supersedes") superseded++;
        else if (j.relationship === "corroborates") corroborated++;
        else if (j.relationship === "conflicts") conflicts_detected++;
        else remained_new++;
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        run_id: dry_run ? null : run_id,
        project_id,
        claims_processed: newClaims.length,
        existing_claims_in_context: (existingClaims || []).length,
        judgments: { superseded, corroborated, conflicts_detected, remained_new, human_override_skips },
        review_queue_entries: dry_run ? 0 : review_queue_entries,
        cross_project_signals: result.cross_project_signals.length,
        promotion_result: dry_run ? null : promotion_result,
        raw_judgments: dry_run ? result.judgments : undefined,
        model,
        tokens_used,
        inference_ms,
        dry_run,
        prompt_version: PROMPT_VERSION,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e: any) {
    console.error("[journal-consolidate] Error:", e.message);

    if (!body.dry_run && run_id) {
      try {
        await db.from("journal_runs").update({
          status: "failed",
          completed_at: new Date().toISOString(),
          error_message: e.message?.slice(0, 500),
        }).eq("run_id", run_id);
      } catch { /* ignore */ }
    }

    return new Response(
      JSON.stringify({
        ok: false,
        error: e.message,
        function_version: FUNCTION_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
