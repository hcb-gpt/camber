-- Backfill missing pipeline_model_config rows for LLM-calling edge functions.
-- Scope: code-derived inventory for supabase/functions/* that call OpenAI/Anthropic APIs.

begin;

with desired as (
  select *
  from (
    values
      (
        'audit-attribution'::text,
        'openai'::text,
        'gpt-4o-mini'::text,
        'openai'::text,
        'gpt-4o-mini'::text,
        1400::integer,
        0.0::numeric,
        'classification'::text,
        'Packet-only attribution audit reviewer with strict JSON adjudication.'::text
      ),
      (
        'embed-facts'::text,
        'openai'::text,
        'text-embedding-3-small'::text,
        null::text,
        null::text,
        1024::integer,
        0.0::numeric,
        'embedding'::text,
        'Embeds project_facts rows for semantic retrieval and xref search.'::text
      ),
      (
        'journal-consolidate'::text,
        'openai'::text,
        'gpt-4o'::text,
        'openai'::text,
        'gpt-4o-mini'::text,
        4096::integer,
        0.0::numeric,
        'reasoning'::text,
        'Consolidates new claims against existing ledger claims (new/supersedes/corroborates/conflicts).'::text
      ),
      (
        'journal-embed-backfill'::text,
        'openai'::text,
        'text-embedding-3-small'::text,
        null::text,
        null::text,
        1024::integer,
        0.0::numeric,
        'embedding'::text,
        'Backfills journal_claims search_text + embeddings for semantic recall.'::text
      ),
      (
        'redline-assistant'::text,
        'openai'::text,
        'gpt-4o'::text,
        'openai'::text,
        'gpt-4o-mini'::text,
        2048::integer,
        0.7::numeric,
        'conversational'::text,
        'Interactive Redline assistant chat response generation.'::text
      )
  ) as t(
    function_name,
    provider,
    model_id,
    fallback_provider,
    fallback_model_id,
    max_tokens,
    temperature,
    task_type,
    rationale
  )
)
insert into public.pipeline_model_config (
  function_name,
  provider,
  model_id,
  fallback_provider,
  fallback_model_id,
  max_tokens,
  temperature,
  task_type,
  rationale,
  benchmarks_consulted,
  updated_by,
  updated_at
)
select
  d.function_name,
  d.provider,
  d.model_id,
  d.fallback_provider,
  d.fallback_model_id,
  d.max_tokens,
  d.temperature,
  d.task_type,
  d.rationale,
  'code_defaults_2026-02-28',
  'data-1',
  now()
from desired d
on conflict (function_name) do update
set provider = excluded.provider,
    model_id = excluded.model_id,
    fallback_provider = excluded.fallback_provider,
    fallback_model_id = excluded.fallback_model_id,
    max_tokens = excluded.max_tokens,
    temperature = excluded.temperature,
    task_type = excluded.task_type,
    rationale = excluded.rationale,
    benchmarks_consulted = excluded.benchmarks_consulted,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;

commit;
