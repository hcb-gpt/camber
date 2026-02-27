begin;

create index if not exists idx_sms_messages_contact_phone_sent_at_direction
  on public.sms_messages (contact_phone, sent_at desc, direction);

commit;
