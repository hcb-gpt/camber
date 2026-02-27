begin;

create index if not exists idx_interactions_redline_contact_event_filtered
  on public.interactions (contact_id, event_at_utc desc)
  where event_at_utc is not null
    and (channel = 'call' or channel = 'phone' or channel is null)
    and (is_shadow is false or is_shadow is null);

create index if not exists idx_sms_messages_contact_phone_sent_at_desc
  on public.sms_messages (contact_phone, sent_at desc);

commit;
