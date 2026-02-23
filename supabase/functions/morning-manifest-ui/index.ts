/**
 * morning-manifest-ui Edge Function v0.4.0
 *
 * Browser-callable endpoint for Morning Manifest UI.
 * - verify_jwt=true (gateway)
 * - validates bearer token and returns manifest rows + queue summary
 * - includes per-call, per-span attribution details (10 most recent)
 * - v0.4.0: review_queue rollup from v_review_queue_summary,
 *   v_review_queue_reason_daily, v_review_queue_top_interactions
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type AnchorEntry,
  type CallAttributionDetail,
  type CandidateEntry,
  type ManifestResponse,
  renderManifestHtml,
  type ReviewQueueReasonDaily,
  type ReviewQueueSummary,
  type ReviewQueueTopInteraction,
  type SpanDetail,
  wantsHtmlResponse,
} from "./view.ts";

const FUNCTION_VERSION = "v0.4.0";

const BASE_HEADERS = {
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

Deno.serve(async (req: Request) => {
  const startedAt = Date.now();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: BASE_HEADERS });
  }

  if (req.method !== "GET") {
    return json(405, {
      ok: false,
      error: "method_not_allowed",
      detail: "Use GET",
    });
  }

  try {
    const authHeader = req.headers.get("authorization") ?? req.headers.get("Authorization") ?? "";
    const token = extractBearerToken(authHeader);
    if (!token) {
      return json(401, {
        ok: false,
        error: "missing_bearer_token",
        detail: "Authorization: Bearer <jwt> is required",
      });
    }

    const supabaseUrl = mustGetEnv("SUPABASE_URL");
    const serviceRoleKey = mustGetEnv("SUPABASE_SERVICE_ROLE_KEY");

    const db = createClient(supabaseUrl, serviceRoleKey);
    const claims = decodeJwtPayload(token);
    const tokenRole = typeof claims.role === "string" ? claims.role : null;
    const hasSubject = typeof claims.sub === "string" && claims.sub.trim().length > 0;

    let viewer: { id: string; email: string | null; role: string | null } = {
      id: hasSubject ? "" : "service-role",
      email: null,
      role: tokenRole,
    };

    if (hasSubject) {
      const { data: userData, error: userError } = await db.auth.getUser(token);
      if (userError || !userData?.user) {
        return json(401, {
          ok: false,
          error: "invalid_jwt",
          detail: userError?.message ?? "Unable to validate token",
        });
      }
      viewer = {
        id: userData.user.id,
        email: userData.user.email ?? null,
        role: userData.user.role ?? tokenRole,
      };
    } else if (tokenRole !== "service_role") {
      return json(401, {
        ok: false,
        error: "invalid_jwt",
        detail: "token must include sub claim or service_role role",
      });
    }

    const url = new URL(req.url);
    const limit = parseBoundedInt(url.searchParams.get("limit"), 50, 1, 250);
    const wantsHtml = wantsHtmlResponse(req, url);

    const { data: manifestRows, error: manifestError } = await db
      .from("v_morning_manifest")
      .select("*")
      .limit(limit);

    if (manifestError) {
      return json(500, {
        ok: false,
        error: "manifest_query_failed",
        detail: manifestError.message,
      });
    }

    let pendingReviewCount: number | null = null;
    let reviewQueueWarning: string | null = null;
    const { count, error: reviewError } = await db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending");

    if (reviewError) {
      reviewQueueWarning = reviewError.message;
    } else {
      pendingReviewCount = count ?? 0;
    }

    // Review queue rollup views (v0.4.0)
    let reviewQueueRollup: ReviewQueueSummary | null = null;
    let reviewReasonDaily: ReviewQueueReasonDaily[] = [];
    let reviewTopInteractions: ReviewQueueTopInteraction[] = [];

    const { data: rollupRow } = await db
      .from("v_review_queue_summary")
      .select("*")
      .limit(1)
      .maybeSingle();
    if (rollupRow) {
      reviewQueueRollup = rollupRow as unknown as ReviewQueueSummary;
    }

    const { data: reasonRows } = await db
      .from("v_review_queue_reason_daily")
      .select("*")
      .order("day", { ascending: false })
      .limit(30);
    if (reasonRows) {
      reviewReasonDaily = reasonRows as unknown as ReviewQueueReasonDaily[];
    }

    const { data: topRows } = await db
      .from("v_review_queue_top_interactions")
      .select("*")
      .order("pending_count", { ascending: false })
      .limit(20);
    if (topRows) {
      reviewTopInteractions = topRows as unknown as ReviewQueueTopInteraction[];
    }

    // Fetch per-call attribution details (10 most recent)
    let attributionDetails: CallAttributionDetail[] = [];
    try {
      attributionDetails = await fetchAttributionDetails(db);
    } catch (attrErr) {
      console.warn(
        "[morning-manifest-ui] attribution details fetch failed:",
        attrErr instanceof Error ? attrErr.message : String(attrErr),
      );
    }

    const payload: ManifestResponse = {
      ok: true,
      function_version: FUNCTION_VERSION,
      generated_at: new Date().toISOString(),
      ms: Date.now() - startedAt,
      user: viewer,
      summary: {
        project_row_count: manifestRows?.length ?? 0,
        pending_review_count: pendingReviewCount,
        review_queue_warning: reviewQueueWarning,
        review_queue_rollup: reviewQueueRollup,
      },
      manifest: manifestRows ?? [],
      attribution_details: attributionDetails,
      review_queue_reason_daily: reviewReasonDaily,
      review_queue_top_interactions: reviewTopInteractions,
    };

    if (wantsHtml) {
      return html(200, renderManifestHtml(payload, limit));
    }

    return json(200, payload);
  } catch (err) {
    console.error("[morning-manifest-ui] fatal:", err);
    return json(500, {
      ok: false,
      error: "morning_manifest_ui_fatal",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
});

// deno-lint-ignore no-explicit-any
function parseAnchors(raw: any): AnchorEntry[] {
  if (!raw || !Array.isArray(raw)) return [];
  return raw.map((a: Record<string, unknown>) => ({
    quote: String(a.quote ?? a.text ?? ""),
    type: typeof a.type === "string" ? a.type : undefined,
    source: typeof a.source === "string" ? a.source : undefined,
  })).filter((a: AnchorEntry) => a.quote.length > 0);
}

// deno-lint-ignore no-explicit-any
function parseCandidates(raw: any, projectMap: Map<string, string>): CandidateEntry[] {
  if (!raw || !Array.isArray(raw)) return [];
  return raw.map((c: Record<string, unknown>) => {
    const pid = String(c.project_id ?? "");
    return {
      project_id: pid,
      project_name: projectMap.get(pid) ?? pid,
      score: typeof c.score === "number" ? c.score : 0,
      reason: typeof c.reason === "string" ? c.reason : undefined,
    };
  });
}

async function fetchAttributionDetails(
  db: SupabaseClient,
): Promise<CallAttributionDetail[]> {
  // Step 1: Get 10 most recent non-shadow, non-test interaction_ids
  const { data: recentSpans, error: spanErr } = await db
    .from("conversation_spans")
    .select("interaction_id")
    .not("interaction_id", "like", "cll_SHADOW_%")
    .not("interaction_id", "like", "%_TEST_%")
    .order("created_at", { ascending: false })
    .limit(200);

  if (spanErr || !recentSpans || recentSpans.length === 0) {
    console.warn("[morning-manifest-ui] attribution query failed or empty:", spanErr?.message);
    return [];
  }

  // Deduplicate interaction_ids, keep order, limit to 10
  const seen = new Set<string>();
  const interactionIds: string[] = [];
  for (const row of recentSpans) {
    const iid = String(row.interaction_id);
    if (!seen.has(iid)) {
      seen.add(iid);
      interactionIds.push(iid);
      if (interactionIds.length >= 10) break;
    }
  }

  if (interactionIds.length === 0) return [];

  // Step 2: Fetch spans + attributions for those interactions
  const { data: spans, error: spansErr } = await db
    .from("conversation_spans")
    .select(`
      id,
      interaction_id,
      span_index,
      created_at,
      transcript_segment
    `)
    .in("interaction_id", interactionIds)
    .order("span_index", { ascending: true });

  if (spansErr || !spans) {
    console.warn("[morning-manifest-ui] spans fetch failed:", spansErr?.message);
    return [];
  }

  const spanIds = spans.map((s: { id: string }) => s.id);

  const { data: attributions, error: attrErr } = await db
    .from("span_attributions")
    .select(`
      span_id,
      decision,
      confidence,
      reasoning,
      anchors,
      candidates_snapshot,
      applied_project_id
    `)
    .in("span_id", spanIds);

  if (attrErr) {
    console.warn("[morning-manifest-ui] attributions fetch failed:", attrErr.message);
  }

  // Step 3: Fetch interactions for contact_name / call_date
  const { data: interactions, error: intErr } = await db
    .from("interactions")
    .select("id, contact_name, call_date")
    .in("id", interactionIds);

  if (intErr) {
    console.warn("[morning-manifest-ui] interactions fetch failed:", intErr.message);
  }

  const interactionMap = new Map<string, { contact_name: string; call_date: string }>();
  if (interactions) {
    for (const i of interactions) {
      interactionMap.set(String(i.id), {
        contact_name: String(i.contact_name ?? "Unknown"),
        call_date: String(i.call_date ?? ""),
      });
    }
  }

  // Step 4: Collect all project IDs we need to resolve
  const projectIds = new Set<string>();
  if (attributions) {
    for (const a of attributions) {
      if (a.applied_project_id) projectIds.add(String(a.applied_project_id));
      if (Array.isArray(a.candidates_snapshot)) {
        for (const c of a.candidates_snapshot) {
          if (c && typeof c === "object" && (c as Record<string, unknown>).project_id) {
            projectIds.add(String((c as Record<string, unknown>).project_id));
          }
        }
      }
    }
  }

  const projectMap = new Map<string, string>();
  if (projectIds.size > 0) {
    const { data: projects } = await db
      .from("projects")
      .select("id, name")
      .in("id", [...projectIds]);
    if (projects) {
      for (const p of projects) {
        projectMap.set(String(p.id), String(p.name ?? p.id));
      }
    }
  }

  // Step 5: Build attribution lookup by span_id
  type AttrRow = {
    span_id: string;
    decision: string;
    confidence: number;
    reasoning: string;
    // deno-lint-ignore no-explicit-any
    anchors: any;
    // deno-lint-ignore no-explicit-any
    candidates_snapshot: any;
    applied_project_id: string | null;
  };
  const attrBySpan = new Map<string, AttrRow>();
  if (attributions) {
    for (const a of attributions) {
      attrBySpan.set(String(a.span_id), a as AttrRow);
    }
  }

  // Step 6: Assemble results in interaction_id order
  const results: CallAttributionDetail[] = [];
  for (const iid of interactionIds) {
    const callSpans = spans.filter(
      (s: { interaction_id: string }) => String(s.interaction_id) === iid,
    );
    const info = interactionMap.get(iid) ?? { contact_name: "Unknown", call_date: "" };

    const spanDetails: SpanDetail[] = callSpans.map(
      (s: {
        id: string;
        span_index: number;
        transcript_segment?: string | null;
      }) => {
        const attr = attrBySpan.get(String(s.id));
        const appliedPid = attr ? String(attr.applied_project_id ?? "") : "";
        const rawSeg = typeof s.transcript_segment === "string" ? s.transcript_segment.trim() : "";
        const excerpt = rawSeg.length > 300 ? rawSeg.slice(0, 300) + "..." : rawSeg || null;
        return {
          span_id: s.id,
          span_index: s.span_index,
          project_name: appliedPid ? (projectMap.get(appliedPid) ?? appliedPid) : "Unassigned",
          applied_project_id: appliedPid || null,
          decision: attr ? String(attr.decision ?? "none") : "none",
          confidence: attr ? Number(attr.confidence ?? 0) : 0,
          reasoning: attr ? String(attr.reasoning ?? "") : "",
          anchors: attr ? parseAnchors(attr.anchors) : [],
          candidates: attr ? parseCandidates(attr.candidates_snapshot, projectMap) : [],
          transcript_excerpt: excerpt,
        };
      },
    );

    results.push({
      interaction_id: iid,
      contact_name: info.contact_name,
      call_date: info.call_date,
      span_count: callSpans.length,
      spans: spanDetails,
    });
  }

  return results;
}

function mustGetEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing_env_${name}`);
  return value;
}

function extractBearerToken(header: string): string | null {
  const trimmed = header.trim();
  if (!trimmed) return null;
  const match = /^Bearer\s+(.+)$/i.exec(trimmed);
  if (!match) return null;
  const token = match[1]?.trim();
  return token ? token : null;
}

function parseBoundedInt(raw: string | null, fallback: number, min: number, max: number): number {
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

function decodeJwtPayload(token: string): Record<string, unknown> {
  const parts = token.split(".");
  if (parts.length < 2) return {};

  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const jsonText = atob(padded);
    const parsed = JSON.parse(jsonText);
    return parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: BASE_HEADERS,
  });
}

function html(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: {
      ...BASE_HEADERS,
      "Content-Type": "text/html; charset=utf-8",
    },
  });
}
