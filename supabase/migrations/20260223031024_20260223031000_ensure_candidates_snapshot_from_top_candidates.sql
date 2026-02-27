-- Ensure candidates_snapshot is populated when top_candidates exists

create or replace function public.ensure_candidates_snapshot_from_top_candidates()
returns trigger
language plpgsql
as $$
begin
  -- Only fill when missing or empty
  if new.candidates_snapshot is null
     or (jsonb_typeof(new.candidates_snapshot) = 'array' and jsonb_array_length(new.candidates_snapshot) = 0)
     or (jsonb_typeof(new.candidates_snapshot) = 'object' and new.candidates_snapshot = '{}'::jsonb)
  then
    if new.top_candidates is not null
       and jsonb_typeof(new.top_candidates) = 'array'
       and jsonb_array_length(new.top_candidates) > 0
    then
      new.candidates_snapshot := new.top_candidates;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_ensure_candidates_snapshot_from_top_candidates on public.span_attributions;

create trigger trg_ensure_candidates_snapshot_from_top_candidates
before insert or update of top_candidates, candidates_snapshot
on public.span_attributions
for each row
execute function public.ensure_candidates_snapshot_from_top_candidates();
;
