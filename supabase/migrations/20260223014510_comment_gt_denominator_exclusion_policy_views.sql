-- Document GT denominator hygiene policy on production-facing views.
-- Policy source: ack_and_policy__pipeline_null_exclude_from_gt_denominator__20260223

comment on view public.v_ground_truth_evaluable_non_prod_exclusions is
  'GT denominator hygiene exclusion set. Contains only PIPELINE_NULL rows excluded from production KPI denominator: (a) shadow fixtures (interactions.is_shadow=true OR call_id like cll_SHADOW_%%), and (b) blocked-contact cohort by regex (sittler|madison|athens|bishop).';

comment on column public.v_ground_truth_evaluable_non_prod_exclusions.exclusion_reason is
  'Reason this PIPELINE_NULL row is excluded from production denominator: shadow_fixture or blocked_contact.';

comment on view public.v_ground_truth_evaluable_prod is
  'Production GT denominator view: v_ground_truth_evaluable with rows in v_ground_truth_evaluable_non_prod_exclusions removed.';
