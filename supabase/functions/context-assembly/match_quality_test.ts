/**
 * Match Quality / Phonetic-Adjacent-Only Unit Tests
 *
 * RULE: First-name-only phonetic match = "possible" only, never auto-merge.
 * RULE: Short tokens (<= 3 chars) skip phonetic entirely.
 * RULE: Substring matching is dead — word-boundary only.
 *
 * Run: deno test --allow-read match_quality_test.ts
 */

import { assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";

// ============================================================
// Copy of classifyMatchStrength from index.ts (standalone test)
// ============================================================
function classifyMatchStrength(
  term: string,
  matchType: string,
  projectName: string,
): "strong" | "weak" {
  const termLower = term.toLowerCase();
  const nameLower = projectName.toLowerCase();

  if (termLower === nameLower || matchType === "exact_project_name" || matchType === "name_match") return "strong";
  const isExplicitAddress = /\d/.test(termLower) ||
    /\b(?:st|street|ave|avenue|blvd|boulevard|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|pkwy|parkway|way)\b/
      .test(termLower);
  if (matchType === "city_or_location" || matchType === "location_match") {
    if (isExplicitAddress) return "strong";
    return "weak";
  }
  if (term.trim().includes(" ")) return "strong";

  const nameParts = nameLower.split(/\s+/);
  if (nameParts.length >= 2) {
    const lastName = nameParts[nameParts.length - 1];
    if (termLower === lastName) return "strong";
  }

  if (term.length >= 6 && (matchType === "alias" || matchType === "alias_match")) return "strong";

  return "weak";
}

// ============================================================
// Copy of findTermInText from index.ts (standalone test)
// ============================================================
function findTermInText(textLower: string, termLower: string): number {
  const idx = textLower.indexOf(termLower);
  if (idx < 0) return -1;
  const before = idx === 0 ? " " : textLower[idx - 1];
  const afterIdx = idx + termLower.length;
  const after = afterIdx >= textLower.length ? " " : textLower[afterIdx];
  const isWordChar = (ch: string) => /[a-z0-9]/i.test(ch);
  if (
    (isWordChar(before) || isWordChar(after)) &&
    before !== "'" && before !== "\u2019" &&
    after !== "'" && after !== "\u2019"
  ) {
    return -1;
  }
  return idx;
}

// ============================================================
// Copy of normalizeAliasTerms from index.ts (standalone test)
// ============================================================
function normalizeAliasTerms(terms: string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const t0 of terms) {
    const t = (t0 || "").trim();
    if (!t) continue;
    const low = t.toLowerCase();
    if (seen.has(low)) continue;
    if (low.length < 4) continue;
    seen.add(low);
    out.push(t);
  }
  return out;
}

// ============================================================
// TESTS: classifyMatchStrength
// ============================================================

Deno.test("classifyMatchStrength: exact project name = strong", () => {
  assertEquals(classifyMatchStrength("Madison Heights", "exact_project_name", "Madison Heights"), "strong");
  assertEquals(classifyMatchStrength("Bid Package Alpha", "name_match", "Bid Package Alpha"), "strong");
});

Deno.test("classifyMatchStrength: multi-word alias = strong", () => {
  assertEquals(classifyMatchStrength("Bob Smith", "alias", "Smithfield Project"), "strong");
  assertEquals(classifyMatchStrength("Well Road", "alias", "Well Road Renovation"), "strong");
});

Deno.test("classifyMatchStrength: city-only location match = weak", () => {
  assertEquals(classifyMatchStrength("Riverside", "city_or_location", "Riverside Project"), "weak");
  assertEquals(classifyMatchStrength("Denver", "location_match", "Denver Office Build"), "weak");
});

Deno.test("classifyMatchStrength: explicit address-like location match = strong", () => {
  assertEquals(classifyMatchStrength("123 Main Street", "city_or_location", "Riverside Project"), "strong");
  assertEquals(classifyMatchStrength("Broadway Ave", "location_match", "Denver Office Build"), "strong");
});

Deno.test("classifyMatchStrength: last-name component = strong", () => {
  assertEquals(classifyMatchStrength("heights", "alias", "Madison Heights"), "strong");
  assertEquals(classifyMatchStrength("wellington", "alias", "Duke Wellington"), "strong");
});

Deno.test("classifyMatchStrength: long alias (>= 6) = strong", () => {
  assertEquals(classifyMatchStrength("madiso", "alias", "Some Project"), "strong");
  assertEquals(classifyMatchStrength("wellsboro", "alias_match", "Some Project"), "strong");
});

Deno.test("classifyMatchStrength: SHORT TOKENS = weak (the critical case)", () => {
  // These are the exact tokens that caused false positives
  assertEquals(classifyMatchStrength("mad", "alias", "Madison Heights"), "weak");
  assertEquals(classifyMatchStrength("bob", "alias", "Bob's Hardware"), "weak");
  assertEquals(classifyMatchStrength("bid", "alias", "Bid Package Alpha"), "weak");
  assertEquals(classifyMatchStrength("well", "alias", "Wellington Project"), "weak");
  assertEquals(classifyMatchStrength("wade", "alias", "Wade Construction"), "weak");
});

Deno.test("classifyMatchStrength: first-name-only short = weak", () => {
  // "randy" (5 chars) as alias for "Randy Bryan" - first name only, < 6 chars
  assertEquals(classifyMatchStrength("randy", "alias", "Randy Bryan"), "weak");
  assertEquals(classifyMatchStrength("mark", "alias", "Mark Johnson"), "weak");
  assertEquals(classifyMatchStrength("john", "alias", "John Doe"), "weak");
});

Deno.test("classifyMatchStrength: db_scan short tokens = weak", () => {
  assertEquals(classifyMatchStrength("wade", "db_scan", "Wade Inc"), "weak");
  assertEquals(classifyMatchStrength("matt", "db_scan", "Matt's Place"), "weak");
});

// ============================================================
// TESTS: normalizeAliasTerms (short-token guard)
// ============================================================

Deno.test("normalizeAliasTerms: filters out tokens < 4 chars", () => {
  const result = normalizeAliasTerms(["bob", "mad", "bi", "well", "Madison", "Wellington"]);
  assertEquals(result, ["well", "Madison", "Wellington"]);
});

Deno.test("normalizeAliasTerms: keeps tokens >= 4 chars", () => {
  const result = normalizeAliasTerms(["wade", "mark", "john", "randy"]);
  assertEquals(result, ["wade", "mark", "john", "randy"]);
});

Deno.test("normalizeAliasTerms: deduplicates case-insensitively", () => {
  const result = normalizeAliasTerms(["Madison", "madison", "MADISON"]);
  assertEquals(result, ["Madison"]);
});

// ============================================================
// TESTS: findTermInText (word-boundary)
// ============================================================

Deno.test("findTermInText: exact word boundary match", () => {
  const text = "we are working at madison heights today";
  assertEquals(findTermInText(text, "madison heights") >= 0, true);
  assertEquals(findTermInText(text, "madison") >= 0, true);
});

Deno.test("findTermInText: rejects substring within word", () => {
  const text = "the madisonian architecture is impressive";
  assertEquals(findTermInText(text, "madison"), -1); // "madison" inside "madisonian"
});

Deno.test("findTermInText: rejects partial word matches (the critical false positives)", () => {
  // "mad" should NOT match inside "madison"
  assertEquals(findTermInText("we went to madison heights", "mad"), -1);
  // "bid" should NOT match inside "bident" or "bidirectional"
  assertEquals(findTermInText("bidirectional scanning", "bid"), -1);
  // "well" should NOT match inside "wellington"
  assertEquals(findTermInText("near wellington", "well"), -1);
});

Deno.test("findTermInText: allows standalone short words", () => {
  // "mad" as a standalone word DOES match (but normalizeAliasTerms would filter it)
  assertEquals(findTermInText("i am mad about it", "mad") >= 0, true);
  // "well" as a standalone word
  assertEquals(findTermInText("that is well done", "well") >= 0, true);
});

// ============================================================
// INTEGRATION: Short tokens should never reach matching due to normalizeAliasTerms
// ============================================================

Deno.test("integration: short tokens filtered before matching", () => {
  const aliases = ["mad", "Madison Heights", "MH", "bob"];
  const normalized = normalizeAliasTerms(aliases);

  // Only "Madison Heights" survives (mad=3, MH=2, bob=3 all filtered)
  assertEquals(normalized.length, 1);
  assertEquals(normalized[0], "Madison Heights");

  // Even if somehow a 4-char token like "wade" passes normalizeAliasTerms,
  // classifyMatchStrength will flag it as weak
  assertEquals(classifyMatchStrength("wade", "alias", "Wade Construction"), "weak");
});
