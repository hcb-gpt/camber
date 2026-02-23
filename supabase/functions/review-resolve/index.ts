/**
 * review-resolve Edge Function
 * Human resolution endpoint for pending review items
 *
 * @version 3.1.0
 * @date 2026-01-31
 * @purpose Close the product loop: human resolves pending item -> SSOT + audit updated
 *
 * IMPLEMENTATION: Calls resolve_review_item() RPC for single-transaction atomicity
 *
 * EXPANDED SCOPE (CHAD decision):
 * - span_attributions: applied_project_id, attribution_lock='human', needs_review=false
 * - review_queue: status='resolved'
 * - override_log: audit row with idempotency_key
 * - scheduler_items: project_id + attribution_status (via interaction, NULL only)
 * - journal_claims: project_id (via call_id/interaction, NULL only)
 *
 * Hard rules:
 * - Never downgrade human lock
 * - Cannot overwrite human-locked span with different project
 * - Idempotency: duplicate resolve = no-op (return success)
 * - Failures must return non-200 + raise exception (txn rollback)
 * - All writes in single transaction (RPC handles this)
 * - Actor verified via supabase.auth.getUser() (NEVER decode JWT manually)
 *
 * AUTH (v3.1.0 fix):
 * - User-facing endpoint: verify_jwt=true + supabase.auth.getUser()
 * - NEVER decode JWT payload via atob - that violates security policy
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface ResolveRequest {
  review_queue_id: string;
  chosen_project_id: string;
  notes?: string;
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  // ========================================
  // 1. VALIDATE REQUEST
  // ========================================
  if (req.method !== "POST") {
    return jsonResponse({ error: "POST only" }, 405);
  }

  let body: ResolveRequest;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const { review_queue_id, chosen_project_id, notes } = body;

  if (!review_queue_id || !isValidUUID(review_queue_id)) {
    return jsonResponse({ error: "missing_or_invalid_review_queue_id" }, 400);
  }
  if (!chosen_project_id || !isValidUUID(chosen_project_id)) {
    return jsonResponse({ error: "missing_or_invalid_chosen_project_id" }, 400);
  }

  // ========================================
  // 2. VERIFY USER VIA SUPABASE AUTH
  // (NEVER decode JWT manually - security policy)
  // ========================================
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return jsonResponse({ error: "missing_authorization_header" }, 401);
  }

  const token = authHeader.replace("Bearer ", "");

  // Create client with user's token to verify it
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      global: {
        headers: { Authorization: `Bearer ${token}` },
      },
    },
  );

  // Verify JWT signature and get user
  const { data: { user }, error: authError } = await userClient.auth.getUser();

  if (authError || !user) {
    console.error("[review-resolve] Auth verification failed:", authError?.message);
    return jsonResponse({
      error: "auth_verification_failed",
      detail: authError?.message || "Invalid or expired token",
    }, 401);
  }

  const user_id = user.id;

  // ========================================
  // 3. INIT SERVICE ROLE DB CLIENT
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ========================================
  // 4. CALL RPC (single transaction)
  // ========================================
  const { data, error } = await db.rpc("resolve_review_item", {
    p_review_queue_id: review_queue_id,
    p_chosen_project_id: chosen_project_id,
    p_notes: notes || null,
    p_user_id: user_id,
  });

  if (error) {
    console.error("[review-resolve] RPC failed:", error.message);

    // Check if it's an SSOT assertion failure (raised exception)
    if (error.message.includes("SSOT_UPDATE_FAILED")) {
      return jsonResponse({
        ok: false,
        error: "ssot_update_failed",
        detail: error.message,
        review_queue_id,
      }, 500);
    }

    return jsonResponse({
      ok: false,
      error: "rpc_failed",
      detail: error.message,
      review_queue_id,
    }, 500);
  }

  // RPC returns jsonb, parse if needed
  const result = typeof data === "string" ? JSON.parse(data) : data;

  if (!result.ok) {
    // RPC returned an error (not found, not pending, human_lock_conflict, etc.)
    let status = 400;
    if (result.error === "review_queue_item_not_found") status = 404;
    if (result.error === "missing_user_id") status = 401;
    if (result.error === "human_lock_conflict") status = 409;

    return jsonResponse({ ...result, ms: Date.now() - t0 }, status);
  }

  // Keep contamination-control state in sync for claims tied to this resolved span.
  if (result.span_id && isValidUUID(String(result.span_id))) {
    const { error: claimConfirmErr } = await db
      .from("journal_claims")
      .update({
        claim_project_id: chosen_project_id,
        claim_project_id_norm: chosen_project_id,
        attribution_decision: "assign",
        claim_confirmation_state: "confirmed",
        confirmed_at: new Date().toISOString(),
        confirmed_by: "review_resolve",
      })
      .eq("source_span_id", String(result.span_id))
      .eq("active", true);

    if (claimConfirmErr) {
      console.error(
        `[review-resolve] claim confirmation sync warning for span ${result.span_id}: ${claimConfirmErr.message}`,
      );
    }
  }

  // ========================================
  // 5. LOG + RESPONSE
  // ========================================
  console.log(
    `[review-resolve] Resolved ${review_queue_id}: span=${result.span_id}, project=${chosen_project_id}, ` +
      `actor=${user_id}, was_already_resolved=${result.was_already_resolved}, updates=${
        JSON.stringify(result.updates)
      }`,
  );

  // RUNTIME LINEAGE EVIDENCE (fire-and-forget)
  try {
    const lineageEdges: { from: string; to: string; type: string }[] = [
      { from: "edge:review-resolve", to: "table:public.review_queue", type: "reads" },
      { from: "edge:review-resolve", to: "table:public.span_attributions", type: "writes" },
      { from: "edge:review-resolve", to: "table:public.review_queue", type: "writes" },
      { from: "edge:review-resolve", to: "table:public.override_log", type: "writes" },
      { from: "edge:review-resolve", to: "table:public.journal_claims", type: "writes" },
    ];
    const { error: lineageErr } = await db.from("evidence_events").upsert({
      source_type: "lineage",
      source_id: review_queue_id,
      source_run_id: "review-resolve:v3.1.0",
      transcript_variant: "baseline",
      metadata: { edges: lineageEdges, pipeline_version: "v3.1.0" },
    }, { onConflict: "source_type,source_id,transcript_variant" });
    if (lineageErr) console.warn(`lineage_emit: ${lineageErr.message}`);
  } catch { /* lineage emission must never block the response */ }

  return jsonResponse({
    ...result,
    ms: Date.now() - t0,
  }, 200);
});

// ============================================================
// HELPERS
// ============================================================

function jsonResponse(data: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str);
}
