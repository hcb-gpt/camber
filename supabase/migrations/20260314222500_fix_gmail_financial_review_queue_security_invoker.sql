create or replace view public.v_gmail_financial_review_queue
with (security_invoker = true) as
select
  c.id as candidate_id,
  c.message_id,
  c.thread_id,
  c.internal_date,
  c.subject,
  c.from_header,
  c.snippet,
  c.body_excerpt,
  c.matched_profile_slugs,
  c.matched_class_hints,
  c.finance_relevance_score,
  c.doc_type,
  c.decision,
  c.decision_reason,
  c.classifier_version,
  c.classifier_meta,
  c.review_state,
  c.run_id,
  c.first_retrieved_at_utc,
  c.last_retrieved_at_utc,
  c.updated_at
from public.gmail_financial_candidates c
where c.decision = 'review'
  and c.review_state = 'pending'
order by c.last_retrieved_at_utc desc, c.internal_date desc nulls last;

grant select on table public.v_gmail_financial_review_queue to service_role;
