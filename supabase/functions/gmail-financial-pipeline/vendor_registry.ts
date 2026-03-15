export interface VendorRegistryRow {
  id: string;
  vendor_name: string;
  vendor_normalized: string;
  vendor_type: "external_vendor" | "internal" | "platform" | "boilerplate";
  status: "active" | "rejected" | "review";
  match_pattern: string | null;
}

/**
 * Build the set of vendor_normalized strings that should be rejected
 * as standalone vendor names (replaces VENDOR_REJECT_TERMS).
 * Includes: boilerplate + platform vendors with status=rejected.
 */
export function buildRejectSet(rows: VendorRegistryRow[]): Set<string> {
  return new Set(
    rows
      .filter(
        (r) =>
          r.status === "rejected" &&
          (r.vendor_type === "boilerplate" || r.vendor_type === "platform"),
      )
      .map((r) => r.vendor_normalized),
  );
}

/**
 * Build RegExp patterns for internal/owner vendors
 * (replaces INTERNAL_VENDOR_PATTERNS).
 * Only rows with vendor_type=internal AND a non-null match_pattern.
 */
export function buildInternalPatterns(
  rows: VendorRegistryRow[],
): RegExp[] {
  return rows
    .filter(
      (r) => r.vendor_type === "internal" && r.match_pattern !== null,
    )
    .map((r) => new RegExp(r.match_pattern!));
}

/**
 * Build the set of internal vendor normalized names
 * (replaces INTERNAL_VENDOR_NORMALS in index.ts and classification.ts).
 */
export function buildInternalVendorNormals(
  rows: VendorRegistryRow[],
): Set<string> {
  return new Set(
    rows
      .filter((r) => r.vendor_type === "internal")
      .map((r) => r.vendor_normalized),
  );
}

/**
 * Build the list of known vendor hint names for extraction
 * (replaces KNOWN_VENDOR_HINTS in index.ts).
 * Returns vendor_name for all active external_vendor entries.
 */
export function buildVendorHintList(rows: VendorRegistryRow[]): string[] {
  return rows
    .filter(
      (r) => r.vendor_type === "external_vendor" && r.status === "active",
    )
    .map((r) => r.vendor_name);
}

/**
 * Load the full vendor registry from Supabase.
 * Called once per pipeline run (not per-candidate).
 */
export async function loadVendorRegistry(
  db: { from: (table: string) => any },
): Promise<VendorRegistryRow[]> {
  const { data, error } = await db
    .from("vendor_registry")
    .select(
      "id, vendor_name, vendor_normalized, vendor_type, status, match_pattern",
    );

  if (error) {
    throw new Error(`Failed to load vendor_registry: ${error.message}`);
  }

  return (data || []) as VendorRegistryRow[];
}

/**
 * Flag an unknown vendor for human review (Option B — permissive).
 * Upserts into vendor_review_queue. If vendor_normalized already exists,
 * increments seen_count and updates last_seen_at.
 *
 * Fire-and-forget — errors are logged but don't block the pipeline.
 */
export async function flagUnknownVendor(
  db: { from: (table: string) => any },
  vendor: {
    vendor_name: string;
    vendor_normalized: string;
    source_email_from: string | null;
    source_candidate_id: string | null;
  },
  warnings: string[],
): Promise<void> {
  const { data: existing } = await db
    .from("vendor_review_queue")
    .select("id, seen_count")
    .eq("vendor_normalized", vendor.vendor_normalized)
    .maybeSingle();

  if (existing) {
    const { error } = await db
      .from("vendor_review_queue")
      .update({
        seen_count: (existing.seen_count || 1) + 1,
        last_seen_at: new Date().toISOString(),
      })
      .eq("id", existing.id);

    if (error) {
      warnings.push(
        `vendor_review_queue_update_failed:${error.message.slice(0, 80)}`,
      );
    }
    return;
  }

  const { error } = await db.from("vendor_review_queue").insert({
    vendor_name: vendor.vendor_name,
    vendor_normalized: vendor.vendor_normalized,
    source_email_from: vendor.source_email_from,
    source_candidate_id: vendor.source_candidate_id,
    status: "pending",
  });

  if (error) {
    if (error.code === "23505") return;
    warnings.push(
      `vendor_review_queue_insert_failed:${error.message.slice(0, 80)}`,
    );
  }
}

/**
 * Check if a vendor_normalized string is known in the registry.
 * Returns the row if found, null if unknown.
 */
export function lookupVendor(
  rows: VendorRegistryRow[],
  vendorNormalized: string,
): VendorRegistryRow | null {
  return rows.find((r) => r.vendor_normalized === vendorNormalized) || null;
}

/**
 * Return the canonical display name for a vendor.
 * If the vendor is in the registry as an active entry, returns the registry's vendor_name.
 * Otherwise returns the raw vendor name unchanged.
 *
 * This normalizes display: "SOCIAL CIRCLE ACE" → "Social Circle ACE" (from registry).
 */
export function canonicalizeVendorDisplay(
  rows: VendorRegistryRow[],
  vendorNormalized: string | null,
  rawVendor: string | null,
): string | null {
  if (!vendorNormalized || !rawVendor) return rawVendor;
  const match = rows.find(
    (r) => r.vendor_normalized === vendorNormalized && r.status === "active",
  );
  return match ? match.vendor_name : rawVendor;
}
