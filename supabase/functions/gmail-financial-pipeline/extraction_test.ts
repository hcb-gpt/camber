import {
  type AliasRow,
  decodeGmailMessageText,
  extractAmount,
  extractInvoiceOrTransaction,
  extractReceiptRecord,
  extractVendor,
} from "./extraction.ts";
import { assertEquals, assertExists } from "https://deno.land/std@0.208.0/assert/mod.ts";

const ALIASES: AliasRow[] = [
  { alias: "Winship", job_name: "Winship Residence", project_id: "11111111-1111-4111-8111-111111111111" },
  { alias: "Woodbery", job_name: "Woodbery Residence", project_id: "22222222-2222-4222-8222-222222222222" },
];

Deno.test("decodeGmailMessageText prefers plain text over html", () => {
  const payload = {
    mimeType: "multipart/alternative",
    parts: [
      {
        mimeType: "text/plain",
        body: { data: "SW52b2ljZSAjIDEwNDIKVG90YWwgRHVlOiAkMTIsNTAwLjAw" },
      },
      {
        mimeType: "text/html",
        body: { data: "PGRpdj5JbnZvaWNlICMxMDQyPC9kaXY+" },
      },
    ],
  };

  const decoded = decodeGmailMessageText(payload);
  assertEquals(decoded.includes("Invoice # 1042"), true);
  assertEquals(decoded.includes("Total Due: $12,500.00"), true);
});

Deno.test("extractAmount picks contextual total before other amounts", () => {
  const parsed = extractAmount("Subtotal $10,000.00\nTax $500.00\nTotal Due: $10,500.00");
  assertEquals(parsed.total, 10500);
  assertEquals(parsed.method, "contextual_total");
});

Deno.test("extractAmount preserves accounting negative notation", () => {
  const contextual = extractAmount("Credit Memo\nAmount Due: ($500.00)");
  assertEquals(contextual.total, -500);
  assertEquals(contextual.method, "contextual_total");

  const fallback = extractAmount("Adjustment posted: ($125.50)");
  assertEquals(fallback.total, -125.5);
  assertEquals(fallback.method, "largest_dollar_amount");
});

Deno.test("extractAmount ignores bare integers without currency markers or cents", () => {
  const parsed = extractAmount("Invoice # 1042\n10 items shipped\nReference 9988");
  assertEquals(parsed.total, null);
  assertEquals(parsed.method, null);
});

Deno.test("extractReceiptRecord resolves vendor, amount, project, and invoice", () => {
  const record = extractReceiptRecord({
    aliasRows: ALIASES,
    bodyText: [
      "Invoice Date: 03/13/2026",
      "Invoice # 1042",
      "Amount Due: $12,500.00",
      "Forward note: this is for Winship driveway work.",
    ].join("\n"),
    fallbackIso: "2026-03-13T22:15:00.000Z",
    fromHeader: '"Grounded Siteworks" <billing@groundedsiteworks.com>',
    subject: "QuickBooks: Invoice 1042 for Winship",
    vendorHints: ["Grounded Siteworks", "QuickBooks", "HCB"],
  });

  assertEquals(record.vendor, "Grounded Siteworks");
  assertEquals(record.vendor_normalized, "grounded siteworks");
  assertEquals(record.amount.total, 12500);
  assertEquals(record.invoice_or_transaction, "1042");
  assertEquals(record.receipt_date, "2026-03-13");
  assertEquals(record.project_id, "11111111-1111-4111-8111-111111111111");
  assertEquals(record.job_name, "Winship Residence");
  assertEquals(record.matched_project_alias, "Winship");
  assertEquals(record.confidence >= 0.8, true);
  assertExists(record.body_excerpt);
});

Deno.test("extractReceiptRecord falls back to header vendor when no vendor hint matches", () => {
  const record = extractReceiptRecord({
    aliasRows: ALIASES,
    bodyText: "Date: 2026-03-10\nTotal: $4,103.22\nWoodbery framing package",
    fallbackIso: "2026-03-10T15:00:00.000Z",
    fromHeader: '"Carter Lumber" <ar@carterlumber.com>',
    subject: "Statement for Woodbery",
    vendorHints: ["Accent Granite"],
  });

  assertEquals(record.vendor, "Carter Lumber");
  assertEquals(record.vendor_normalized, "carter lumber");
  assertEquals(record.amount.total, 4103.22);
  assertEquals(record.project_id, "22222222-2222-4222-8222-222222222222");
});

Deno.test("extractInvoiceOrTransaction does not capture the tail of invoice", () => {
  const invoice = extractInvoiceOrTransaction(
    "Invoice attached",
    "Please see invoice for the updated framing package.",
  );

  assertEquals(invoice, null);
});

Deno.test("decodeGmailMessageText tolerates malformed base64", () => {
  const warnings: string[] = [];
  const decoded = decodeGmailMessageText({
    mimeType: "text/plain",
    body: { data: "!!!not-base64!!!" },
  }, warnings);

  assertEquals(decoded, "");
  assertEquals(warnings.length, 1);
});

Deno.test("extractReceiptRecord rejects impossible calendar dates", () => {
  const record = extractReceiptRecord({
    aliasRows: ALIASES,
    bodyText: "Invoice Date: 2026-02-31\nAmount Due: $99.00\nWinship fixture charge",
    fallbackIso: null,
    fromHeader: '"Grounded Siteworks" <billing@groundedsiteworks.com>',
    subject: "Invoice 9001 for Winship",
    vendorHints: ["Grounded Siteworks"],
  });

  assertEquals(record.receipt_date, null);
});

Deno.test("extractReceiptRecord prefers the subject project over body alias drift", () => {
  const record = extractReceiptRecord({
    aliasRows: ALIASES,
    bodyText: "Woodbery invoice attached for site prep.",
    fallbackIso: "2026-03-14T12:00:00.000Z",
    fromHeader: '"Carter Lumber" <billing@carterlumber.com>',
    subject: "Invoice 2044 for Winship",
    vendorHints: ["Carter Lumber"],
  });

  assertEquals(record.project_id, "11111111-1111-4111-8111-111111111111");
  assertEquals(record.job_name, "Winship Residence");
  assertEquals(record.matched_project_alias, "Winship");
  assertEquals(record.reasons.includes("project:subject_alias_match"), true);
});

Deno.test("extractReceiptRecord prefers a real vendor hint over HCB in forwarded mail", () => {
  const record = extractReceiptRecord({
    aliasRows: ALIASES,
    bodyText: "Forwarded from HCB. Invoice # 7788. Total Due: $4,500.00 for Woodbery.",
    fallbackIso: "2026-03-14T12:00:00.000Z",
    fromHeader: '"QuickBooks" <quickbooks@notification.intuit.com>',
    subject: "Fwd: Carter Lumber invoice for Woodbery",
    vendorHints: ["HCB", "Carter Lumber", "QuickBooks"],
  });

  assertEquals(record.vendor, "Carter Lumber");
  assertEquals(record.vendor_normalized, "carter lumber");
});

// --- Forwarded-vendor attribution regression tests (E-5 fix) ---

Deno.test("extractVendor suppresses From header when domain matches mailbox owner", () => {
  const result = extractVendor(
    '"Heartwood Custom Builders" <noreply@heartwoodcustombuilders.com>',
    "Fwd: Carter Lumber Invoice 2044",
    "Please see attached invoice from Carter Lumber for framing package.",
    [],
    "heartwoodcustombuilders.com",
  );

  assertEquals(result.source, "from_header_suppressed_owner_domain");
  assertEquals(result.vendor, null);
});

Deno.test("extractVendor finds vendor hint via normalized match when raw match fails", () => {
  // "Carter Lumber" hint should match even when the body has slightly different formatting
  const result = extractVendor(
    '"Heartwood Custom Builders" <noreply@heartwoodcustombuilders.com>',
    "Fwd: Invoice for framing",
    "Invoice from Carter  Lumber LLC for the Winship framing package.",
    ["Carter Lumber"],
    "heartwoodcustombuilders.com",
  );

  assertEquals(result.vendor, "Carter Lumber");
  assertEquals(result.vendor_normalized, "carter lumber");
  assertEquals(result.source, "vendor_hint");
});

Deno.test("extractVendor rejects accounting boilerplate terms as vendor names", () => {
  const result = extractVendor(
    '"Accounts Receivable" <ar@example.com>',
    "Statement",
    "Your statement is attached.",
    [],
    null,
  );

  assertEquals(result.source, "from_header_rejected_boilerplate");
  assertEquals(result.vendor, null);
});

Deno.test("extractReceiptRecord threads mailboxDomain to suppress forwarded HCB vendor", () => {
  const record = extractReceiptRecord({
    aliasRows: ALIASES,
    bodyText: "Invoice from Carter Lumber. Total Due: $4,103.22. Woodbery framing package.",
    fallbackIso: "2026-03-14T12:00:00.000Z",
    fromHeader: '"Heartwood Custom Builders" <noreply@heartwoodcustombuilders.com>',
    mailboxDomain: "heartwoodcustombuilders.com",
    subject: "Fwd: Carter Lumber Invoice for Woodbery",
    vendorHints: ["Carter Lumber", "HCB"],
  });

  assertEquals(record.vendor, "Carter Lumber");
  assertEquals(record.vendor_normalized, "carter lumber");
});

// --- BuilderTrend internal notification regression tests ---

Deno.test("extractVendor rejects concatenated internal vendor name from BuilderTrend", () => {
  const result = extractVendor(
    '"heartwoodcustombuildersllc" <heartwoodcustombuildersllc@buildertrend.com>',
    "Invoice Created - _Test_Job",
    "An invoice has been created for _Test_Job. Amount: $27,530.00",
    [],
    null,
  );

  assertEquals(result.source, "from_header_rejected_internal_vendor");
  assertEquals(result.vendor, null);
});

Deno.test("extractVendor rejects 'Heartwood Custom Builders LLC' display name as internal vendor", () => {
  const result = extractVendor(
    '"Heartwood Custom Builders LLC" <notifications@buildertrend.com>',
    "Invoice Updated",
    "An invoice has been updated. Total: $48,480.56",
    [],
    null,
  );

  assertEquals(result.source, "from_header_rejected_internal_vendor");
  assertEquals(result.vendor, null);
});

Deno.test("extractVendor rejects QuickBooks as forwarding platform boilerplate", () => {
  const result = extractVendor(
    '"QuickBooks" <quickbooks@notification.intuit.com>',
    "New payment request from TLP Construction, LLC - invoice 895",
    "You have a new payment request. Amount Due: $14,925.00",
    [],
    null,
  );

  assertEquals(result.source, "from_header_rejected_boilerplate");
  assertEquals(result.vendor, null);
});

Deno.test("extractVendor still uses From header when domain does NOT match mailbox", () => {
  const result = extractVendor(
    '"Carter Lumber" <billing@carterlumber.com>',
    "Invoice 2044",
    "Your invoice is attached.",
    [],
    "heartwoodcustombuilders.com",
  );

  assertEquals(result.vendor, "Carter Lumber");
  assertEquals(result.vendor_normalized, "carter lumber");
  assertEquals(result.source, "from_header");
});

// --- DB-backed vendor registry override tests ---

Deno.test("extractVendor uses registry rejectSet override instead of hardcoded VENDOR_REJECT_TERMS", () => {
  // "billing" is in hardcoded VENDOR_REJECT_TERMS but NOT in our custom set
  const customRejectSet = new Set(["custom blocker"]);
  const result = extractVendor(
    '"Billing" <billing@example.com>',
    "Invoice",
    "Your invoice is attached.",
    [],
    null,
    { rejectSet: customRejectSet },
  );

  // "billing" should NOT be rejected because it's not in the custom set
  assertEquals(result.vendor, "Billing");
  assertEquals(result.source, "from_header");
});

Deno.test("extractVendor uses registry internalPatterns override", () => {
  // "hcb" is caught by hardcoded INTERNAL_VENDOR_PATTERNS but not by our custom list
  const customPatterns = [/^acme$/];
  const result = extractVendor(
    '"HCB" <info@hcb.llc>',
    "Statement",
    "Your statement.",
    [],
    null,
    { rejectSet: new Set(), internalPatterns: customPatterns },
  );

  // With empty rejectSet and custom internalPatterns that don't match "hcb",
  // the vendor should pass through
  assertEquals(result.vendor, "HCB");
  assertEquals(result.source, "from_header");
});
