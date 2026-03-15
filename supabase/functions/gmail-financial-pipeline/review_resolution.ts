export type ReviewResolutionAction = "promote" | "reject" | "skip";

const VALID_ACTIONS = new Set<string>(["promote", "reject", "skip"]);

export function validateResolutionAction(
  action: string,
): action is ReviewResolutionAction {
  return typeof action === "string" && VALID_ACTIONS.has(action);
}

export interface ReviewResolutionPatch {
  decision: string;
  review_state: string;
  review_resolution: string;
  review_resolved_at_utc: string;
  updated_at: string;
}

export function buildReviewResolutionPatch(
  action: ReviewResolutionAction,
): ReviewResolutionPatch {
  const now = new Date().toISOString();
  const decisionMap: Record<ReviewResolutionAction, string> = {
    promote: "accept_extract",
    reject: "reject",
    skip: "review",
  };
  return {
    decision: decisionMap[action],
    review_state: "resolved",
    review_resolution: action === "skip" ? "skip" : decisionMap[action],
    review_resolved_at_utc: now,
    updated_at: now,
  };
}

/**
 * Bulk-promote all pending review candidates that match vendors
 * now in the vendor registry as active external_vendor.
 * Only promotes candidates that were gated by affinity (decision_reason contains "affinity_gate_review").
 */
export async function autoPromoteByVendorRegistry(
  db: { from: (table: string) => any },
  warnings: string[],
): Promise<{ promoted: number; skipped: number; errors: string[] }> {
  // 1. Load all active external vendors from registry
  const { data: vendors, error: vendorError } = await db
    .from("vendor_registry")
    .select("vendor_name, vendor_normalized")
    .eq("vendor_type", "external_vendor")
    .eq("status", "active");

  if (vendorError) {
    warnings.push(
      `auto_promote_vendor_load_failed:${vendorError.message.slice(0, 80)}`,
    );
    return { promoted: 0, skipped: 0, errors: [vendorError.message] };
  }

  const vendorNames = new Set(
    (vendors || []).map((v: { vendor_name: string }) => v.vendor_name.toLowerCase()),
  );
  const vendorNormals = new Set(
    (vendors || []).map((v: { vendor_normalized: string }) => v.vendor_normalized),
  );

  // 2. Load all pending review candidates
  const { data: candidates, error: candidateError } = await db
    .from("gmail_financial_candidates")
    .select("id, from_header, subject, snippet, decision_reason")
    .eq("decision", "review")
    .eq("review_state", "pending");

  if (candidateError) {
    warnings.push(
      `auto_promote_candidate_load_failed:${candidateError.message.slice(0, 80)}`,
    );
    return { promoted: 0, skipped: 0, errors: [candidateError.message] };
  }

  const errors: string[] = [];
  let promoted = 0;
  let skipped = 0;

  for (const candidate of candidates || []) {
    // Only promote candidates that were review-gated by affinity
    const reason = candidate.decision_reason || "";
    if (!reason.includes("affinity_gate_review")) {
      skipped++;
      continue;
    }

    // Check if any known vendor name appears in from_header, subject, or snippet
    const combined = `${candidate.from_header || ""} ${candidate.subject || ""} ${candidate.snippet || ""}`
      .toLowerCase();
    const hasKnownVendor = Array.from(vendorNames).some((name) => combined.includes(name)) ||
      Array.from(vendorNormals).some((name) => combined.includes(name));

    if (!hasKnownVendor) {
      skipped++;
      continue;
    }

    const patch = buildReviewResolutionPatch("promote");
    const { error } = await db
      .from("gmail_financial_candidates")
      .update(patch)
      .eq("id", candidate.id)
      .eq("decision", "review")
      .eq("review_state", "pending");

    if (error) {
      errors.push(`${candidate.id}:${error.message.slice(0, 80)}`);
    } else {
      promoted++;
    }
  }

  warnings.push(
    `auto_promote:promoted=${promoted},skipped=${skipped},errors=${errors.length}`,
  );
  return { promoted, skipped, errors };
}
