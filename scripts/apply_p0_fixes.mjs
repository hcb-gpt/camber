
import fs from 'fs';

const filePath = 'camber-calls/supabase/functions/redline-thread/index.ts';
let content = fs.readFileSync(filePath, 'utf8');

// 1. Version and changelog
content = content.replace(/const FUNCTION_VERSION = "redline-thread_v3\.1\.1";
\/\*\*
 \* v3\.1\.1 - Unified Contacts View \(Full Exposure\)
 \* - Switch source to redline_contacts_unified_matview
 \* - Remove activity filter to expose all Beside-native contacts
 \* - Closes 65% visibility gap for beside_threads
 \*\//, 
`const FUNCTION_VERSION = "redline-thread_v3.1.3";
/**
 * v3.1.3 - iOS Contract Fix (P0 Unbrick + Source)
 * - Map DB 'id' to 'span_id' and 'claim_id' for iOS compatibility
 * - Include 'source' in contacts query for stable keys
 * - Reconciled with v3.1.1 unified matview source
 */`);

// 2. selectColumns
content = content.replace(/"contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type"/,
`"contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type, source"`);

// 3. handleContacts mapping
content = content.replace(/\.map\(\(row: any\) => \(\{[\s\S]*?\}\)\)
    \.sort\(\(a: any, b: any\) => \{/,
`.map((row: any) => ({
      contact_id: row.contact_id,
      contact_key: row.source === "contacts"
        ? row.contact_id
        : `sms:\${(row.contact_phone || "").replace(/\D/g, "").slice(-10)}`,
      name: row.contact_name,
      phone: row.contact_phone,
      call_count: Number(row.call_count ?? 0),
      sms_count: Number(row.sms_count ?? 0),
      claim_count: Number(row.claim_count ?? 0),
      ungraded_count: Number(row.ungraded_count ?? 0),
      last_activity: row.last_activity || null,
      last_summary: deriveContactLastSummary(row),
      last_direction: row.last_direction || null,
      last_interaction_type: row.last_interaction_type || null,
      source: row.source || "contacts",
    }))
    .sort((a: any, b: any) => {`);

// 4. handleThread query
content = content.replace(/db
\s+\.from\("contacts"\)
\s+\.select\("id, name, phone"\)/,
`db
      .from("redline_contacts_unified_matview")
      .select("contact_id, contact_name, contact_phone")`);

// 5. handleThread field usage
content = content.replace(/const contactPhoneVariants = buildPhoneVariants\(contact\.phone\);/, `const contactPhoneVariants = buildPhoneVariants(contact.contact_phone);`);
content = content.replace(/deriveSmsInteractionKeys\(s, contact\.phone\)/g, `deriveSmsInteractionKeys(s, contact.contact_phone)`);
content = content.replace(/contact_name: i\.contact_name \|\| contact\.name,/g, `contact_name: i.contact_name || contact.contact_name,`);
content = content.replace(/contact: \{ id: contact\.id, name: contact\.name, phone: contact\.phone \}/g, `contact: { id: contact.contact_id, name: contact.contact_name, phone: contact.contact_phone }`);

// 6. callEntries and smsEntries mapping
content = content.replace(/  const callEntries = allInteractions\.filter\(\(i: any\) => pagedCallIds\.includes\(i\.interaction_id\)\)\.map\(\(i: any\) => \{[\s\S]*?\}\);

  const smsEntries = pagedSmsMessages\.map\(\(s: any\) => \(\{[\s\S]*?\}\)\);/,
`  const callEntries = allInteractions.filter((i: any) => pagedCallIds.includes(i.interaction_id)).map((i: any) => {
    const interactionClaims = (claimsByCall.get(i.interaction_id) || []).map((c: any) => {
      const g = gradeByClaim.get(c.id);
      return {
        ...c,
        claim_id: c.id,
        grade: g?.grade,
        correction_text: g?.correction_text,
        graded_by: g?.graded_by,
      };
    });
    const spans = (spansPerInteraction.get(i.interaction_id) || []).map((s: any) => {
      const attr = attrBySpan.get(s.id);
      const reviewQueueId = pendingBySpan.get(s.id)?.id;
      return {
        ...s,
        span_id: s.id,
        review_queue_id: reviewQueueId,
        needs_attribution: !!reviewQueueId,
        project_name: projectNameById.get(attr?.applied_project_id || attr?.project_id),
        confidence: attr?.confidence,
        claims: interactionClaims.filter((c: any) => c.source_span_id === s.id),
      };
    });
    return {
      type: "call",
      interaction_id: i.interaction_id,
      event_at: i.event_at_utc,
      direction: directionMap.get(i.interaction_id),
      summary: i.human_summary,
      contact_name: i.contact_name || contact.contact_name,
      participants: [], // Placeholder
      spans,
      pending_attribution_count: spans.filter((s: any) => s.needs_attribution).length,
      claims: interactionClaims,
    };
  });

  const smsEntries = pagedSmsMessages.map((s: any) => {
    const reviewQueueId = deriveSmsInteractionKeys(s, contact.contact_phone).map((k) => pendingSmsByInteraction.get(k)).find((p) =>
      !!p
    )?.id;
    return {
      type: "sms",
      sms_id: s.id,
      event_at: s.sent_at,
      direction: s.direction,
      content: s.content,
      sender_name: s.direction === "outbound" ? "Zack" : (s.contact_name || contact.contact_name),
      review_queue_id: reviewQueueId,
      needs_attribution: !!reviewQueueId,
    };
  });`);

fs.writeFileSync(filePath, content);
console.log('Applied P0 fixes.');
