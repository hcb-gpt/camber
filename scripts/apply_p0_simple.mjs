
import fs from 'fs';

const filePath = 'camber-calls/supabase/functions/redline-thread/index.ts';
let content = fs.readFileSync(filePath, 'utf8');

const replacements = [
  ['const FUNCTION_VERSION = "redline-thread_v3.1.1";', 'const FUNCTION_VERSION = "redline-thread_v3.1.3";'],
  ['"contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type"', '"contact_id, contact_name, contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type, source"'],
  ['const contactsSource = "redline_contacts";', 'const contactsSource = "redline_contacts_unified_matview";'],
  ['db.from("contacts")', 'db.from("redline_contacts_unified_matview")'],
  ['select("id, name, phone")', 'select("contact_id, contact_name, contact_phone")'],
  ['contact.phone', 'contact.contact_phone'],
  ['contact.id', 'contact.contact_id'],
  ['contact.name', 'contact.contact_name'],
  ['needs_attribution: !!pendingReview', 'needs_attribution: !!pendingReview, span_id: s.id'],
  ['claim_id: c.id', 'claim_id: c.id'], // already good
  ['sms_id: s.id,', 'sms_id: s.id, sender_name: s.direction === "outbound" ? "Zack" : (s.contact_name || contact.contact_name), needs_attribution: !!pendingReview,'],
];

for (const [oldStr, newStr] of replacements) {
  content = content.split(oldStr).join(newStr);
}

fs.writeFileSync(filePath, content);
console.log('Applied P0 string replacements.');
