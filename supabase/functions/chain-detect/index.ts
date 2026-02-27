/**
 * chain-detect Edge Function v1.0.0
 * Detects temporal call chains — clusters of calls from the same contact
 * within a day — and uses LLM to assess chain significance.
 *
 * AI-Forward design: The model judges whether a pattern is meaningful,
 * not threshold heuristics.
 *
 * @version 1.0.0
 * @date 2026-02-09
 * @purpose Temporal clustering layer for the call pipeline
 *
 * DESIGN:
 * - Triggered after process-call or on-demand for backfill
 * - Collects all calls from same contact on same day
 * - Excludes SHADOW/duplicate calls
 * - Feeds temporal data + transcript excerpts to LLM for pattern assessment
 * - Persists to call_chains table
 *
 * AUTH: X-Edge-Secret == EDGE_SHARED_SECRET (internal machine-to-machine)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CHAIN_VERSION = "v1.0.0";
const PROMPT_VERSION = "v1.0.0";
const MODEL_ID = "gpt-4o-mini";
const MAX_TOKENS = 1024;

const jsonHeaders = { "Content-Type": "application/json" };

// ============================================================
// CHAIN PATTERN TYPES
// ============================================================
const VALID_CHAIN_PATTERNS = [
  "crisis_burst", // rapid-fire calls, something is wrong
  "follow_up_sequence", // progressive follow-ups on same topic
  "routine_daily", // normal daily coordination with a regular contact
  "coordination_cluster", // scheduling/logistics across multiple topics
  "escalation_chain", // issue escalating across calls
  "decision_sequence", // building toward a decision across calls
  "single_call", // only one call this day (no chain pattern)
] as const;

type ChainPattern = typeof VALID_CHAIN_PATTERNS[number];

interface ChainAssessment {
  chain_significance: number;
  chain_pattern: ChainPattern;
  chain_assessment: string;
}

// ============================================================
// PROMPT
// ============================================================
const SYSTEM_PROMPT = `You are a temporal pattern analyst for HCB (Heartwood Custom Builders), a construction company.
Your job is to assess call chains — groups of phone calls from the same contact to Chad/Zack within a single day.

You receive:
- Temporal data: how many calls, timing, gaps between calls
- Brief summaries or transcript excerpts from each call in the chain
- Any project attribution data from prior calls

Your job is to ASSESS THE SIGNIFICANCE of this pattern.

PATTERN TYPES (use ONLY these):
- crisis_burst: Rapid-fire calls indicating urgency, something is wrong or needs immediate attention
- follow_up_sequence: Progressive follow-ups on the same topic/issue across calls
- routine_daily: Normal daily coordination with a regular contact, nothing unusual
- coordination_cluster: Scheduling and logistics across multiple topics in one day
- escalation_chain: An issue is escalating in severity across the calls
- decision_sequence: Multiple calls building toward or resolving a decision
- single_call: Only one call this day — no chain pattern to assess

SIGNIFICANCE SCORING:
- 0.0–0.2: Routine. Regular contact, no notable pattern. Single calls or normal check-ins.
- 0.3–0.5: Mildly notable. Multiple calls but on different routine topics.
- 0.6–0.7: Significant. Clear progression across calls, or time-pressure coordination.
- 0.8–1.0: Highly significant. Crisis burst, escalation, or critical decision-making across calls.

IMPORTANT:
- A single call per day is ALWAYS "single_call" with significance 0.1
- 2 calls hours apart on different topics is likely "routine_daily" (0.2-0.3)
- The TIME GAPS matter: 3 calls in 20 minutes is very different from 3 calls over 8 hours
- Attribution to the SAME PROJECT across multiple calls increases significance
- Look at the CONTENT, not just the count

OUTPUT FORMAT (JSON only, no markdown):
{
  "chain_significance": <0.00-1.00>,
  "chain_pattern": "<pattern_type>",
  "chain_assessment": "<2-3 sentence narrative assessment of what this chain means for the project/relationship>"
}`;

function buildUserPrompt(
  contactPhone: string,
  contactName: string | null,
  chainDate: string,
  callCount: number,
  durationMinutes: number,
  avgGapMinutes: number,
  callDetails: Array<{ interaction_id: string; time: string; summary: string | null; project: string | null }>,
): string {
  const detailLines = callDetails.map((c, i) => {
    const projStr = c.project ? ` [Project: ${c.project}]` : "";
    const summaryStr = c.summary ? `\n   Summary: ${c.summary.slice(0, 300)}` : "\n   Summary: (not available)";
    return `  ${i + 1}. ${c.time}${projStr}${summaryStr}`;
  }).join("\n");

  return `CALL CHAIN ANALYSIS:
Contact: ${contactName || contactPhone} (${contactPhone})
Date: ${chainDate}
Total calls: ${callCount}
Time span: ${Math.round(durationMinutes)} minutes (first to last call)
Average gap between calls: ${Math.round(avgGapMinutes)} minutes

Calls in chronological order:
${detailLines}

Assess the significance and pattern of this call chain.`;
}

// ============================================================
// MAIN HANDLER
// ============================================================
Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  // ============================================================
  // AUTH GATE
  // ============================================================
  const edgeSecretHeader = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ ok: false, error: "invalid_json", version: CHAIN_VERSION }),
      { status: 400, headers: jsonHeaders },
    );
  }

  const hasValidEdgeSecret = expectedSecret &&
    edgeSecretHeader === expectedSecret;

  if (!hasValidEdgeSecret) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "unauthorized",
        hint: "Requires X-Edge-Secret matching EDGE_SHARED_SECRET",
        version: CHAIN_VERSION,
      }),
      { status: 401, headers: jsonHeaders },
    );
  }

  // ============================================================
  // INPUT: accept interaction_id OR (contact_phone + chain_date)
  // ============================================================
  const {
    interaction_id,
    contact_phone: inputPhone,
    chain_date: inputDate,
    dry_run = false,
  } = body;

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  let contactPhone: string;
  let chainDate: string;

  if (interaction_id) {
    // Look up the call to get contact phone and date
    const { data: callRow, error: callErr } = await db
      .from("calls_raw")
      .select("other_party_phone, event_at_utc")
      .eq("interaction_id", interaction_id)
      .single();

    if (callErr || !callRow?.other_party_phone || !callRow?.event_at_utc) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: "call_not_found",
          interaction_id,
          version: CHAIN_VERSION,
        }),
        { status: 400, headers: jsonHeaders },
      );
    }

    contactPhone = callRow.other_party_phone;
    chainDate = callRow.event_at_utc.split("T")[0].split(" ")[0];
  } else if (inputPhone && inputDate) {
    contactPhone = inputPhone;
    chainDate = inputDate;
  } else {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "missing_input",
        hint: "Provide interaction_id OR (contact_phone + chain_date)",
        version: CHAIN_VERSION,
      }),
      { status: 400, headers: jsonHeaders },
    );
  }

  // ============================================================
  // COLLECT ALL CALLS FROM SAME CONTACT ON SAME DAY
  // Exclude SHADOW/duplicate/test calls
  // ============================================================
  const { data: dayCalls, error: dayCallsErr } = await db
    .from("calls_raw")
    .select("interaction_id, event_at_utc, other_party_name, summary")
    .eq("other_party_phone", contactPhone)
    .gte("event_at_utc", `${chainDate}T00:00:00Z`)
    .lt("event_at_utc", `${chainDate}T23:59:59Z`)
    .not("interaction_id", "like", "cll_SHADOW%")
    .not("interaction_id", "like", "cll_V3%")
    .not("interaction_id", "like", "debug_%")
    .not("interaction_id", "like", "cll_STABILITY%")
    .not("interaction_id", "like", "cll_V38%")
    .order("event_at_utc", { ascending: true });

  if (dayCallsErr) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "query_failed",
        detail: dayCallsErr.message,
        version: CHAIN_VERSION,
      }),
      { status: 500, headers: jsonHeaders },
    );
  }

  if (!dayCalls || dayCalls.length === 0) {
    return new Response(
      JSON.stringify({
        ok: true,
        contact_phone: contactPhone,
        chain_date: chainDate,
        call_count: 0,
        chain_significance: 0,
        chain_pattern: null,
        chain_assessment: "No calls found for this contact on this date",
        persisted: false,
        version: CHAIN_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: jsonHeaders },
    );
  }

  // ============================================================
  // COMPUTE TEMPORAL DATA
  // ============================================================
  const callCount = dayCalls.length;
  const interactionIds = dayCalls.map((c: any) => c.interaction_id);
  const contactName = dayCalls.find((c: any) => c.other_party_name)?.other_party_name || null;

  const times = dayCalls.map((c: any) => new Date(c.event_at_utc).getTime());
  const firstCallAt = new Date(Math.min(...times)).toISOString();
  const lastCallAt = new Date(Math.max(...times)).toISOString();
  const durationMinutes = (Math.max(...times) - Math.min(...times)) / 60000;

  // Average gap between consecutive calls
  let avgGapMinutes = 0;
  if (callCount > 1) {
    const gaps: number[] = [];
    for (let i = 1; i < times.length; i++) {
      gaps.push((times[i] - times[i - 1]) / 60000);
    }
    avgGapMinutes = gaps.reduce((a, b) => a + b, 0) / gaps.length;
  }

  // ============================================================
  // COLLECT ATTRIBUTION DATA
  // ============================================================
  const { data: attrData } = await db
    .from("interactions")
    .select("interaction_id, project_id, projects:project_id(name)")
    .in("interaction_id", interactionIds)
    .not("project_id", "is", null);

  const projectMap = new Map<string, string>();
  const projectIds: string[] = [];
  if (attrData) {
    for (const row of attrData as any[]) {
      if (row.project_id) {
        projectIds.push(row.project_id);
        const projName = row.projects?.name || row.project_id;
        projectMap.set(row.interaction_id, projName);
      }
    }
  }

  const uniqueProjectIds = [...new Set(projectIds)];

  // Determine dominant project (most frequent)
  let dominantProjectId: string | null = null;
  if (projectIds.length > 0) {
    const freq = new Map<string, number>();
    for (const pid of projectIds) {
      freq.set(pid, (freq.get(pid) || 0) + 1);
    }
    let maxCount = 0;
    for (const [pid, count] of freq) {
      if (count > maxCount) {
        maxCount = count;
        dominantProjectId = pid;
      }
    }
  }

  // ============================================================
  // BUILD CALL DETAILS FOR LLM
  // ============================================================
  const callDetails = dayCalls.map((c: any) => ({
    interaction_id: c.interaction_id,
    time: c.event_at_utc,
    summary: c.summary,
    project: projectMap.get(c.interaction_id) || null,
  }));

  // ============================================================
  // LLM INFERENCE
  // ============================================================
  let assessment: ChainAssessment;
  let tokens_used = 0;
  let inference_ms = 0;
  let model_error = false;

  // Single-call chains: skip LLM, assign directly
  if (callCount === 1) {
    assessment = {
      chain_significance: 0.1,
      chain_pattern: "single_call",
      chain_assessment: `Single call from ${contactName || contactPhone} on ${chainDate}. No chain pattern to assess.`,
    };
  } else {
    try {
      const openaiKey = Deno.env.get("OPENAI_API_KEY");
      if (!openaiKey) throw new Error("config_missing: OPENAI_API_KEY not set");

      const inferenceStart = Date.now();

      const resp = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${openaiKey}`,
        },
        body: JSON.stringify({
          model: MODEL_ID,
          max_tokens: MAX_TOKENS,
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            {
              role: "user",
              content: buildUserPrompt(
                contactPhone,
                contactName,
                chainDate,
                callCount,
                durationMinutes,
                avgGapMinutes,
                callDetails,
              ),
            },
          ],
        }),
      });
      if (!resp.ok) {
        const errText = await resp.text();
        throw new Error(`openai_${resp.status}: ${errText.slice(0, 240)}`);
      }
      const payload = await resp.json();

      inference_ms = Date.now() - inferenceStart;
      tokens_used = (payload?.usage?.prompt_tokens || 0) + (payload?.usage?.completion_tokens || 0);

      const responseText = payload?.choices?.[0]?.message?.content || "";

      let jsonStr = responseText;
      const jsonMatch = responseText.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        jsonStr = jsonMatch[0];
      }

      const parsed = JSON.parse(jsonStr);

      const significance = Math.max(0, Math.min(1, Number(parsed.chain_significance) || 0));
      const pattern = VALID_CHAIN_PATTERNS.includes(parsed.chain_pattern)
        ? parsed.chain_pattern as ChainPattern
        : "routine_daily";

      assessment = {
        chain_significance: significance,
        chain_pattern: pattern,
        chain_assessment: (parsed.chain_assessment || "No assessment provided").slice(0, 1000),
      };
    } catch (e: any) {
      console.error("[chain-detect] Inference error:", e.message);
      model_error = true;

      assessment = {
        chain_significance: 0,
        chain_pattern: "routine_daily",
        chain_assessment: `model_error: ${e.message}`,
      };
    }
  }

  // ============================================================
  // PERSIST TO call_chains
  // ============================================================
  // chain_key: deterministic, one chain per contact per day
  // Use simple concat since MD5 not available in edge runtime
  const chain_key = `${contactPhone}::${chainDate}`;

  let persisted = false;

  if (!dry_run && !model_error) {
    const { error: upsertErr } = await db.from("call_chains").upsert({
      chain_key,
      contact_phone: contactPhone,
      contact_id: null, // resolved downstream or by backfill
      chain_date: chainDate,
      call_count: callCount,
      first_call_at: firstCallAt,
      last_call_at: lastCallAt,
      duration_minutes: Math.round(durationMinutes * 100) / 100,
      avg_gap_minutes: Math.round(avgGapMinutes * 100) / 100,
      interaction_ids: interactionIds,
      attributed_projects: uniqueProjectIds.length > 0 ? uniqueProjectIds : null,
      dominant_project_id: dominantProjectId,
      chain_assessment: assessment.chain_assessment,
      chain_significance: assessment.chain_significance,
      chain_pattern: assessment.chain_pattern,
      model_id: callCount > 1 ? MODEL_ID : null,
      prompt_version: callCount > 1 ? PROMPT_VERSION : null,
      tokens_used: tokens_used || null,
      inference_ms: inference_ms || null,
    }, {
      onConflict: "chain_key",
    });

    if (upsertErr) {
      console.error("[chain-detect] Upsert failed:", upsertErr.message);
    } else {
      persisted = true;
    }
  }

  // ============================================================
  // RESPONSE
  // ============================================================
  return new Response(
    JSON.stringify({
      ok: true,
      chain_key,
      contact_phone: contactPhone,
      contact_name: contactName,
      chain_date: chainDate,
      call_count: callCount,
      interaction_ids: interactionIds,
      first_call_at: firstCallAt,
      last_call_at: lastCallAt,
      duration_minutes: Math.round(durationMinutes * 100) / 100,
      avg_gap_minutes: Math.round(avgGapMinutes * 100) / 100,
      attributed_projects: uniqueProjectIds,
      dominant_project_id: dominantProjectId,
      chain_significance: assessment.chain_significance,
      chain_pattern: assessment.chain_pattern,
      chain_assessment: assessment.chain_assessment,
      persisted,
      model_error,
      dry_run,
      model_id: callCount > 1 ? MODEL_ID : null,
      tokens_used,
      inference_ms,
      version: CHAIN_VERSION,
      ms: Date.now() - t0,
    }),
    { status: 200, headers: jsonHeaders },
  );
});
