/**
 * Words that should never be accepted as invoice/transaction identifiers.
 * These are common English words, financial keywords, and fragments of
 * keywords that the previous regex would incorrectly capture.
 */
export const GARBAGE_INVOICE_PATTERNS = new Set([
  // Keyword fragments (tail of "invoice", "selected", etc.)
  "oice",
  "voice",
  "lected",
  "ment",
  "tion",
  "ount",
  // Document type keywords
  "invoice",
  "receipt",
  "statement",
  "payment",
  "amount",
  "balance",
  "total",
  "subtotal",
  "due",
  "paid",
  "charge",
  "transaction",
  "order",
  "billing",
  "account",
  // Common English words
  "the",
  "this",
  "that",
  "from",
  "for",
  "your",
  "you",
  "was",
  "has",
  "been",
  "are",
  "were",
  "will",
  "have",
  "with",
  "and",
  "but",
  "not",
  "our",
  "its",
  "all",
  "new",
  "one",
  "two",
  "per",
  "via",
  "see",
  "may",
  // Pronouns and articles
  "his",
  "her",
  "him",
  "she",
  "they",
  "them",
  "who",
  // Common email/financial verbs
  "sent",
  "send",
  "view",
  "click",
  "open",
  "pay",
  "please",
  "thank",
  "thanks",
  "dear",
  "hello",
  "here",
  // Additional financial/document nouns
  "codes",
  "code",
  "number",
  "date",
  "item",
  "items",
  "price",
  "detail",
  "details",
  "description",
  "quantity",
  "rate",
  "notes",
  "note",
  "terms",
  "credit",
  "debit",
  "memo",
  "check",
  "status",
  "type",
  "name",
  "simple",
  "ready",
  "pending",
  "customer",
  "company",
  "service",
  "services",
  "monthly",
  "annual",
  "renewal",
  "subscription",
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
