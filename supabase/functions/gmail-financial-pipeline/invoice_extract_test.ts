import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { isGarbageInvoice } from "./invoice_extract.ts";

Deno.test("isGarbageInvoice rejects keyword fragments", () => {
  // These are real garbage values from production gmail_financial_receipts
  assertEquals(isGarbageInvoice("oice"), true); // tail of "invoice"
  assertEquals(isGarbageInvoice("lected"), true); // tail of "selected"
  assertEquals(isGarbageInvoice("this"), true); // common pronoun
  assertEquals(isGarbageInvoice("from"), true); // preposition
  assertEquals(isGarbageInvoice("amount"), true); // financial keyword
  assertEquals(isGarbageInvoice("receipt"), true); // document keyword
  assertEquals(isGarbageInvoice("invoice"), true); // document keyword
  assertEquals(isGarbageInvoice("payment"), true); // document keyword
  assertEquals(isGarbageInvoice("the"), true); // article
  assertEquals(isGarbageInvoice("for"), true); // preposition
  assertEquals(isGarbageInvoice("your"), true); // pronoun
  assertEquals(isGarbageInvoice("was"), true); // verb
  assertEquals(isGarbageInvoice("has"), true); // verb
  assertEquals(isGarbageInvoice("been"), true); // verb
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

Deno.test("isGarbageInvoice rejects pure short alphabetic strings", () => {
  assertEquals(isGarbageInvoice("test"), true); // 4 alpha chars
  assertEquals(isGarbageInvoice("abcd"), true); // 4 alpha chars
  assertEquals(isGarbageInvoice("ABCD"), true); // 4 alpha CAPS
});

Deno.test("isGarbageInvoice allows 5+ char alphabetic strings", () => {
  // These could be valid reference codes
  assertEquals(isGarbageInvoice("HUNTERST1"), false);
  assertEquals(isGarbageInvoice("WAGGINTAILS4"), false);
});
