-- Register/codify v_overdue_tasks view in migrations.
-- Keep remote-compatible column shape to avoid breakage on existing deployments.

create or replace view public.v_overdue_tasks as
select
  si.project_id,
  p.name as project_name,
  si.title,
  si.assignee,
  si.due_at_utc,
  extract(day from now() - si.due_at_utc) as days_overdue,
  si.item_type,
  (si.financial_json is not null) as has_financial_json
from public.scheduler_items si
left join public.projects p on p.id = si.project_id
where si.status = 'pending'
  and si.due_at_utc is not null
  and si.due_at_utc < now()
order by si.due_at_utc;

comment on view public.v_overdue_tasks is
  'Pending scheduler items with due_at_utc in the past for overdue task monitoring.';
