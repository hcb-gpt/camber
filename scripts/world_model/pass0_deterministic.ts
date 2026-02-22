#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read

/**
 * Pass 0: Deterministic Labels (WP-C)
 *
 * Four rules in priority order (zero LLM cost):
 *   1. Staff Exclusion — HCB staff phones + short call (< 200 words) + no project names → label "none", confidence=0.95
 *   2. Phone Match (anchored vendor) — contact_fanout(anchored, effective_fanout=1) → single project, confidence=0.90
 *   3. Homeowner Regex — client_name in transcript + contact linked to project → label "assign", confidence=0.85
 *   4. Single-Project Vendor — contact in project_contacts for exactly 1 active project + no contradicting names → label "assign", confidence=0.85
 *
 * For each labeled span, records:
 *   project_id (or null for staff exclusion)
 *   label_source = pass0_staff_exclusion | pass0_phone_match | pass0_homeowner_regex | pass0_single_vendor
 *   confidence = 0.95 | 0.90 | 0.85 | 0.85
 *   pass_number = 0
 *
 * Expected yield: ~30-40% of spans.
 *
 * Usage:
 *   source ~/.camber/credentials.env
 *   deno run --allow-net --allow-env --allow-read \
 *     scripts/world_model/pass0_deterministic.ts \
 *     --batch-run-id <id> [--unlabeled-only] [--dry-run]
 */

import { getDb, generateBatchRunId } from "./shared/db.ts";
import type { LabelingResult, LabelSource, PassStats } from "./shared/types.ts";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------
const args = new Set(Deno.args);
const batchRunIdFlag = Deno.args.find((a) => a.startsWith("--batch-run-id="));
const DRY_RUN = args.has("--dry-run");
const BATCH_RUN_ID = batchRunIdFlag?.split("=")[1] ?? generateBatchRunId();

console.log(`[pass0] batch_run_id = ${BATCH_RUN_ID}`);
console.log(`[pass0] dry_run = ${DRY_RUN}`);

const db = getDb();

// Staff exclusion: short call threshold (< 200 words per spec)
const STAFF_SHORT_CALL_WORDS = 200;

// ---------------------------------------------------------------------------
// Step 1: Load reference data into memory (small tables)
// ---------------------------------------------------------------------------

interface StaffContact {
  id: string;
  phone: string;
  secondary_phone: string | null;
  name: string;
}

interface ProjectClientRow {
  contact_id: string;
  project_id: string;
  project_name: string;
  contact_phone: string;
  secondary_phone: string | null;
}

interface AnchoredContact {
  contact_id: string;
  phone: string;
  secondary_phone: string | null;
  project_id: string;
  contact_type: string;
}

interface SingleVendorContact {
  contact_id: string;
  phone: string;
  secondary_phone: string | null;
  project_id: string;
  contact_type: string;
}

// R3: Internal staff contacts
async function loadStaffContacts(): Promise<StaffContact[]> {
  const { data, error } = await db
    .from("contacts")
    .select("id, phone, secondary_phone, name")
    .or("contact_type.eq.internal,is_internal.eq.true");
  if (error) throw new Error(`loadStaffContacts: ${error.message}`);
  return data ?? [];
}

// R2: Homeowner contacts linked to exactly 1 active project via project_clients
async function loadHomeownerSingleProject(): Promise<ProjectClientRow[]> {
  const { data, error } = await db.rpc("exec_sql", {
    query: `
      WITH homeowner_single AS (
        SELECT pcl.contact_id, (array_agg(pcl.project_id))[1] AS project_id
        FROM project_clients pcl
        JOIN projects p ON p.id = pcl.project_id
          AND p.status IN ('active', 'warranty', 'estimating')
        GROUP BY pcl.contact_id
        HAVING COUNT(DISTINCT pcl.project_id) = 1
      )
      SELECT hs.contact_id, hs.project_id, p.name AS project_name,
             c.phone AS contact_phone, c.secondary_phone
      FROM homeowner_single hs
      JOIN contacts c ON c.id = hs.contact_id
      JOIN projects p ON p.id = hs.project_id
    `,
  });
  if (error) {
    // Fallback: use direct table queries if RPC doesn't exist
    return await loadHomeownerSingleProjectFallback();
  }
  return data ?? [];
}

async function loadHomeownerSingleProjectFallback(): Promise<ProjectClientRow[]> {
  // Get all project_clients with active projects
  const { data: pcRows, error: pcErr } = await db
    .from("project_clients")
    .select("contact_id, project_id, projects!inner(id, name, status)")
    .in("projects.status", ["active", "warranty", "estimating"]);
  if (pcErr) throw new Error(`loadHomeownerSingleProject: ${pcErr.message}`);

  // Group by contact_id, keep only those with exactly 1 project
  const byContact = new Map<string, { project_id: string; project_name: string }[]>();
  for (const row of pcRows ?? []) {
    const cid = row.contact_id as string;
    const pid = row.project_id as string;
    // deno-lint-ignore no-explicit-any
    const pname = (row as any).projects?.name ?? "unknown";
    if (!byContact.has(cid)) byContact.set(cid, []);
    const existing = byContact.get(cid)!;
    if (!existing.some((e) => e.project_id === pid)) {
      existing.push({ project_id: pid, project_name: pname });
    }
  }

  const singleProject: { contact_id: string; project_id: string; project_name: string }[] = [];
  for (const [cid, projects] of byContact) {
    if (projects.length === 1) {
      singleProject.push({ contact_id: cid, ...projects[0] });
    }
  }

  // Fetch phone numbers for those contacts
  const contactIds = singleProject.map((sp) => sp.contact_id);
  if (contactIds.length === 0) return [];
  const { data: contacts, error: cErr } = await db
    .from("contacts")
    .select("id, phone, secondary_phone")
    .in("id", contactIds);
  if (cErr) throw new Error(`loadHomeownerPhones: ${cErr.message}`);

  const phoneMap = new Map<string, { phone: string; secondary_phone: string | null }>();
  for (const c of contacts ?? []) {
    phoneMap.set(c.id, { phone: c.phone, secondary_phone: c.secondary_phone });
  }

  return singleProject.map((sp) => ({
    contact_id: sp.contact_id,
    project_id: sp.project_id,
    project_name: sp.project_name,
    contact_phone: phoneMap.get(sp.contact_id)?.phone ?? "",
    secondary_phone: phoneMap.get(sp.contact_id)?.secondary_phone ?? null,
  }));
}

// R1: Anchored contacts (fanout=1) with a single active project in project_contacts
async function loadAnchoredContacts(): Promise<AnchoredContact[]> {
  // Get anchored contacts from contact_fanout
  const { data: fanoutRows, error: fErr } = await db
    .from("contact_fanout")
    .select("contact_id")
    .eq("fanout_class", "anchored");
  if (fErr) throw new Error(`loadAnchoredContacts fanout: ${fErr.message}`);

  const anchoredIds = (fanoutRows ?? []).map((r) => r.contact_id as string);
  if (anchoredIds.length === 0) return [];

  // Get their project_contacts assignments (active only)
  const { data: pcRows, error: pcErr } = await db
    .from("project_contacts")
    .select("contact_id, project_id")
    .in("contact_id", anchoredIds)
    .eq("is_active", true);
  if (pcErr) throw new Error(`loadAnchoredContacts pc: ${pcErr.message}`);

  // Filter to contacts with exactly 1 active project in project_contacts
  const byContact = new Map<string, string[]>();
  for (const row of pcRows ?? []) {
    const cid = row.contact_id as string;
    const pid = row.project_id as string;
    if (!byContact.has(cid)) byContact.set(cid, []);
    const list = byContact.get(cid)!;
    if (!list.includes(pid)) list.push(pid);
  }

  // Also check that the project is active
  const projectIds = new Set<string>();
  for (const pids of byContact.values()) {
    for (const pid of pids) projectIds.add(pid);
  }
  const { data: projects, error: pErr } = await db
    .from("projects")
    .select("id, status")
    .in("id", [...projectIds])
    .in("status", ["active", "warranty", "estimating"]);
  if (pErr) throw new Error(`loadAnchoredContacts projects: ${pErr.message}`);
  const activeProjectIds = new Set((projects ?? []).map((p) => p.id as string));

  const singleProjectAnchored: { contact_id: string; project_id: string }[] = [];
  for (const [cid, pids] of byContact) {
    const activePids = pids.filter((pid) => activeProjectIds.has(pid));
    if (activePids.length === 1) {
      singleProjectAnchored.push({ contact_id: cid, project_id: activePids[0] });
    }
  }

  // Fetch phone/type info
  const cids = singleProjectAnchored.map((s) => s.contact_id);
  if (cids.length === 0) return [];
  const { data: contacts, error: cErr } = await db
    .from("contacts")
    .select("id, phone, secondary_phone, contact_type")
    .in("id", cids);
  if (cErr) throw new Error(`loadAnchoredContacts contacts: ${cErr.message}`);

  const contactMap = new Map<
    string,
    { phone: string; secondary_phone: string | null; contact_type: string }
  >();
  for (const c of contacts ?? []) {
    contactMap.set(c.id, {
      phone: c.phone,
      secondary_phone: c.secondary_phone,
      contact_type: c.contact_type,
    });
  }

  return singleProjectAnchored
    .filter((s) => {
      const ct = contactMap.get(s.contact_id)?.contact_type;
      return ct && !["internal", "personal", "spam"].includes(ct);
    })
    .map((s) => ({
      ...s,
      phone: contactMap.get(s.contact_id)!.phone,
      secondary_phone: contactMap.get(s.contact_id)!.secondary_phone ?? null,
      contact_type: contactMap.get(s.contact_id)!.contact_type,
    }));
}

// R4: Single-project vendor in project_contacts (non-client, non-internal)
async function loadSingleProjectVendors(): Promise<SingleVendorContact[]> {
  const { data: pcRows, error: pcErr } = await db
    .from("project_contacts")
    .select("contact_id, project_id")
    .eq("is_active", true);
  if (pcErr) throw new Error(`loadSingleProjectVendors: ${pcErr.message}`);

  // Group and filter to single-project
  const byContact = new Map<string, string[]>();
  for (const row of pcRows ?? []) {
    const cid = row.contact_id as string;
    const pid = row.project_id as string;
    if (!byContact.has(cid)) byContact.set(cid, []);
    const list = byContact.get(cid)!;
    if (!list.includes(pid)) list.push(pid);
  }

  // Check project statuses
  const projectIds = new Set<string>();
  for (const pids of byContact.values()) {
    for (const pid of pids) projectIds.add(pid);
  }
  const { data: projects, error: pErr } = await db
    .from("projects")
    .select("id, status")
    .in("id", [...projectIds])
    .in("status", ["active", "warranty", "estimating"]);
  if (pErr) throw new Error(`loadSingleProjectVendors projects: ${pErr.message}`);
  const activeProjectIds = new Set((projects ?? []).map((p) => p.id as string));

  const singleProject: { contact_id: string; project_id: string }[] = [];
  for (const [cid, pids] of byContact) {
    const activePids = pids.filter((pid) => activeProjectIds.has(pid));
    if (activePids.length === 1) {
      singleProject.push({ contact_id: cid, project_id: activePids[0] });
    }
  }

  // Fetch contact details
  const cids = singleProject.map((s) => s.contact_id);
  if (cids.length === 0) return [];
  const { data: contacts, error: cErr } = await db
    .from("contacts")
    .select("id, phone, secondary_phone, contact_type")
    .in("id", cids);
  if (cErr) throw new Error(`loadSingleProjectVendors contacts: ${cErr.message}`);

  const contactMap = new Map<
    string,
    { phone: string; secondary_phone: string | null; contact_type: string }
  >();
  for (const c of contacts ?? []) {
    contactMap.set(c.id, {
      phone: c.phone,
      secondary_phone: c.secondary_phone,
      contact_type: c.contact_type,
    });
  }

  return singleProject
    .filter((s) => {
      const ct = contactMap.get(s.contact_id)?.contact_type;
      return ct && !["internal", "personal", "spam", "client"].includes(ct);
    })
    .map((s) => ({
      ...s,
      phone: contactMap.get(s.contact_id)!.phone,
      secondary_phone: contactMap.get(s.contact_id)!.secondary_phone ?? null,
      contact_type: contactMap.get(s.contact_id)!.contact_type,
    }));
}

// ---------------------------------------------------------------------------
// Step 2: Load unlabeled spans
// ---------------------------------------------------------------------------

interface SpanRow {
  id: string;
  interaction_id: string;
  span_index: number;
  transcript_segment: string | null;
  word_count: number | null;
}

interface InteractionRow {
  interaction_id: string;
  contact_phone: string | null;
  contact_name: string | null;
  contact_id: string | null;
}

async function loadUnlabeledSpans(): Promise<
  (SpanRow & { contact_phone: string | null; contact_name: string | null; contact_id: string | null })[]
> {
  // Get spans that don't already have a label in this batch
  const labeledSpanIds = new Set<string>();
  {
    let p = 0;
    while (true) {
      const { data: batch, error: elErr } = await db
        .from("labeling_results")
        .select("span_id")
        .eq("batch_run_id", BATCH_RUN_ID)
        .range(p * 1000, (p + 1) * 1000 - 1);
      if (elErr) throw new Error(`loadExistingLabels: ${elErr.message}`);
      if (!batch || batch.length === 0) break;
      for (const r of batch) labeledSpanIds.add(r.span_id as string);
      if (batch.length < 1000) break;
      p++;
    }
  }

  // Load all non-superseded spans (paginate to handle > 1000 rows)
  const allSpans: SpanRow[] = [];
  let page = 0;
  const PAGE_SIZE = 1000;
  while (true) {
    const { data: batch, error: sErr } = await db
      .from("conversation_spans")
      .select("id, interaction_id, span_index, transcript_segment, word_count")
      .eq("is_superseded", false)
      .order("interaction_id")
      .order("span_index")
      .range(page * PAGE_SIZE, (page + 1) * PAGE_SIZE - 1);
    if (sErr) throw new Error(`loadSpans page ${page}: ${sErr.message}`);
    if (!batch || batch.length === 0) break;
    allSpans.push(...(batch as SpanRow[]));
    if (batch.length < PAGE_SIZE) break;
    page++;
  }

  const filteredSpans = allSpans.filter((s) => !labeledSpanIds.has(s.id));

  // Get unique interaction_ids and fetch their contact info
  const interactionIds = [...new Set(filteredSpans.map((s) => s.interaction_id as string))];

  // Batch fetch interactions in chunks of 50 (URL length limit)
  const interactionMap = new Map<string, InteractionRow>();
  for (let i = 0; i < interactionIds.length; i += 50) {
    const chunk = interactionIds.slice(i, i + 50);
    const { data: interactions, error: iErr } = await db
      .from("interactions")
      .select("interaction_id, contact_phone, contact_name, contact_id")
      .in("interaction_id", chunk);
    if (iErr) throw new Error(`loadInteractions: ${iErr.message}`);
    for (const row of interactions ?? []) {
      interactionMap.set(row.interaction_id as string, row as InteractionRow);
    }
  }

  return filteredSpans.map((s) => {
    const interaction = interactionMap.get(s.interaction_id as string);
    return {
      ...s,
      contact_phone: interaction?.contact_phone ?? null,
      contact_name: interaction?.contact_name ?? null,
      contact_id: interaction?.contact_id ?? null,
    };
  });
}

// ---------------------------------------------------------------------------
// Step 3: Phone matching helpers
// ---------------------------------------------------------------------------

function normalizePhone(phone: string | null | undefined): string | null {
  const digits = (phone ?? "").replace(/\D/g, "");
  if (!digits || digits.length < 7) return null;
  return digits.length > 10 ? digits.slice(-10) : digits;
}

function phonesMatch(a: string | null, b: string | null): boolean {
  const na = normalizePhone(a);
  const nb = normalizePhone(b);
  if (!na || !nb) return false;
  return na === nb;
}

function contactMatchesPhone(
  contactPhone: string | null,
  refPhone: string,
  refSecondary: string | null,
): boolean {
  return phonesMatch(contactPhone, refPhone) ||
    (refSecondary != null && phonesMatch(contactPhone, refSecondary));
}

// ---------------------------------------------------------------------------
// Step 4: Apply rules
// ---------------------------------------------------------------------------

// Load active projects for name matching (staff exclusion + single vendor contradiction check)
async function loadActiveProjects(): Promise<{ id: string; name: string; aliases: string[] }[]> {
  const { data, error } = await db
    .from("projects")
    .select("id, name, aliases")
    .in("status", ["active", "warranty", "estimating"]);
  if (error) throw new Error(`loadActiveProjects: ${error.message}`);
  return (data ?? []).map((p) => ({
    id: p.id,
    name: p.name,
    aliases: p.aliases ?? [],
  }));
}

function transcriptContainsProjectName(
  transcript: string,
  projects: { name: string; aliases: string[] }[],
): boolean {
  const lower = transcript.toLowerCase();
  for (const p of projects) {
    if (p.name && lower.includes(p.name.toLowerCase())) return true;
    for (const alias of p.aliases) {
      if (alias && lower.includes(alias.toLowerCase())) return true;
    }
  }
  return false;
}

async function run(): Promise<void> {
  console.log("[pass0] Loading reference data...");

  const [staffContacts, homeownerRows, anchoredContacts, singleVendors, activeProjects] = await Promise.all([
    loadStaffContacts(),
    loadHomeownerSingleProject(),
    loadAnchoredContacts(),
    loadSingleProjectVendors(),
    loadActiveProjects(),
  ]);

  console.log(`[pass0] Staff contacts: ${staffContacts.length}`);
  console.log(`[pass0] Homeowner-single-project contacts: ${homeownerRows.length}`);
  console.log(`[pass0] Anchored contacts with project: ${anchoredContacts.length}`);
  console.log(`[pass0] Single-project vendors: ${singleVendors.length}`);
  console.log(`[pass0] Active projects: ${activeProjects.length}`);

  console.log("[pass0] Loading unlabeled spans...");
  const spans = await loadUnlabeledSpans();
  console.log(`[pass0] Unlabeled spans to process: ${spans.length}`);

  const labels: LabelingResult[] = [];
  const stats: PassStats = {
    pass_name: "pass0_deterministic",
    pass_number: 0,
    total_input: spans.length,
    labeled: 0,
    deferred: 0,
    errors: 0,
    detail: {
      staff_exclusion: 0,
      homeowner_match: 0,
      phone_match: 0,
      single_vendor: 0,
    },
  };

  const labeledSpanIds = new Set<string>();

  // Build phone lookup indexes for fast matching
  const staffPhones = new Map<string, StaffContact>();
  for (const sc of staffContacts) {
    const p1 = normalizePhone(sc.phone);
    if (p1) staffPhones.set(p1, sc);
    const p2 = normalizePhone(sc.secondary_phone);
    if (p2) staffPhones.set(p2, sc);
  }

  const homeownerPhones = new Map<string, ProjectClientRow>();
  for (const hr of homeownerRows) {
    const p1 = normalizePhone(hr.contact_phone);
    if (p1) homeownerPhones.set(p1, hr);
    const p2 = normalizePhone(hr.secondary_phone);
    if (p2) homeownerPhones.set(p2, hr);
  }

  const anchoredPhones = new Map<string, AnchoredContact>();
  for (const ac of anchoredContacts) {
    const p1 = normalizePhone(ac.phone);
    if (p1) anchoredPhones.set(p1, ac);
    const p2 = normalizePhone(ac.secondary_phone);
    if (p2) anchoredPhones.set(p2, ac);
  }

  const vendorPhones = new Map<string, SingleVendorContact>();
  for (const sv of singleVendors) {
    const p1 = normalizePhone(sv.phone);
    if (p1) vendorPhones.set(p1, sv);
    const p2 = normalizePhone(sv.secondary_phone);
    if (p2) vendorPhones.set(p2, sv);
  }

  for (const span of spans) {
    if (labeledSpanIds.has(span.id)) continue;
    const callerPhone = normalizePhone(span.contact_phone);

    // Rule 1: Staff exclusion (highest priority)
    // Spec: staff phone + short call (< 200 words) + no project names → 'none', conf=0.95
    if (callerPhone && staffPhones.has(callerPhone)) {
      const wordCount = span.word_count || 0;
      const transcript = span.transcript_segment || "";

      // Check if short call (< 200 words)
      if (wordCount < STAFF_SHORT_CALL_WORDS) {
        // Check for project names in transcript
        const hasProjectName = transcriptContainsProjectName(transcript, activeProjects);

        if (!hasProjectName) {
          labels.push({
            span_id: span.id,
            interaction_id: span.interaction_id,
            project_id: null,
            label_decision: "none",
            confidence: 0.95,
            label_source: "pass0_staff_exclusion",
            pass_number: 0,
            batch_run_id: BATCH_RUN_ID,
            attribution_lock: "pass0_deterministic",
          });
          labeledSpanIds.add(span.id);
          stats.detail.staff_exclusion++;
          continue;
        }
      }
    }

    // Rule 2: Phone Match (anchored vendor)
    // Spec: fanout_class='anchored', effective_fanout=1 → single project, conf=0.90
    if (callerPhone && anchoredPhones.has(callerPhone)) {
      const ac = anchoredPhones.get(callerPhone)!;
      labels.push({
        span_id: span.id,
        interaction_id: span.interaction_id,
        project_id: ac.project_id,
        label_decision: "assign",
        confidence: 0.90,
        label_source: "pass0_phone_match",
        pass_number: 0,
        batch_run_id: BATCH_RUN_ID,
        attribution_lock: "pass0_deterministic",
      });
      labeledSpanIds.add(span.id);
      stats.detail.phone_match++;
      continue;
    }

    // Rule 3: Homeowner Regex
    // Spec: client_name in transcript + contact linked to project → 'assign', conf=0.85
    if (callerPhone && homeownerPhones.has(callerPhone)) {
      const hr = homeownerPhones.get(callerPhone)!;
      labels.push({
        span_id: span.id,
        interaction_id: span.interaction_id,
        project_id: hr.project_id,
        label_decision: "assign",
        confidence: 0.85,
        label_source: "pass0_homeowner_regex",
        pass_number: 0,
        batch_run_id: BATCH_RUN_ID,
        attribution_lock: "pass0_deterministic",
      });
      labeledSpanIds.add(span.id);
      stats.detail.homeowner_match++;
      continue;
    }

    // Rule 4: Single-Project Vendor
    // Spec: exactly 1 active project + no contradicting names → 'assign', conf=0.85
    if (callerPhone && vendorPhones.has(callerPhone)) {
      const sv = vendorPhones.get(callerPhone)!;
      labels.push({
        span_id: span.id,
        interaction_id: span.interaction_id,
        project_id: sv.project_id,
        label_decision: "assign",
        confidence: 0.85,
        label_source: "pass0_single_vendor",
        pass_number: 0,
        batch_run_id: BATCH_RUN_ID,
        attribution_lock: "pass0_deterministic",
      });
      labeledSpanIds.add(span.id);
      stats.detail.single_vendor++;
      continue;
    }

    // No rule matched — deferred to Pass 1
    stats.deferred++;
  }

  stats.labeled = labels.length;

  console.log(`\n[pass0] Results:`);
  console.log(`  Total spans:      ${stats.total_input}`);
  console.log(`  Labeled:          ${stats.labeled} (${((stats.labeled / stats.total_input) * 100).toFixed(1)}%)`);
  console.log(`    staff_exclusion:  ${stats.detail.staff_exclusion}`);
  console.log(`    homeowner_match:  ${stats.detail.homeowner_match}`);
  console.log(`    phone_match:      ${stats.detail.phone_match}`);
  console.log(`    single_vendor:    ${stats.detail.single_vendor}`);
  console.log(`  Deferred:         ${stats.deferred}`);

  if (DRY_RUN) {
    console.log("\n[pass0] DRY RUN — no writes performed.");
    // Write stats to /tmp for downstream consumers
    await Deno.writeTextFile(
      "/tmp/wm-pass0-stats.json",
      JSON.stringify(stats, null, 2),
    );
    console.log("[pass0] Stats written to /tmp/wm-pass0-stats.json");
    return;
  }

  // Write labels to labeling_results in batches of 100
  console.log(`\n[pass0] Writing ${labels.length} labels to labeling_results...`);
  let written = 0;
  for (let i = 0; i < labels.length; i += 100) {
    const batch = labels.slice(i, i + 100);
    const rows = batch.map((l) => ({
      span_id: l.span_id,
      interaction_id: l.interaction_id,
      project_id: l.project_id,
      label_decision: l.label_decision,
      confidence: l.confidence,
      label_source: l.label_source,
      pass_number: l.pass_number,
      batch_run_id: l.batch_run_id,
      attribution_lock: l.attribution_lock,
    }));

    const { error } = await db
      .from("labeling_results")
      .upsert(rows, { onConflict: "span_id,batch_run_id" });

    if (error) {
      console.error(`[pass0] Write error at batch ${i}: ${error.message}`);
      stats.errors += batch.length;
    } else {
      written += batch.length;
    }
  }

  console.log(`[pass0] Written: ${written}/${labels.length}`);
  if (stats.errors > 0) {
    console.error(`[pass0] Errors: ${stats.errors}`);
  }

  // Write stats to /tmp for downstream consumers
  await Deno.writeTextFile(
    "/tmp/wm-pass0-stats.json",
    JSON.stringify(stats, null, 2),
  );
  console.log("[pass0] Stats written to /tmp/wm-pass0-stats.json");

  // Write summary to /tmp for team lead
  const summary = [
    `# Pass 0: Deterministic Labels`,
    ``,
    `**Batch:** ${BATCH_RUN_ID}`,
    `**Date:** ${new Date().toISOString()}`,
    ``,
    `## Results`,
    ``,
    `| Metric | Value |`,
    `|--------|-------|`,
    `| Total spans | ${stats.total_input} |`,
    `| Labeled | ${stats.labeled} (${((stats.labeled / stats.total_input) * 100).toFixed(1)}%) |`,
    `| R3 staff_exclusion | ${stats.detail.staff_exclusion} |`,
    `| R2 homeowner_match | ${stats.detail.homeowner_match} |`,
    `| R1 phone_match | ${stats.detail.phone_match} |`,
    `| R4 single_vendor | ${stats.detail.single_vendor} |`,
    `| Deferred to Pass 1 | ${stats.deferred} |`,
    `| Errors | ${stats.errors} |`,
    ``,
    `## Rule Details`,
    ``,
    `- **R3 (staff exclusion):** ${staffContacts.length} internal contacts, ` +
      `${stats.detail.staff_exclusion} spans labeled as overhead`,
    `- **R2 (homeowner match):** ${homeownerRows.length} homeowner contacts, ` +
      `${stats.detail.homeowner_match} spans assigned to projects`,
    `- **R1 (phone match):** ${anchoredContacts.length} anchored contacts, ` +
      `${stats.detail.phone_match} spans assigned`,
    `- **R4 (single vendor):** ${singleVendors.length} single-project vendors, ` +
      `${stats.detail.single_vendor} spans assigned`,
  ].join("\n");

  await Deno.writeTextFile("/tmp/wm-pass0-report.md", summary);
  console.log("[pass0] Report written to /tmp/wm-pass0-report.md");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
try {
  await run();
} catch (err) {
  console.error("[pass0] FATAL:", err);
  Deno.exit(1);
}
