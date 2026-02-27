-- Add Beside native IDs to sms_messages for fallback contact resolution.
--
-- When Beside drops contact_phone (~16% of messages), these IDs provide
-- an alternative resolution path: find any prior message with the same
-- beside_contact_id that HAS a resolved phone, and use that phone.
--
-- Thread: redline_health
-- Author: data-r2

begin;

-- beside_contact_id: Beside's native contact identifier.
-- Stable across messages from the same external party.
alter table sms_messages
  add column if not exists beside_contact_id text;

-- beside_conversation_id: Beside's native conversation/thread identifier.
-- Groups messages into conversations independent of phone number.
alter table sms_messages
  add column if not exists beside_conversation_id text;

-- Index for the fallback lookup: "find a prior message with this beside_contact_id
-- that has a resolved contact_phone"
create index if not exists idx_sms_beside_contact_id
  on sms_messages (beside_contact_id)
  where beside_contact_id is not null and beside_contact_id != '';

create index if not exists idx_sms_beside_conversation_id
  on sms_messages (beside_conversation_id)
  where beside_conversation_id is not null and beside_conversation_id != '';

commit;
