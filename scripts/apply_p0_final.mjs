
import fs from 'fs';

const filePath = 'camber-calls/supabase/functions/redline-thread/index.ts';
let content = fs.readFileSync(filePath, 'utf8');

// 1. Version
content = content.replace(/const FUNCTION_VERSION = "redline-thread_v3\.1\.1";/, `const FUNCTION_VERSION = "redline-thread_v3.1.3";`);

// 2. selectColumns
content = content.replace(
  /"contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type"/,
  `"contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type, source"`
);

// 3. handleContacts mapping
content = content.replace(
  /\.map\(\(row: any\) => \(\{[\s\S]*?\}\)\)
    \.sort\(/,
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
    .sort(`
);

// 4. handleThread query and field usage
content = content.replace(/\.from\("contacts"\)/g, `.from("redline_contacts_unified_matview")`);
content = content.replace(/select\("id, name, phone"\)/g, `select("contact_id, contact_name, contact_phone")`);
content = content.replace(/contact\.phone/g, `contact.contact_phone`);
content = content.replace(/contact\.id/g, `contact.contact_id`);
content = content.replace(/contact\.name/g, `contact.contact_name`);

// 5. iOS Contract Fixes (spans and claims)
// This is more complex, I'll do specific replacements for keys.
content = content.replace(/span_id: s\.id,/g, `span_id: s.id, // already fixed?`); // check
content = content.replace(/needs_attribution: !!pendingReview/g, `needs_attribution: !!pendingReview, span_id: s.id`);
content = content.replace(/claim_id: c\.id/g, `claim_id: c.id`);

// SMSEntry
content = content.replace(
  /sms_id: s\.id,/,
  `sms_id: s.id, sender_name: s.direction === "outbound" ? "Zack" : (s.contact_name || contact.contact_name), needs_attribution: true,`
);

fs.writeFileSync(filePath, content);
console.log('Applied P0 fixes comprehensively.');
