
CREATE OR REPLACE FUNCTION decide_lane(
  claim journal_claims,
  context jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(lane text, reason_code text, reason_detail text)
LANGUAGE plpgsql STABLE AS $$
declare
  ct text := case coalesce(claim.claim_type, '')
    when 'deadline' then 'commitment' when 'question' then 'open_loop'
    when 'blocker' then 'risk' when 'concern' then 'risk'
    when 'fact' then 'state' when 'update' then 'state'
    when 'requirement' then 'request'
    else coalesce(claim.claim_type, '') end;
  original_ct text := coalesce(claim.claim_type, '');
  conf double precision := coalesce(claim.attribution_confidence, 0.70);
  is_promotable boolean;
  is_non_promotable boolean;
  contradiction_detected boolean := coalesce((context->>'contradiction_detected')::boolean, false);
  is_multi_project_correspondent boolean := coalesce((context->>'is_multi_project_correspondent')::boolean, false);
  schedule_anchored boolean := coalesce((context->>'schedule_anchored')::boolean, false);
  min_conf double precision;
  is_doc_sourced boolean := (claim.source_document_id IS NOT NULL);
  interaction_candidates jsonb;
  claim_proj_in_candidates boolean := false;
  candidate_count int;
begin
  is_promotable := ct in ('decision','commitment','schedule','open_loop','risk');
  is_non_promotable := ct in ('state','status','narrative','summary','preference','fact','info','request');

  -- G1: Pointer validity
  if claim.pointer_type NOT IN ('transcript_span', 'document_span', 'span_bounded') then
    if is_doc_sourced and claim.pointer_type = 'document_span' then null;
    else
      lane := 'REVIEW';
      reason_code := case when claim.pointer_type is null or claim.char_start is null or claim.char_end is null or claim.span_hash is null then 'missing_pointer' else 'pointer_invalid' end;
      reason_detail := 'pointer_type=' || coalesce(claim.pointer_type::text,'NULL') || ' original_type=' || original_ct;
      return next; return;
    end if;
  end if;

  if claim.pointer_type IN ('transcript_span', 'span_bounded') then
    if claim.char_start is null or claim.char_end is null or claim.span_hash is null then
      lane := 'REVIEW'; reason_code := 'missing_pointer';
      reason_detail := 'transcript_span missing char_start/end/hash, original_type=' || original_ct;
      return next; return;
    end if;
  end if;

  -- G2: Missing claim_project_id
  if claim.claim_project_id is null then
    if is_promotable then
      lane := 'REVIEW'; reason_code := 'ambiguous_project';
      reason_detail := 'claim_project_id is NULL, type=' || ct;
    else
      lane := 'STAGE'; reason_code := null;
      reason_detail := 'non_promotable_type=' || ct || ' (original=' || original_ct || ')';
    end if;
    return next; return;
  end if;

  -- G3: Contradiction
  if contradiction_detected then
    lane := 'REVIEW'; reason_code := 'contradiction'; reason_detail := 'contradiction_detected=true';
    return next; return;
  end if;

  -- G4: claim_project_id must be in interactions.candidate_projects
  -- FIX: candidate_projects is array of objects [{id, name, ...}], not flat strings
  if is_promotable and NOT is_doc_sourced and claim.call_id is not null then
    SELECT i.candidate_projects INTO interaction_candidates
    FROM interactions i WHERE i.interaction_id = claim.call_id;
    
    if interaction_candidates is not null and jsonb_array_length(interaction_candidates) > 0 then
      -- Correct lookup: check if any element's "id" field matches
      SELECT EXISTS(
        SELECT 1 FROM jsonb_array_elements(interaction_candidates) elem
        WHERE elem->>'id' = claim.claim_project_id::text
      ) INTO claim_proj_in_candidates;
      candidate_count := jsonb_array_length(interaction_candidates);
    else
      claim_proj_in_candidates := true;
      candidate_count := 0;
    end if;
    
    if not claim_proj_in_candidates and candidate_count >= 2 then
      lane := 'REVIEW'; reason_code := 'project_not_in_candidates';
      reason_detail := 'claim_project_id=' || claim.claim_project_id::text || ' not in ' || candidate_count::text || ' candidates, type=' || ct;
      return next; return;
    end if;
  end if;

  -- Multi-project correspondent: only block high-stakes
  if NOT is_doc_sourced and is_multi_project_correspondent and original_ct in ('decision', 'commitment', 'deadline') then
    lane := 'REVIEW'; reason_code := 'multi_project_correspondent';
    reason_detail := 'is_multi_project_correspondent=true, type=' || ct;
    return next; return;
  end if;

  -- G7: Reported speech
  if NOT is_doc_sourced and claim.testimony_type = 'reported' and original_ct in ('decision', 'commitment') then
    lane := 'REVIEW'; reason_code := 'reported_speech_decision';
    reason_detail := 'testimony_type=reported, claim_type=' || original_ct;
    return next; return;
  end if;

  -- Type routing
  if is_non_promotable then
    lane := 'STAGE'; reason_code := null; reason_detail := 'non_promotable_type=' || ct || ' (original=' || original_ct || ')';
    return next; return;
  elsif not is_promotable then
    lane := 'STAGE'; reason_code := null; reason_detail := 'unknown_claim_type=' || ct || ' (original=' || original_ct || ')';
    return next; return;
  end if;

  -- Thresholds
  min_conf := case ct when 'decision' then 0.75 when 'commitment' then 0.70 when 'schedule' then 0.75 when 'open_loop' then 0.65 when 'risk' then 0.65 else 1.00 end;

  if ct = 'schedule' and not schedule_anchored and NOT is_doc_sourced then
    lane := 'REVIEW'; reason_code := 'schedule_unanchored'; reason_detail := 'schedule_anchored=false';
    return next; return;
  end if;

  if conf < min_conf then
    lane := 'REVIEW'; reason_code := 'low_signal';
    reason_detail := 'confidence=' || conf::text || ' min=' || min_conf::text || ' type=' || ct;
    return next; return;
  end if;

  -- Promote
  lane := 'PROMOTE'; reason_code := null;
  reason_detail := 'type=' || ct || ' (original=' || original_ct || ') conf=' || conf::text || case when is_doc_sourced then ' source=document' else '' end;
  return next;
end;
$$;
;
