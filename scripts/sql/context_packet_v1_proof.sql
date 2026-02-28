-- Proof query for public.get_context_packet_v1
-- Usage:
--   scripts/query.sh --file scripts/sql/context_packet_v1_proof.sql

with packet as (
  select public.get_context_packet_v1(
    '55832dbd-feb0-438c-92cb-b763c65e47dc'::uuid, -- Blanton Winship
    '310a3768-d7c0-4e72-88d0-aa67bf4d1b05'::uuid, -- Winship Residence
    10,
    10,
    10,
    168
  ) as payload
)
select
  payload->>'packet_version' as packet_version,
  payload->>'generated_at_utc' as generated_at_utc,
  payload->'filters' as filters,
  payload->'materialized_at_utc' as materialized_at_utc,
  jsonb_array_length(payload->'recent'->'interactions') as recent_interactions_count,
  jsonb_array_length(payload->'recent'->'sms_spans') as recent_sms_spans_count,
  (payload->'open'->'pending_review_queue'->>'count')::bigint as pending_review_count,
  (payload->'open'->'ungraded_claims'->>'count')::bigint as ungraded_claim_count,
  (payload->'open'->'active_open_loops'->>'count')::bigint as open_loop_count,
  (payload->'open'->'active_scheduler_items'->>'count')::bigint as active_scheduler_count
from packet;
