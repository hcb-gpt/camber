# Pipeline Accuracy Improvements Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three accuracy gaps in the gmail-financial-pipeline: (1) resolve 45 review-queue candidates so real invoices stop being gated, (2) fix invoice number extraction garbage, and (3) add vendor name post-normalization to the vendor display name on extracted receipts.

**Architecture:** Three independent improvements to the existing Deno edge function pipeline. Improvement 1 is a SQL migration + new edge function endpoint for review resolution. Improvement 2 is a fix to the LLM extraction prompt and invoice regex in `extraction.ts`. Improvement 3 adds a `canonicalizeVendorDisplay` function that maps `vendor_normalized` back to a clean display name via the vendor registry.

**Tech Stack:** Deno/TypeScript, Supabase Edge Functions, PostgreSQL, `@supabase/supabase-js@2`

**CI:** `deno fmt` is a CI gate. Run `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions && deno fmt <file>` on all modified files. Tests: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test <file> --allow-env --allow-net --no-check`

**GIT DISCIPLINE:** Do NOT run git commit/push/add. A mechanical git-sync process commits every 5 minutes. Just write/edit files.

---

## Scope & Independence

These three improvements are **independent subsystems** that can be built in any order. Each produces working, testable software on its own:

1. **Review Queue Resolution** — Adds vendor registry entries for known vendors stuck in review, plus a new `resolve-review` endpoint to bulk-promote candidates
2. **Invoice Number Extraction Fix** — Fixes garbage invoice IDs ("oice", "this", "from") by improving the extraction regex and adding validation
3. **Vendor Display Name Canonicalization** — Maps all extracted vendor names through the registry to produce consistent display names

---

## File Structure

### Files to Create
- `camber/supabase/functions/gmail-financial-pipeline/review_resolution.ts` — Review queue resolution logic (promote/reject candidates)
- `camber/supabase/functions/gmail-financial-pipeline/review_resolution_test.ts` — Tests for review resolution
- `camber/supabase/functions/gmail-financial-pipeline/invoice_extract.ts` — Invoice number extraction + validation (extracted from extraction.ts)
- `camber/supabase/functions/gmail-financial-pipeline/invoice_extract_test.ts` — Tests for invoice extraction

### Files to Modify
- `camber/supabase/functions/gmail-financial-pipeline/vendor_registry.ts` — Add `canonicalizeVendorDisplay()` function
- `camber/supabase/functions/gmail-financial-pipeline/vendor_registry_test.ts` — Tests for canonicalize
- `camber/supabase/functions/gmail-financial-pipeline/extraction.ts` — Wire new invoice extraction, wire vendor canonicalization
- `camber/supabase/functions/gmail-financial-pipeline/extraction_test.ts` — Add tests for improved invoice extraction
- `camber/supabase/functions/gmail-financial-pipeline/index.ts` — Wire review resolution endpoint, wire vendor canonicalization into extraction loop

### Migrations (applied via gandalf MCP)
- Seed new vendor registry entries for vendors stuck in review queue
- Add `resolve_gmail_financial_review` RPC function

---

## Key Context for Implementers

### Database Tables
- **`gmail_financial_candidates`** — Pipeline candidate tracking. Key columns: `decision` (accept_extract|reject|review), `review_state` (pending|resolved), `review_resolution`, `extraction_state`, `extraction_error`.
- **`gmail_financial_receipts`** — Pipeline output (NOT `receipts` which is the older manual dataset). Has `vendor`, `vendor_normalized`, `dedupe_key`, `hit_count`. Currently 16 rows.
- **`vendor_registry`** — 21 rows. Columns: `vendor_name`, `vendor_normalized`, `vendor_type`, `status`, `match_pattern`.
- **`vendor_review_queue`** — Currently 0 rows (just deployed). Columns: `vendor_name`, `vendor_normalized`, `status`, `seen_count`.

### The Affinity Gate Problem
Candidates get `decision='review'` instead of `decision='accept_extract'` when `hasAutoExtractAffinity()` returns false. This happens when:
- No matched project alias
- No matched vendor name (vendor not in search targets)
- No matched project ID

**Fix:** Add the missing vendors to `vendor_registry` as `external_vendor/active`. The pipeline loads the registry at startup and uses `buildVendorHintList()` to populate vendor hints. When vendor hints match, `hasAutoExtractAffinity()` sees `matchedVendorNames` and passes.

### Invoice Number Garbage
The `extractInvoiceOrTransaction()` function in `extraction.ts` uses regex to find invoice-like patterns. When it fails, it falls back to grabbing a word near "invoice" or "receipt" keywords — producing garbage like "oice" (end of "invoice"), "this", "from", "amount", "lected" (end of "selected").

### Vendor Display Normalization
`extractVendor()` returns either the hint name (e.g., "Carter Lumber") or the raw From header display name (e.g., "SOCIAL CIRCLE ACE"). The `vendor_normalized` field is always lowercase with suffixes stripped. The registry has canonical `vendor_name` values. We should use those when available.

---

## Chunk 1: Review Queue Resolution

### Task 1: Seed Missing Vendors into Registry

**Files:**
- Migration: Applied via `gandalf` MCP tool `apply_migration`

The following vendors appear in the review queue as real construction vendors that should auto-extract. We need to add them to `vendor_registry`:

| vendor_name | vendor_type | status | match_pattern |
|-------------|-------------|--------|---------------|
| AAA Northside Portable Toilets | external_vendor | active | NULL |
| Georgia Civil | external_vendor | active | NULL |
| Social Circle ACE | external_vendor | active | NULL |
| TLP Construction | external_vendor | active | NULL |
| Anything Fireplace | external_vendor | active | NULL |
| Robinson Well | external_vendor | active | NULL |
| Family Pro Window Cleaning | external_vendor | active | NULL |
| Hetzer Electric | external_vendor | active | NULL |
| Crossed Chisels | external_vendor | active | NULL |
| Givens Landscaping | external_vendor | active | NULL |
| Sisson DuPont | external_vendor | active | NULL |
| Builders Warehouse | external_vendor | active | NULL |
| Phelps Welding | external_vendor | active | NULL |
| TJ Exteriors | external_vendor | active | NULL |
| Structuremen | external_vendor | active | NULL |
| JJ Brick | external_vendor | active | NULL |
| Jayco Innovation | external_vendor | active | NULL |
| GA Insulation | external_vendor | active | NULL |
| Air GA | external_vendor | active | NULL |

Also add these as rejected to prevent false extractions:

| vendor_name | vendor_type | status | match_pattern |
|-------------|-------------|--------|---------------|
| Pipedream | platform | rejected | NULL |
| Stripe | platform | rejected | NULL |
| Calendly | platform | rejected | NULL |
| Anthropic | platform | rejected | NULL |
| Supabase | platform | rejected | NULL |
| Paddle | platform | rejected | NULL |
| Google Payments | platform | rejected | NULL |
| Home Depot Pro Xtra | platform | rejected | NULL |

- [ ] **Step 1: Apply vendor registry seed migration**

Use gandalf MCP `apply_migration` with name `seed_vendor_registry_batch2`:

```sql
-- Seed batch 2: construction vendors from review queue analysis + SaaS platform rejections
INSERT INTO public.vendor_registry (vendor_name, vendor_normalized, vendor_type, status, match_pattern)
VALUES
  -- Construction vendors (active)
  ('AAA Northside Portable Toilets', 'aaa northside portable toilets', 'external_vendor', 'active', NULL),
  ('Georgia Civil', 'georgia civil', 'external_vendor', 'active', NULL),
  ('Social Circle ACE', 'social circle ace', 'external_vendor', 'active', NULL),
  ('TLP Construction', 'tlp construction', 'external_vendor', 'active', NULL),
  ('Anything Fireplace', 'anything fireplace', 'external_vendor', 'active', NULL),
  ('Robinson Well', 'robinson well', 'external_vendor', 'active', NULL),
  ('Family Pro Window Cleaning', 'family pro window cleaning', 'external_vendor', 'active', NULL),
  ('Hetzer Electric', 'hetzer electric', 'external_vendor', 'active', NULL),
  ('Crossed Chisels', 'crossed chisels', 'external_vendor', 'active', NULL),
  ('Givens Landscaping', 'givens landscaping', 'external_vendor', 'active', NULL),
  ('Sisson DuPont', 'sisson dupont', 'external_vendor', 'active', NULL),
  ('Builders Warehouse', 'builders warehouse', 'external_vendor', 'active', NULL),
  ('Phelps Welding', 'phelps welding', 'external_vendor', 'active', NULL),
  ('TJ Exteriors', 'tj exteriors', 'external_vendor', 'active', NULL),
  ('Structuremen', 'structuremen', 'external_vendor', 'active', NULL),
  ('JJ Brick', 'jj brick', 'external_vendor', 'active', NULL),
  ('Jayco Innovation', 'jayco innovation', 'external_vendor', 'active', NULL),
  ('GA Insulation', 'ga insulation', 'external_vendor', 'active', NULL),
  ('Air GA', 'air ga', 'external_vendor', 'active', NULL),
  -- SaaS platforms (rejected — these are Chad's tools, not construction vendors)
  ('Pipedream', 'pipedream', 'platform', 'rejected', NULL),
  ('Stripe', 'stripe', 'platform', 'rejected', NULL),
  ('Calendly', 'calendly', 'platform', 'rejected', NULL),
  ('Anthropic', 'anthropic', 'platform', 'rejected', NULL),
  ('Supabase', 'supabase', 'platform', 'rejected', NULL),
  ('Paddle', 'paddle', 'platform', 'rejected', NULL),
  ('Google Payments', 'google payments', 'platform', 'rejected', NULL),
  ('Home Depot Pro Xtra', 'home depot pro xtra', 'platform', 'rejected', NULL)
ON CONFLICT (vendor_normalized) DO NOTHING;
```

- [ ] **Step 2: Verify registry now has ~48 entries**

```sql
SELECT vendor_type, status, count(*) FROM vendor_registry GROUP BY vendor_type, status ORDER BY vendor_type, status;
```

Expected: ~19 external_vendor/active, ~8 boilerplate/rejected, ~10 platform/rejected, ~2 internal/rejected = ~48 total.

---

### Task 2: Build Review Resolution Module

**Files:**
- Create: `camber/supabase/functions/gmail-financial-pipeline/review_resolution.ts`
- Create: `camber/supabase/functions/gmail-financial-pipeline/review_resolution_test.ts`

- [ ] **Step 1: Write the test file**

```typescript
// review_resolution_test.ts
import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildReviewResolutionPatch,
  validateResolutionAction,
  type ReviewResolutionAction,
} from "./review_resolution.ts";

Deno.test("validateResolutionAction accepts valid actions", () => {
  assertEquals(validateResolutionAction("promote"), true);
  assertEquals(validateResolutionAction("reject"), true);
  assertEquals(validateResolutionAction("skip"), true);
});

Deno.test("validateResolutionAction rejects invalid actions", () => {
  assertEquals(validateResolutionAction("invalid"), false);
  assertEquals(validateResolutionAction(""), false);
  assertEquals(validateResolutionAction(null as unknown as string), false);
});

Deno.test("buildReviewResolutionPatch for promote", () => {
  const patch = buildReviewResolutionPatch("promote", "test-user");
  assertEquals(patch.decision, "accept_extract");
  assertEquals(patch.review_state, "resolved");
  assertEquals(patch.review_resolution, "accept_extract");
  assertEquals(typeof patch.review_resolved_at_utc, "string");
});

Deno.test("buildReviewResolutionPatch for reject", () => {
  const patch = buildReviewResolutionPatch("reject", "test-user");
  assertEquals(patch.decision, "reject");
  assertEquals(patch.review_state, "resolved");
  assertEquals(patch.review_resolution, "reject");
});

Deno.test("buildReviewResolutionPatch for skip", () => {
  const patch = buildReviewResolutionPatch("skip", "test-user");
  assertEquals(patch.decision, "review");
  assertEquals(patch.review_state, "resolved");
  assertEquals(patch.review_resolution, "skip");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test review_resolution_test.ts --allow-env --allow-net --no-check`
Expected: FAIL — module not found

- [ ] **Step 3: Write the implementation**

```typescript
// review_resolution.ts

export type ReviewResolutionAction = "promote" | "reject" | "skip";

const VALID_ACTIONS = new Set<string>(["promote", "reject", "skip"]);

export function validateResolutionAction(action: string): action is ReviewResolutionAction {
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
  resolvedBy: string,
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
 * Resolve a batch of review-queue candidates.
 * Returns { resolved: number, errors: string[] }.
 */
export async function resolveReviewBatch(
  db: { from: (table: string) => any },
  candidateIds: string[],
  action: ReviewResolutionAction,
  resolvedBy: string,
  warnings: string[],
): Promise<{ resolved: number; errors: string[] }> {
  const errors: string[] = [];
  let resolved = 0;

  const patch = buildReviewResolutionPatch(action, resolvedBy);

  for (const candidateId of candidateIds) {
    const { error } = await db
      .from("gmail_financial_candidates")
      .update(patch)
      .eq("id", candidateId)
      .eq("decision", "review")
      .eq("review_state", "pending");

    if (error) {
      errors.push(`${candidateId}:${error.message.slice(0, 80)}`);
      warnings.push(`review_resolution_failed:${candidateId}`);
    } else {
      resolved++;
    }
  }

  return { resolved, errors };
}

/**
 * Bulk-promote all pending review candidates that match vendors
 * now in the vendor registry as active external_vendor.
 * This re-runs affinity gate logic: if the vendor is now known,
 * the candidate should be auto-promoted.
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
    warnings.push(`auto_promote_vendor_load_failed:${vendorError.message.slice(0, 80)}`);
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
    warnings.push(`auto_promote_candidate_load_failed:${candidateError.message.slice(0, 80)}`);
    return { promoted: 0, skipped: 0, errors: [candidateError.message] };
  }

  const errors: string[] = [];
  let promoted = 0;
  let skipped = 0;

  for (const candidate of (candidates || [])) {
    // Check if any known vendor name appears in from_header or subject
    const combined = `${candidate.from_header || ""} ${candidate.subject || ""} ${candidate.snippet || ""}`.toLowerCase();
    const hasKnownVendor = Array.from(vendorNames).some((name) => combined.includes(name)) ||
      Array.from(vendorNormals).some((name) => combined.includes(name));

    if (!hasKnownVendor) {
      skipped++;
      continue;
    }

    // Only promote candidates that were review-gated by affinity
    const reason = candidate.decision_reason || "";
    if (!reason.includes("affinity_gate_review")) {
      skipped++;
      continue;
    }

    const patch = buildReviewResolutionPatch("promote", "auto_promote_vendor_registry");
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

  warnings.push(`auto_promote:promoted=${promoted},skipped=${skipped},errors=${errors.length}`);
  return { promoted, skipped, errors };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test review_resolution_test.ts --allow-env --allow-net --no-check`
Expected: 5 tests pass

- [ ] **Step 5: Run deno fmt**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions && deno fmt gmail-financial-pipeline/review_resolution.ts gmail-financial-pipeline/review_resolution_test.ts`

---

### Task 3: Wire Review Resolution into index.ts

**Files:**
- Modify: `camber/supabase/functions/gmail-financial-pipeline/index.ts`

The pipeline already handles `run_mode` via the request body. We add a new `action=resolve_reviews` parameter that triggers auto-promotion.

- [ ] **Step 1: Add import at top of index.ts**

After the existing vendor_registry imports (around line 24), add:

```typescript
import { autoPromoteByVendorRegistry } from "./review_resolution.ts";
```

- [ ] **Step 2: Add resolve_reviews action handler**

Find the section after vendor registry loading (around line 1175) and before classification (line 1180). Add:

```typescript
    // Auto-promote review candidates whose vendors are now in the registry
    if (requestBody.action === "resolve_reviews" || requestBody.auto_promote_reviews === true) {
      const promoResult = await autoPromoteByVendorRegistry(db, warnings);
      if (requestBody.action === "resolve_reviews") {
        return new Response(
          JSON.stringify({
            ok: true,
            action: "resolve_reviews",
            ...promoResult,
            warnings,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
    }
```

- [ ] **Step 3: Run deno fmt**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions && deno fmt gmail-financial-pipeline/index.ts`

- [ ] **Step 4: Deploy and test resolve_reviews**

Deploy: `cd /Users/chadbarlow/gh/hcb-gpt/camber && npx supabase functions deploy gmail-financial-pipeline --project-ref rjhdwidddtfetbwqolof`

Test:
```bash
source /Users/chadbarlow/gh/hcb-gpt/camber/credentials.env
curl -X POST "${SUPABASE_URL}/functions/v1/gmail-financial-pipeline" \
  -H "Content-Type: application/json" \
  -H "X-Edge-Secret: ${X_EDGE_SECRET}" \
  -H "X-Source: manual" \
  -d '{"action":"resolve_reviews","source":"manual"}'
```

Expected: JSON with `promoted` > 0 for affinity-gated vendors that now exist in registry.

- [ ] **Step 5: Verify review queue shrunk**

```sql
SELECT count(*) FROM gmail_financial_candidates WHERE decision = 'review' AND review_state = 'pending';
```

Expected: fewer than 45 (was 45 before).

---

## Chunk 2: Invoice Number Extraction Fix

### Task 4: Build Invoice Number Extraction + Validation Module

**Files:**
- Create: `camber/supabase/functions/gmail-financial-pipeline/invoice_extract.ts`
- Create: `camber/supabase/functions/gmail-financial-pipeline/invoice_extract_test.ts`

The current `extractInvoiceOrTransaction()` in extraction.ts produces garbage like "oice", "this", "from", "lected", "amount". Root cause: the fallback regex grabs a single word near invoice/receipt keywords, often catching the tail of the keyword itself or a common preposition.

- [ ] **Step 1: Write the test file**

```typescript
// invoice_extract_test.ts
import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  extractInvoiceNumber,
  isGarbageInvoice,
  GARBAGE_INVOICE_PATTERNS,
} from "./invoice_extract.ts";

Deno.test("isGarbageInvoice rejects keyword fragments", () => {
  // These are real garbage values from production gmail_financial_receipts
  assertEquals(isGarbageInvoice("oice"), true);    // tail of "invoice"
  assertEquals(isGarbageInvoice("lected"), true);   // tail of "selected"
  assertEquals(isGarbageInvoice("this"), true);     // common pronoun
  assertEquals(isGarbageInvoice("from"), true);     // preposition
  assertEquals(isGarbageInvoice("amount"), true);   // financial keyword
  assertEquals(isGarbageInvoice("receipt"), true);  // document keyword
  assertEquals(isGarbageInvoice("invoice"), true);  // document keyword
  assertEquals(isGarbageInvoice("payment"), true);  // document keyword
  assertEquals(isGarbageInvoice("the"), true);      // article
  assertEquals(isGarbageInvoice("for"), true);      // preposition
  assertEquals(isGarbageInvoice("your"), true);     // pronoun
  assertEquals(isGarbageInvoice("was"), true);      // verb
  assertEquals(isGarbageInvoice("has"), true);      // verb
  assertEquals(isGarbageInvoice("been"), true);     // verb
});

Deno.test("isGarbageInvoice allows real invoice numbers", () => {
  assertEquals(isGarbageInvoice("IN45000259403"), false);
  assertEquals(isGarbageInvoice("2244"), false);
  assertEquals(isGarbageInvoice("84992A"), false);
  assertEquals(isGarbageInvoice("000080434"), false);
  assertEquals(isGarbageInvoice("551984"), false);
  assertEquals(isGarbageInvoice("HUNTERST1"), false);
  assertEquals(isGarbageInvoice("WAGGINTAILS4"), false);
  assertEquals(isGarbageInvoice("45000258453/258401"), false);
  assertEquals(isGarbageInvoice("F89303"), false);
  assertEquals(isGarbageInvoice("P14393"), false);
  assertEquals(isGarbageInvoice("8457"), false);
});

Deno.test("isGarbageInvoice rejects too-short strings", () => {
  assertEquals(isGarbageInvoice("ab"), true);
  assertEquals(isGarbageInvoice("x"), true);
  assertEquals(isGarbageInvoice(""), true);
});

Deno.test("extractInvoiceNumber finds structured invoice numbers", () => {
  const result = extractInvoiceNumber("Invoice #IN45000259403 for Carter Lumber");
  assertEquals(result, "IN45000259403");
});

Deno.test("extractInvoiceNumber finds invoice with colon separator", () => {
  const result = extractInvoiceNumber("Invoice: F89303 dated March 2026");
  assertEquals(result, "F89303");
});

Deno.test("extractInvoiceNumber finds invoice number pattern", () => {
  const result = extractInvoiceNumber("Please pay invoice number 551984 at your convenience");
  assertEquals(result, "551984");
});

Deno.test("extractInvoiceNumber returns null for no match", () => {
  const result = extractInvoiceNumber("Thank you for your business");
  assertEquals(result, null);
});

Deno.test("extractInvoiceNumber rejects garbage fallback", () => {
  // This text has "invoice" but no real invoice number nearby
  const result = extractInvoiceNumber("This invoice is for your records");
  assertEquals(result, null);
});

Deno.test("extractInvoiceNumber finds PO numbers", () => {
  const result = extractInvoiceNumber("PO# 45400026071 shipped today");
  assertEquals(result, "45400026071");
});

Deno.test("extractInvoiceNumber finds receipt number", () => {
  const result = extractInvoiceNumber("Payment Receipt P14393 for service");
  assertEquals(result, "P14393");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test invoice_extract_test.ts --allow-env --allow-net --no-check`
Expected: FAIL — module not found

- [ ] **Step 3: Write the implementation**

```typescript
// invoice_extract.ts

/**
 * Words that should never be accepted as invoice/transaction identifiers.
 * These are common English words, financial keywords, and fragments of
 * keywords that the previous regex would incorrectly capture.
 */
export const GARBAGE_INVOICE_PATTERNS = new Set([
  // Keyword fragments (tail of "invoice", "selected", etc.)
  "oice", "voice", "lected", "ment", "tion", "ount",
  // Document type keywords
  "invoice", "receipt", "statement", "payment", "amount",
  "balance", "total", "subtotal", "due", "paid", "charge",
  "transaction", "order", "billing", "account",
  // Common English words
  "the", "this", "that", "from", "for", "your", "you",
  "was", "has", "been", "are", "were", "will", "have",
  "with", "and", "but", "not", "our", "its", "all",
  "new", "one", "two", "per", "via", "see", "may",
  // Pronouns and articles
  "his", "her", "him", "she", "they", "them", "who",
  // Common email/financial verbs
  "sent", "send", "view", "click", "open", "pay",
  "please", "thank", "thanks", "dear", "hello", "here",
]);

/** Minimum length for a valid invoice number. */
const MIN_INVOICE_LENGTH = 3;

/**
 * Check if a candidate invoice string is garbage.
 * Returns true if the string should be rejected.
 */
export function isGarbageInvoice(value: string): boolean {
  if (!value) return true;
  const trimmed = value.trim();
  if (trimmed.length < MIN_INVOICE_LENGTH) return true;
  if (GARBAGE_INVOICE_PATTERNS.has(trimmed.toLowerCase())) return true;
  // Pure alphabetic strings under 5 chars are likely noise
  if (/^[a-zA-Z]{1,4}$/.test(trimmed)) return true;
  return false;
}

/**
 * Primary invoice/reference number patterns, ordered by specificity.
 * Each pattern captures the invoice ID in group 1.
 */
const INVOICE_PATTERNS: RegExp[] = [
  // "Invoice #IN45000259403" or "Invoice: F89303" or "Invoice Number 551984"
  /(?:invoice|inv|receipt|po|order|ref|confirmation|payment\s+receipt)\s*(?:#|no\.?|number|num|:)\s*([A-Z0-9][\w\-/]{2,30})/i,
  // "#12345" standalone (common in subject lines)
  /#\s*([A-Z0-9][\w\-/]{3,20})/i,
  // "IN45000259403" pattern (Carter Lumber style: prefix + digits)
  /\b(IN\d{8,})\b/i,
  // Pure numeric 4+ digits near financial context
  /(?:invoice|receipt|po|order|ref|confirmation)\s+(?:\w+\s+){0,3}(\d{4,})\b/i,
  // "P14393" or "F89303" pattern (letter + digits)
  /\b([A-Z]\d{4,})\b/,
];

/**
 * Extract an invoice or transaction number from email text.
 * Returns null if no plausible invoice number is found.
 *
 * Unlike the old implementation, this NEVER returns garbage words.
 * It prefers returning null over returning noise.
 */
export function extractInvoiceNumber(text: string): string | null {
  if (!text) return null;

  for (const pattern of INVOICE_PATTERNS) {
    const match = text.match(pattern);
    if (match?.[1]) {
      const candidate = match[1].trim();
      if (!isGarbageInvoice(candidate)) {
        return candidate;
      }
    }
  }

  return null;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test invoice_extract_test.ts --allow-env --allow-net --no-check`
Expected: 10 tests pass

- [ ] **Step 5: Run deno fmt**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions && deno fmt gmail-financial-pipeline/invoice_extract.ts gmail-financial-pipeline/invoice_extract_test.ts`

---

### Task 5: Wire Invoice Validation into Extraction Pipeline

**Files:**
- Modify: `camber/supabase/functions/gmail-financial-pipeline/extraction.ts`
- Modify: `camber/supabase/functions/gmail-financial-pipeline/extraction_test.ts`

The existing `extractInvoiceOrTransaction()` function (in extraction.ts) will be wrapped with garbage filtering. We don't replace it entirely — we add a validation gate.

- [ ] **Step 1: Add import to extraction.ts**

At the top of `extraction.ts`, add:

```typescript
import { isGarbageInvoice } from "./invoice_extract.ts";
```

- [ ] **Step 2: Find `extractInvoiceOrTransaction()` and add garbage filter**

Locate the `extractInvoiceOrTransaction` function in extraction.ts. At the end of the function, just before the return statement, add garbage validation:

```typescript
  // Validate: reject garbage invoice numbers
  if (result && isGarbageInvoice(result)) {
    return null;
  }
```

This ensures any existing extraction path that produces garbage gets filtered. The function should return `null` instead of "oice", "this", etc.

- [ ] **Step 3: Add tests to extraction_test.ts**

Append to `extraction_test.ts`:

```typescript
Deno.test("extractInvoiceOrTransaction rejects garbage fragments", () => {
  // These were real production failures
  const garbageInputs = [
    "Please view this invoice for payment",
    "Your receipt from Anthropic amount $18.99",
    "Payment was selected for processing",
  ];
  for (const input of garbageInputs) {
    const result = extractInvoiceOrTransaction(input);
    if (result !== null) {
      // If something is extracted, it must not be garbage
      assertEquals(
        ["oice", "this", "from", "amount", "lected", "was", "receipt", "invoice"].includes(result.toLowerCase()),
        false,
        `Extracted garbage "${result}" from: ${input}`,
      );
    }
  }
});
```

- [ ] **Step 4: Run all extraction tests**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test extraction_test.ts --allow-env --allow-net --no-check`
Expected: All tests pass (existing + new)

- [ ] **Step 5: Run deno fmt on modified files**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions && deno fmt gmail-financial-pipeline/extraction.ts gmail-financial-pipeline/extraction_test.ts`

---

## Chunk 3: Vendor Display Name Canonicalization

### Task 6: Add canonicalizeVendorDisplay to vendor_registry.ts

**Files:**
- Modify: `camber/supabase/functions/gmail-financial-pipeline/vendor_registry.ts`
- Modify: `camber/supabase/functions/gmail-financial-pipeline/vendor_registry_test.ts`

When the vendor registry has a canonical `vendor_name` for a `vendor_normalized`, use it. This ensures "SOCIAL CIRCLE ACE" (from email header) becomes "Social Circle ACE" (from registry), and all Carter Lumber variants become "Carter Lumber".

- [ ] **Step 1: Add tests to vendor_registry_test.ts**

Append:

```typescript
Deno.test("canonicalizeVendorDisplay returns registry name when found", () => {
  const rows: VendorRegistryRow[] = [
    { id: "1", vendor_name: "Carter Lumber", vendor_normalized: "carter lumber", vendor_type: "external_vendor", status: "active", match_pattern: null },
    { id: "2", vendor_name: "GA Insulation", vendor_normalized: "ga insulation", vendor_type: "external_vendor", status: "active", match_pattern: null },
  ];
  assertEquals(canonicalizeVendorDisplay(rows, "carter lumber", "CARTER LUMBER CO"), "Carter Lumber");
  assertEquals(canonicalizeVendorDisplay(rows, "ga insulation", "GA INSULATION LLC"), "GA Insulation");
});

Deno.test("canonicalizeVendorDisplay returns raw vendor when not in registry", () => {
  const rows: VendorRegistryRow[] = [];
  assertEquals(canonicalizeVendorDisplay(rows, "unknown vendor", "Unknown Vendor LLC"), "Unknown Vendor LLC");
});

Deno.test("canonicalizeVendorDisplay returns raw vendor for empty registry", () => {
  assertEquals(canonicalizeVendorDisplay([], "carter lumber", "Carter Lumber Inc"), "Carter Lumber Inc");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test vendor_registry_test.ts --allow-env --allow-net --no-check`
Expected: FAIL — canonicalizeVendorDisplay not exported

- [ ] **Step 3: Add implementation to vendor_registry.ts**

After the `lookupVendor` function (line 154), add:

```typescript
/**
 * Return the canonical display name for a vendor.
 * If the vendor is in the registry, returns the registry's vendor_name.
 * Otherwise returns the raw vendor name unchanged.
 *
 * This normalizes display: "CARTER LUMBER CO" → "Carter Lumber" (from registry).
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test vendor_registry_test.ts --allow-env --allow-net --no-check`
Expected: All tests pass (existing 7 + new 3 = 10)

- [ ] **Step 5: Run deno fmt**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions && deno fmt gmail-financial-pipeline/vendor_registry.ts gmail-financial-pipeline/vendor_registry_test.ts`

---

### Task 7: Wire Vendor Canonicalization into Extraction Loop

**Files:**
- Modify: `camber/supabase/functions/gmail-financial-pipeline/index.ts`

- [ ] **Step 1: Add import**

Add `canonicalizeVendorDisplay` to the existing vendor_registry import line in index.ts:

```typescript
import {
  buildRejectSet,
  buildInternalPatterns,
  buildInternalVendorNormals,
  buildVendorHintList,
  canonicalizeVendorDisplay,
  flagUnknownVendor,
  loadVendorRegistry,
  lookupVendor,
  type VendorRegistryRow,
} from "./vendor_registry.ts";
```

- [ ] **Step 2: Add canonicalization after extraction, before receipt insert**

In the extraction loop (around line 1267, after `flagUnknownVendor` call and before the `evidenceLocator` line), add:

```typescript
          // Canonicalize vendor display name via registry
          if (receipt.vendor && receipt.vendor_normalized && vendorRegistry.length > 0) {
            const canonical = canonicalizeVendorDisplay(
              vendorRegistry,
              receipt.vendor_normalized,
              receipt.vendor,
            );
            if (canonical && canonical !== receipt.vendor) {
              receipt.vendor = canonical;
            }
          }
```

Note: `receipt` is the result of `applyTargetAffinity(extractReceiptRecord(...))`. The `vendor` field is mutable on the returned object, so direct assignment works.

- [ ] **Step 3: Run deno fmt**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions && deno fmt gmail-financial-pipeline/index.ts`

- [ ] **Step 4: Run all tests to verify nothing broke**

Run: `cd /Users/chadbarlow/gh/hcb-gpt/camber/supabase/functions/gmail-financial-pipeline && deno test --allow-env --allow-net --no-check`
Expected: All tests pass across all test files

---

### Task 8: Deploy and Verify End-to-End

**Files:** None (deployment + verification only)

- [ ] **Step 1: Deploy the updated function**

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber && npx supabase functions deploy gmail-financial-pipeline --project-ref rjhdwidddtfetbwqolof
```

- [ ] **Step 2: Run resolve_reviews to auto-promote candidates**

```bash
source /Users/chadbarlow/gh/hcb-gpt/camber/credentials.env
curl -X POST "${SUPABASE_URL}/functions/v1/gmail-financial-pipeline" \
  -H "Content-Type: application/json" \
  -H "X-Edge-Secret: ${X_EDGE_SECRET}" \
  -H "X-Source: manual" \
  -d '{"action":"resolve_reviews","source":"manual"}'
```

Expected: `promoted` count > 0

- [ ] **Step 3: Run full pipeline to extract newly-promoted candidates**

```bash
curl -X POST "${SUPABASE_URL}/functions/v1/gmail-financial-pipeline" \
  -H "Content-Type: application/json" \
  -H "X-Edge-Secret: ${X_EDGE_SECRET}" \
  -H "X-Source: manual" \
  -d '{"run_mode":"full","dry_run":false,"source":"manual","candidate_limit":50}'
```

Expected: `receipts_inserted` > 0, `vendor_registry_loaded:48_entries` (approx) in warnings

- [ ] **Step 4: Verify receipt quality — no garbage invoice numbers**

```sql
SELECT vendor, vendor_normalized, total, invoice_or_transaction, receipt_date
FROM gmail_financial_receipts
WHERE created_at > now() - interval '1 hour'
ORDER BY created_at DESC;
```

Verify: No invoice_or_transaction values like "oice", "this", "from", "amount", "lected". Values should be real IDs or NULL.

- [ ] **Step 5: Verify vendor display names are canonical**

```sql
SELECT vendor, vendor_normalized
FROM gmail_financial_receipts
WHERE vendor != vendor_normalized  -- non-trivial display names
ORDER BY created_at DESC;
```

Verify: vendor names match registry's `vendor_name` (e.g., "Carter Lumber" not "CARTER LUMBER CO").

- [ ] **Step 6: Check review queue final state**

```sql
SELECT count(*) as remaining_reviews
FROM gmail_financial_candidates
WHERE decision = 'review' AND review_state = 'pending';
```

Expected: Fewer than 45 (SaaS receipts like Anthropic/Pipedream stay in review — they're correctly gated because they're platform vendors, not construction vendors).

---

## Data Quality Cleanup (Optional, Post-Deploy)

After all three improvements are deployed and verified, clean up existing bad data:

```sql
-- Remove Bo Hurley $1.5M false positive
DELETE FROM gmail_financial_receipts WHERE vendor_normalized = 'bo hurley' AND total > 1000000;

-- Null out garbage invoice numbers on existing receipts
UPDATE gmail_financial_receipts
SET invoice_or_transaction = NULL, updated_at = now()
WHERE invoice_or_transaction IN ('oice', 'this', 'from', 'amount', 'lected', 'receipt');

-- Deduplicate Carter Lumber $13,700 (keep the one with best data)
-- Manual review needed: 3 rows with same amount but different dates (02-23, 02-24, 02-25)
-- These may be legitimately different invoices on consecutive days, or pipeline re-runs
```

These are manual SQL operations, not automated code changes. Run them via gandalf MCP `execute_sql` after verifying the data.
