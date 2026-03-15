
import fs from 'fs';

const filePath = 'camber-calls/supabase/functions/redline-thread/index.ts';
let content = fs.readFileSync(filePath, 'utf8');

// 1. VERSION
content = content.replace(/const FUNCTION_VERSION = "redline-thread_v3\.1\.1";/, `const FUNCTION_VERSION = "redline-thread_v3.1.3";`);

// 2. selectColumns
content = content.replace(/contact_phone, call_count/, `contact_phone, call_count, sms_count, claim_count, ungraded_count, last_activity, last_snippet, last_direction, last_interaction_type, source`);

// 3. handleContacts matview source
content = content.replace(/const contactsSource = "redline_contacts";/, `const contactsSource = "redline_contacts_unified_matview";`);

// 4. handleThread matview source
content = content.replace(/\.from\("contacts"\)/g, `.from("redline_contacts_unified_matview")`);
content = content.replace(/select\("id, name, phone"\)/g, `select("contact_id, contact_name, contact_phone")`);

// 5. field mapping globals
content = content.replace(/contact\.phone/g, `contact.contact_phone`);
content = content.replace(/contact\.id/g, `contact.contact_id`);
content = content.replace(/contact\.name/g, `contact.contact_name`);

fs.writeFileSync(filePath, content);
console.log('Applied P0 basic replacements.');
