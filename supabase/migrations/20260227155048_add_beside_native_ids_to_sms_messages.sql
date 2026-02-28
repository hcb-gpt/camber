alter table sms_messages
  add column if not exists beside_contact_id text;

alter table sms_messages
  add column if not exists beside_conversation_id text;

create index if not exists idx_sms_beside_contact_id
  on sms_messages (beside_contact_id)
  where beside_contact_id is not null and beside_contact_id != '';

create index if not exists idx_sms_beside_conversation_id
  on sms_messages (beside_conversation_id)
  where beside_conversation_id is not null and beside_conversation_id != '';;
