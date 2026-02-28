-- Financial SSOT semantic guardrails for cost code imports.
-- Enforces high-signal validation to catch common malformed keyword payloads.

create or replace function public.cost_code_taxonomy_guardrail_issues(
  p_code text,
  p_name text,
  p_keywords text,
  p_row_type text,
  p_is_assignable boolean
)
returns text[]
language plpgsql
as $$
declare
  v_issues text[] := '{}'::text[];
  v_keywords text := coalesce(p_keywords, '');
begin
  if coalesce(p_row_type, '') <> 'COST_CODE' or not coalesce(p_is_assignable, false) then
    return v_issues;
  end if;

  if btrim(v_keywords) = '' then
    v_issues := array_append(v_issues, 'keywords empty for assignable cost code');
  end if;

  -- Detect prefixed payloads like "Keywords:vdeck..." that indicate upstream normalization defects.
  if v_keywords ~* '^[[:space:]]*"*keywords[[:space:]]*:' then
    v_issues := array_append(v_issues, 'keywords has disallowed "Keywords:" prefix');
  end if;

  if p_code = '4080' then
    if not (v_keywords ~* '(paint|painting)') then
      v_issues := array_append(v_issues, '4080 missing paint keyword signal');
    end if;
    if v_keywords ~* '(hvac|duct|rough[ -]?in)' then
      v_issues := array_append(v_issues, '4080 contains HVAC rough-in signal');
    end if;
  elsif p_code = '5060' then
    if not (v_keywords ~* '(sprinkler|fire suppression|fire sprinkler|nfpa)') then
      v_issues := array_append(v_issues, '5060 missing fire sprinkler keyword signal');
    end if;
    if v_keywords ~* '(drywall|sheetrock|taping|mudding)' then
      v_issues := array_append(v_issues, '5060 contains drywall keyword signal');
    end if;
  elsif p_code = '8020' then
    if not (v_keywords ~* '(deck|porch)') then
      v_issues := array_append(v_issues, '8020 missing deck/porch keyword signal');
    end if;
    if v_keywords ~* '^[[:space:]]*"*keywords[[:space:]]*:' then
      v_issues := array_append(v_issues, '8020 retains prefixed keyword payload');
    end if;
  end if;

  return v_issues;
end;
$$;
comment on function public.cost_code_taxonomy_guardrail_issues(text, text, text, text, boolean) is
  'Returns semantic guardrail violations for assignable COST_CODE rows before import/merge.';
create or replace function public.enforce_cost_code_taxonomy_semantic_guardrails()
returns trigger
language plpgsql
as $$
declare
  v_issues text[];
begin
  v_issues := public.cost_code_taxonomy_guardrail_issues(
    new.code,
    new.name,
    new.keywords,
    new.row_type,
    new.is_assignable
  );

  if coalesce(array_length(v_issues, 1), 0) > 0 then
    raise exception
      using
        errcode = '23514',
        message = format(
          'cost_code_taxonomy guardrail violation for code %s: %s',
          coalesce(new.code, '<null>'),
          array_to_string(v_issues, '; ')
        ),
        detail = format(
          'name=%s row_type=%s is_assignable=%s keywords=%s',
          coalesce(new.name, '<null>'),
          coalesce(new.row_type, '<null>'),
          coalesce(new.is_assignable, false),
          left(coalesce(new.keywords, ''), 400)
        ),
        hint = 'Fix SSOT mapping/keywords before retrying import.';
  end if;

  return new;
end;
$$;
comment on function public.enforce_cost_code_taxonomy_semantic_guardrails() is
  'Trigger enforcement for cost_code_taxonomy semantic keyword guardrails.';
drop trigger if exists trg_cost_code_taxonomy_semantic_guardrails on public.cost_code_taxonomy;
create trigger trg_cost_code_taxonomy_semantic_guardrails
before insert or update of code, name, keywords, row_type, is_assignable
on public.cost_code_taxonomy
for each row
execute function public.enforce_cost_code_taxonomy_semantic_guardrails();
create or replace view public.v_cost_code_taxonomy_guardrail_violations as
select
  t.code,
  t.name,
  t.row_type,
  t.is_assignable,
  t.keywords,
  issue.issue as violation
from public.cost_code_taxonomy t
cross join lateral unnest(
  public.cost_code_taxonomy_guardrail_issues(
    t.code,
    t.name,
    t.keywords,
    t.row_type,
    t.is_assignable
  )
) as issue(issue);
comment on view public.v_cost_code_taxonomy_guardrail_violations is
  'Live audit view of cost_code_taxonomy semantic guardrail violations.';
