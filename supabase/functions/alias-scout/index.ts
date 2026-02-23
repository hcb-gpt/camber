/**
 * alias-scout Edge Function v1.0.0
 * Discovery job: finds and suggests new aliases for projects.
 *
 * @version 1.0.0
 * @date 2026-02-16
 * @purpose Discover candidate aliases from project metadata and transcripts
 *
 * Called by: Claude agents (Agent Teams), cron
 * Auth: Internal pattern (X-Edge-Secret + source allowlist) OR service_role key
 * verify_jwt = false (config.toml)
 *
 * Three discovery sources:
 *   A) Projects with zero aliases
 *   B) Projects with only auto-generated aliases
 *   C) Transcript mining (frequently mentioned terms near attributed projects)
 *
 * Write path (if not dry_run):
 *   suggested_aliases: INSERT with ON CONFLICT DO NOTHING
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { emitLineage } from "../_shared/lineage.ts";

// ============================================================
// TYPES
// ============================================================

interface AliasScoutRequest {
  batch_size?: number;
  dry_run?: boolean;
  source_filter?: "zero_aliases" | "auto_only" | "transcript_mining" | null;
}

interface Candidate {
  project_id: string;
  alias: string;
  alias_type: string;
  source: "alias-scout";
  confidence: number;
  rationale: string;
  evidence: Record<string, unknown>;
}

const MAX_BATCH = 100;
const DEFAULT_BATCH = 50;
const VERSION = "alias-scout_v1.0.0";
const ALLOWED_SOURCES = [
  "agent-teams",
  "claude-chat",
  "alias-scout",
  "cron",
  "test",
];

// Auto-generated alias types that indicate a project needs enrichment
const AUTO_ALIAS_TYPES = [
  "name_stem",
  "client_first_name",
  "client_last_name",
  "auto_trigger",
];

// ============================================================
// MAIN
// ============================================================

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(),
    });
  }

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "POST_ONLY" }, 405);
  }

  // ========================================
  // 1. AUTH
  // ========================================
  const authResult = authenticateRequest(req);
  if (!authResult.ok) {
    return authErrorResponse(authResult.error_code!, authResult.detail);
  }

  // ========================================
  // 2. PARSE + VALIDATE BODY
  // ========================================
  let body: AliasScoutRequest;
  try {
    body = await req.json();
  } catch {
    // Allow empty body (all defaults)
    body = {};
  }

  const batchSize = Math.min(
    Math.max(1, body.batch_size ?? DEFAULT_BATCH),
    MAX_BATCH,
  );
  const dryRun = body.dry_run ?? false;
  const sourceFilter = body.source_filter ?? null;

  // ========================================
  // 3. INIT DB CLIENT
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ========================================
  // 4. RUN DISCOVERY SOURCES
  // ========================================
  const allCandidates: Candidate[] = [];
  const bySource = { zero_aliases: 0, auto_only: 0, transcript_mining: 0 };

  // Load existing aliases and contact names for dedup
  const existingAliases = await loadExistingAliases(db);
  const contactNames = await loadContactNames(db);

  // Source A: Projects with zero aliases
  if (!sourceFilter || sourceFilter === "zero_aliases") {
    const candidates = await discoverZeroAliases(db, batchSize);
    bySource.zero_aliases = candidates.length;
    allCandidates.push(...candidates);
  }

  // Source B: Projects with only auto-generated aliases
  if (!sourceFilter || sourceFilter === "auto_only") {
    const remaining = batchSize - allCandidates.length;
    if (remaining > 0) {
      const candidates = await discoverAutoOnly(db, remaining);
      bySource.auto_only = candidates.length;
      allCandidates.push(...candidates);
    }
  }

  // Source C: Transcript mining
  if (!sourceFilter || sourceFilter === "transcript_mining") {
    const remaining = batchSize - allCandidates.length;
    if (remaining > 0) {
      const candidates = await discoverTranscriptMining(
        db,
        remaining,
        existingAliases,
        contactNames,
      );
      bySource.transcript_mining = candidates.length;
      allCandidates.push(...candidates);
    }
  }

  // ========================================
  // 5. DEDUP against existing aliases
  // ========================================
  const deduped = allCandidates.filter(
    (c) => !existingAliases.has(aliasKey(c.project_id, c.alias)),
  );

  // ========================================
  // 6. INSERT (if not dry_run)
  // ========================================
  let insertedCount = 0;
  if (!dryRun && deduped.length > 0) {
    insertedCount = await insertCandidates(db, deduped);
  }

  // ========================================
  // 7. RESPONSE
  // ========================================
  const elapsed = Date.now() - t0;
  console.log(
    `[alias-scout] dry_run=${dryRun} found=${deduped.length} inserted=${insertedCount} ms=${elapsed}`,
  );

  // RUNTIME LINEAGE (fire-and-forget)
  try {
    const lineageEdges: { from: string; to: string; type: string }[] = [
      { from: "edge:alias-scout", to: "table:public.projects", type: "reads" },
      { from: "edge:alias-scout", to: "table:public.project_aliases", type: "reads" },
      { from: "edge:alias-scout", to: "table:public.suggested_aliases", type: "reads" },
      { from: "edge:alias-scout", to: "table:public.contacts", type: "reads" },
      { from: "edge:alias-scout", to: "table:public.span_attributions", type: "reads" },
    ];
    if (!dryRun && insertedCount > 0) {
      lineageEdges.push({
        from: "edge:alias-scout",
        to: "table:public.suggested_aliases",
        type: "writes",
      });
    }
    emitLineage(db, {
      slug: "alias-scout",
      version: VERSION,
      edges: lineageEdges,
      metadata: { dry_run: dryRun },
    });
  } catch { /* lineage must never block */ }

  return jsonResponse({
    ok: true,
    version: VERSION,
    dry_run: dryRun,
    candidates_found: deduped.length,
    candidates_inserted: insertedCount,
    by_source: bySource,
    candidates: deduped,
    ms: elapsed,
  }, 200);
});

// ============================================================
// SOURCE A: Projects with zero aliases
// ============================================================

async function discoverZeroAliases(
  // deno-lint-ignore no-explicit-any
  db: any,
  limit: number,
): Promise<Candidate[]> {
  // Get candidate projects: client projects in active statuses
  // with empty or null aliases array. Over-fetch to filter post-query.
  const { data: projects, error } = await db
    .from("projects")
    .select("id, name, address, aliases")
    .eq("project_kind", "client")
    .in("status", ["active", "warranty", "estimating"])
    .or("aliases.is.null,aliases.eq.{}")
    .limit(limit * 2);

  if (error || !projects) {
    console.error("[alias-scout] Source A query error:", error?.message);
    return [];
  }

  // Filter to those with no project_aliases rows
  const candidates: Candidate[] = [];
  for (const p of projects) {
    if (candidates.length >= limit) break;

    const { count } = await db
      .from("project_aliases")
      .select("id", { count: "exact", head: true })
      .eq("project_id", p.id);

    if (count === 0) {
      candidates.push(
        ...generateFromMetadata(
          p.id,
          p.name,
          p.address,
          "zero_aliases",
        ),
      );
    }
  }

  return candidates.slice(0, limit);
}

// ============================================================
// SOURCE B: Projects with only auto-generated aliases
// ============================================================

async function discoverAutoOnly(
  // deno-lint-ignore no-explicit-any
  db: any,
  limit: number,
): Promise<Candidate[]> {
  // Find projects where ALL aliases are auto-generated types
  const { data: projects, error } = await db
    .from("projects")
    .select("id, name, address, aliases")
    .eq("project_kind", "client")
    .in("status", ["active", "warranty", "estimating"])
    .limit(limit * 3);

  if (error || !projects) {
    console.error("[alias-scout] Source B query error:", error?.message);
    return [];
  }

  const candidates: Candidate[] = [];

  for (const p of projects) {
    if (candidates.length >= limit) break;

    // Check if project has aliases but all are auto-generated
    const { data: aliases } = await db
      .from("project_aliases")
      .select("alias_type, source")
      .eq("project_id", p.id);

    if (!aliases || aliases.length === 0) continue; // skip: Source A handles zero-alias

    const allAuto = aliases.every(
      (a: Record<string, unknown>) =>
        AUTO_ALIAS_TYPES.includes(a.alias_type as string) ||
        a.source === "auto_trigger",
    );

    if (allAuto) {
      const enriched = generateEnrichmentAliases(
        p.id,
        p.name,
        p.address,
      );
      candidates.push(...enriched);
    }
  }

  return candidates.slice(0, limit);
}

// ============================================================
// SOURCE C: Transcript mining
// ============================================================

async function discoverTranscriptMining(
  // deno-lint-ignore no-explicit-any
  db: any,
  limit: number,
  existingAliases: Set<string>,
  contactNames: Set<string>,
): Promise<Candidate[]> {
  // Find frequently mentioned terms in transcripts near attributed projects
  // Look at span_attributions from the last 30 days joined with conversation_spans
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
    .toISOString();

  const { data: spans, error } = await db
    .from("span_attributions")
    .select(`
      applied_project_id,
      span:span_id (
        transcript_segment,
        interaction_id
      )
    `)
    .not("applied_project_id", "is", null)
    .gte("attributed_at", thirtyDaysAgo)
    .limit(500);

  if (error || !spans) {
    console.error(
      "[alias-scout] Source C query error:",
      error?.message,
    );
    return [];
  }

  // Validate project IDs are still active before processing
  const rawProjectIds = [
    ...new Set(
      spans
        .filter((r: Record<string, unknown>) => r.applied_project_id)
        .map((r: Record<string, unknown>) => r.applied_project_id as string),
    ),
  ];
  const { data: validProjects } = await db
    .from("projects")
    .select("id")
    .in("id", rawProjectIds)
    .in("status", ["active", "warranty", "estimating"])
    .eq("project_kind", "client");

  const validProjectIds = new Set(
    (validProjects || []).map((p: { id: string }) => p.id),
  );

  // Group transcript segments by project (only active projects)
  const projectTerms: Map<string, Map<string, Set<string>>> = new Map();

  for (const row of spans) {
    const projectId = row.applied_project_id as string;
    if (!validProjectIds.has(projectId)) continue;
    const span = row.span as Record<string, unknown> | null;
    if (!span?.transcript_segment) continue;

    const text = span.transcript_segment as string;
    const interactionId = span.interaction_id as string;

    // Extract potential alias terms (capitalized words, 4+ chars)
    const terms = extractTerms(text);

    if (!projectTerms.has(projectId)) {
      projectTerms.set(projectId, new Map());
    }
    const termMap = projectTerms.get(projectId)!;

    for (const term of terms) {
      if (!termMap.has(term)) {
        termMap.set(term, new Set());
      }
      termMap.get(term)!.add(interactionId);
    }
  }

  // Filter: term appears in >= 3 distinct transcripts, not already an alias, not a contact name
  const candidates: Candidate[] = [];

  for (const [projectId, termMap] of projectTerms) {
    for (const [term, interactions] of termMap) {
      if (candidates.length >= limit) break;
      if (interactions.size < 3) continue;
      if (term.length < 4) continue;

      const lower = term.toLowerCase();

      // Skip if already an alias for this project
      if (existingAliases.has(aliasKey(projectId, lower))) continue;

      // Skip if it's a contact name
      if (contactNames.has(lower)) continue;

      // Skip common words
      if (STOP_WORDS.has(lower)) continue;

      const confidence = Math.min(
        0.4 + (interactions.size - 3) * 0.1,
        0.8,
      );

      candidates.push({
        project_id: projectId,
        alias: lower,
        alias_type: "transcript_mined",
        source: "alias-scout",
        confidence,
        rationale: `Term "${lower}" appears in ${interactions.size} distinct transcripts for this project`,
        evidence: {
          extraction_method: "transcript_mining",
          distinct_transcripts: interactions.size,
          sample_interaction_ids: [...interactions].slice(0, 3),
        },
      });
    }
    if (candidates.length >= limit) break;
  }

  return candidates.slice(0, limit);
}

// ============================================================
// ALIAS GENERATION HELPERS
// ============================================================

function generateFromMetadata(
  projectId: string,
  projectName: string,
  address: string | null,
  sourceTag: string,
): Candidate[] {
  const candidates: Candidate[] = [];

  // Extract name stem: "Woodbery Residence" -> "woodbery"
  const nameParts = projectName.trim().split(/\s+/);
  if (nameParts.length > 0) {
    // Use first word as name stem (typically the client/location name)
    const stem = nameParts[0].toLowerCase().replace(/[^a-z0-9]/g, "");
    if (stem.length >= 3) {
      candidates.push({
        project_id: projectId,
        alias: stem,
        alias_type: "name_stem",
        source: "alias-scout",
        confidence: 0.7,
        rationale: `Project has ${
          sourceTag === "zero_aliases" ? "zero" : "only auto"
        } aliases, extracted stem from project name`,
        evidence: {
          extraction_method: "name_stem",
          project_name: projectName,
        },
      });
    }

    // If multi-word name, also suggest the last name part if different from common suffixes
    if (nameParts.length >= 2) {
      const lastPart = nameParts[nameParts.length - 1].toLowerCase().replace(
        /[^a-z0-9]/g,
        "",
      );
      if (
        lastPart.length >= 3 &&
        lastPart !== stem &&
        !PROJECT_SUFFIXES.has(lastPart)
      ) {
        candidates.push({
          project_id: projectId,
          alias: lastPart,
          alias_type: "name_stem",
          source: "alias-scout",
          confidence: 0.6,
          rationale: `Secondary name component from project name "${projectName}"`,
          evidence: {
            extraction_method: "name_stem",
            project_name: projectName,
            component: "last_word",
          },
        });
      }
    }
  }

  // Extract from address if available
  if (address && address.trim().length > 0) {
    const streetName = extractStreetName(address);
    if (streetName && streetName.length >= 3) {
      candidates.push({
        project_id: projectId,
        alias: streetName.toLowerCase(),
        alias_type: "street_name",
        source: "alias-scout",
        confidence: 0.6,
        rationale: `Street name extracted from project address`,
        evidence: {
          extraction_method: "street_name",
          address,
        },
      });
    }
  }

  return candidates;
}

function generateEnrichmentAliases(
  projectId: string,
  projectName: string,
  address: string | null,
): Candidate[] {
  const candidates: Candidate[] = [];

  // Combine client name + street for enrichment
  const nameParts = projectName.trim().split(/\s+/);
  const stem = nameParts[0]?.toLowerCase().replace(/[^a-z0-9]/g, "") || "";

  if (address && address.trim().length > 0) {
    const streetName = extractStreetName(address);
    if (streetName && streetName.length >= 3 && stem.length >= 3) {
      // Combined alias: "woodbery-elm" style
      const combined = `${stem}-${streetName.toLowerCase()}`;
      if (combined.length >= 7) {
        candidates.push({
          project_id: projectId,
          alias: combined,
          alias_type: "client_name",
          source: "alias-scout",
          confidence: 0.5,
          rationale: `Enrichment alias combining client name + street for project with only auto aliases`,
          evidence: {
            extraction_method: "name_street_combo",
            project_name: projectName,
            address,
          },
        });
      }
    }

    // Also suggest standalone street name if not already covered
    if (streetName && streetName.length >= 3) {
      candidates.push({
        project_id: projectId,
        alias: streetName.toLowerCase(),
        alias_type: "street_name",
        source: "alias-scout",
        confidence: 0.5,
        rationale: `Street name enrichment for project with only auto aliases`,
        evidence: {
          extraction_method: "street_name",
          address,
        },
      });
    }
  }

  return candidates;
}

function extractStreetName(address: string): string | null {
  // Try to extract the street name from an address like "123 Elm Street, City, ST"
  const match = address.match(
    /^\d+\s+(?:N|S|E|W|North|South|East|West)?\s*(.+?)(?:\s+(?:St|Street|Ave|Avenue|Blvd|Boulevard|Dr|Drive|Ln|Lane|Rd|Road|Ct|Court|Way|Pl|Place|Cir|Circle|Ter|Terrace|Trl|Trail|Pkwy|Parkway)\.?)?(?:,|$)/i,
  );
  if (match?.[1]) {
    // Clean up and return just the street name portion
    const name = match[1].trim().replace(/[^a-zA-Z0-9\s-]/g, "");
    const parts = name.split(/\s+/);
    // Return first significant word
    return parts[0] || null;
  }
  return null;
}

function extractTerms(text: string): string[] {
  // Extract potential alias terms: words that are 4+ chars, not purely numeric
  const words = text.split(/[\s,."!?;:()\[\]{}]+/);
  const terms: string[] = [];
  for (const w of words) {
    const clean = w.replace(/[^a-zA-Z0-9'-]/g, "");
    if (clean.length >= 4 && !/^\d+$/.test(clean)) {
      terms.push(clean.toLowerCase());
    }
  }
  return [...new Set(terms)];
}

// ============================================================
// DATA LOADING HELPERS
// ============================================================

async function loadExistingAliases(
  // deno-lint-ignore no-explicit-any
  db: any,
): Promise<Set<string>> {
  const keys = new Set<string>();

  // Load from project_aliases table
  const { data: paRows } = await db
    .from("project_aliases")
    .select("project_id, alias");

  if (paRows) {
    for (const r of paRows) {
      keys.add(aliasKey(r.project_id, (r.alias as string).toLowerCase()));
    }
  }

  // Load from projects.aliases array
  const { data: projRows } = await db
    .from("projects")
    .select("id, aliases")
    .not("aliases", "is", null);

  if (projRows) {
    for (const r of projRows) {
      const arr = r.aliases as string[] | null;
      if (arr) {
        for (const a of arr) {
          keys.add(aliasKey(r.id, a.toLowerCase()));
        }
      }
    }
  }

  // Load from suggested_aliases (pending ones to avoid re-suggesting)
  const { data: saRows } = await db
    .from("suggested_aliases")
    .select("project_id, alias")
    .eq("status", "pending");

  if (saRows) {
    for (const r of saRows) {
      keys.add(aliasKey(r.project_id, (r.alias as string).toLowerCase()));
    }
  }
  // If suggested_aliases doesn't exist yet, the query silently returns null -- that's fine

  return keys;
}

async function loadContactNames(
  // deno-lint-ignore no-explicit-any
  db: any,
): Promise<Set<string>> {
  const names = new Set<string>();

  const { data: contacts } = await db
    .from("contacts")
    .select("name, aliases");

  if (contacts) {
    for (const c of contacts) {
      if (c.name) {
        // Add full name and individual parts
        names.add((c.name as string).toLowerCase());
        for (const part of (c.name as string).split(/\s+/)) {
          if (part.length >= 3) {
            names.add(part.toLowerCase());
          }
        }
      }
      const arr = c.aliases as string[] | null;
      if (arr) {
        for (const a of arr) {
          names.add(a.toLowerCase());
        }
      }
    }
  }

  return names;
}

// ============================================================
// INSERT CANDIDATES
// ============================================================

async function insertCandidates(
  // deno-lint-ignore no-explicit-any
  db: any,
  candidates: Candidate[],
): Promise<number> {
  const rows = candidates.map((c) => ({
    project_id: c.project_id,
    alias: c.alias,
    alias_type: c.alias_type,
    source: c.source,
    confidence: c.confidence,
    status: "pending",
    rationale: c.rationale,
    evidence: c.evidence,
    suggested_at: new Date().toISOString(),
  }));

  const { data, error } = await db
    .from("suggested_aliases")
    .upsert(rows, { onConflict: "project_id,alias,status", ignoreDuplicates: true })
    .select("id");

  if (error) {
    // Table may not exist yet -- log and return 0
    console.error(
      "[alias-scout] Insert error (table may not exist yet):",
      error.message,
    );
    return 0;
  }

  return data?.length ?? 0;
}

// ============================================================
// AUTH HELPER
// ============================================================

interface ExtendedAuthResult {
  ok: boolean;
  error_code?: string;
  detail?: string;
  method?: string;
}

function authenticateRequest(req: Request): ExtendedAuthResult {
  // Method 1: X-Edge-Secret (internal agent pattern)
  const edgeSecret = req.headers.get("X-Edge-Secret");
  if (edgeSecret) {
    const result = requireEdgeSecret(req, ALLOWED_SOURCES);
    if (result.ok) {
      return { ok: true, method: "edge_secret", detail: result.source };
    }
    return {
      ok: false,
      error_code: result.error_code,
      detail: `edge_secret: ${result.error_code}`,
    };
  }

  // Method 2: Service role key in Authorization header
  const authHeader = req.headers.get("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.replace("Bearer ", "");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (serviceRoleKey && token === serviceRoleKey) {
      return { ok: true, method: "service_role" };
    }
    return {
      ok: false,
      error_code: "invalid_auth_token",
      detail: "Only service_role key or X-Edge-Secret accepted",
    };
  }

  return {
    ok: false,
    error_code: "missing_edge_secret",
    detail: "Provide X-Edge-Secret header or Authorization: Bearer <service_role_key>",
  };
}

// ============================================================
// GENERAL HELPERS
// ============================================================

function aliasKey(projectId: string, alias: string): string {
  return `${projectId}::${alias.toLowerCase()}`;
}

function jsonResponse(
  data: Record<string, unknown>,
  status: number,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, x-source, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

// Common project name suffixes to skip when extracting aliases
const PROJECT_SUFFIXES = new Set([
  "residence",
  "project",
  "build",
  "home",
  "house",
  "renovation",
  "remodel",
  "addition",
  "construction",
  "custom",
  "new",
  "lot",
  "phase",
  "unit",
]);

// Stop words to skip in transcript mining
const STOP_WORDS = new Set([
  "that",
  "this",
  "with",
  "from",
  "have",
  "they",
  "been",
  "were",
  "will",
  "would",
  "could",
  "should",
  "about",
  "there",
  "their",
  "them",
  "then",
  "than",
  "what",
  "when",
  "where",
  "which",
  "while",
  "these",
  "those",
  "other",
  "some",
  "just",
  "also",
  "very",
  "much",
  "more",
  "most",
  "like",
  "going",
  "want",
  "need",
  "know",
  "think",
  "look",
  "make",
  "come",
  "take",
  "give",
  "tell",
  "call",
  "work",
  "back",
  "over",
  "down",
  "only",
  "into",
  "year",
  "your",
  "yeah",
  "okay",
  "right",
  "well",
  "good",
  "here",
  "don't",
  "didn't",
  "doesn't",
  "can't",
  "won't",
  "isn't",
  "aren't",
  "wasn't",
  "weren't",
]);
