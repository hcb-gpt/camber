create or replace function public.remediate_gmail_financial_shadow_state(
  p_pipeline_key text default null
)
returns table (
  candidate_id uuid,
  message_id text,
  prior_run_id uuid,
  pipeline_key text,
  prior_status text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with reset_rows as (
    update public.gmail_financial_candidates c
       set classification_state = 'pending',
           doc_type = null,
           finance_relevance_score = null,
           decision = null,
           decision_reason = null,
           classifier_version = null,
           classifier_meta = '{}'::jsonb,
           review_state = 'pending',
           review_resolution = null,
           review_resolved_at_utc = null,
           extraction_state = 'pending',
           extraction_error = null,
           extraction_meta = '{}'::jsonb,
           extracted_at_utc = null,
           updated_at = now()
      from public.gmail_financial_pipeline_runs r
     where c.run_id = r.id
       and r.status = 'dry_run'
       and (p_pipeline_key is null or r.pipeline_key = p_pipeline_key)
       and c.extraction_receipt_id is null
       and (
         c.classification_state <> 'pending'
         or c.doc_type is not null
         or c.finance_relevance_score is not null
         or c.decision is not null
         or c.decision_reason is not null
         or c.classifier_version is not null
         or c.review_state <> 'pending'
         or c.review_resolution is not null
         or c.review_resolved_at_utc is not null
         or c.extraction_state <> 'pending'
         or c.extraction_error is not null
         or c.extracted_at_utc is not null
       )
    returning
      c.id,
      c.message_id,
      r.id as prior_run_id,
      r.pipeline_key,
      r.status
  )
  select
    reset_rows.id,
    reset_rows.message_id,
    reset_rows.prior_run_id,
    reset_rows.pipeline_key,
    reset_rows.status
  from reset_rows;
end;
$$;

comment on function public.remediate_gmail_financial_shadow_state(text) is
  'Resets candidate classification/review/extraction state for rows last retrieved by dry_run Gmail finance pipeline runs. Intended as one-time remediation before fresh shadow validation.';

revoke execute on function public.remediate_gmail_financial_shadow_state(text) from public;
grant execute on function public.remediate_gmail_financial_shadow_state(text) to service_role;
