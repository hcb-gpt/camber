import {
  type AliasRow,
  decodeGmailMessageText,
  extractAmount,
  extractInvoiceOrTransaction,
  extractReceiptRecord,
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
