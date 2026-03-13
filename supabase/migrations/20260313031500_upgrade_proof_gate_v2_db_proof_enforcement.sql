-- =============================================================
-- PROOF GATE V2
-- Enforce DB_PROOF for DB-task completions and inspect both
-- completion content plus the dedicated proof column.
--
-- Draft-only migration until peer reviewed and applied.
-- =============================================================

CREATE OR REPLACE FUNCTION public.tram_completion_scope_text(
  p_receipt text,
  p_max_depth integer DEFAULT 8
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  scope_text text;
BEGIN
  IF p_receipt IS NULL OR btrim(p_receipt) = '' THEN
    RETURN '';
  END IF;

  WITH RECURSIVE scope AS (
    SELECT
      m.receipt,
      m.in_reply_to,
      COALESCE(m.subject, '') AS subject,
      COALESCE(m.content, '') AS content,
      COALESCE(m.proof, '') AS proof,
      0 AS depth
    FROM public.tram_messages m
    WHERE m.receipt = p_receipt

    UNION ALL

    SELECT
      parent.receipt,
      parent.in_reply_to,
      COALESCE(parent.subject, ''),
      COALESCE(parent.content, ''),
      COALESCE(parent.proof, ''),
      scope.depth + 1
    FROM scope
    JOIN public.tram_messages parent
      ON parent.receipt = scope.in_reply_to
    WHERE scope.depth < GREATEST(COALESCE(p_max_depth, 8), 0)
  )
  SELECT string_agg(
           concat_ws(E'\n', receipt, subject, content, proof),
           E'\n---\n'
           ORDER BY depth
         )
    INTO scope_text
  FROM scope;

  RETURN COALESCE(scope_text, '');
END;
$$;

CREATE OR REPLACE FUNCTION public.tram_scope_requires_db_proof(
  p_task_receipt text,
  p_content text DEFAULT NULL,
  p_proof text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  WITH scope_text AS (
    SELECT concat_ws(
             E'\n',
             COALESCE(public.tram_completion_scope_text(p_task_receipt, 8), ''),
             COALESCE(p_content, ''),
             COALESCE(p_proof, '')
           ) AS value
  )
  SELECT
    value ~* 'gandalf:execute_sql'
    OR value ~* '(^|[^A-Za-z])(UPDATE|INSERT|DELETE)([^A-Za-z]|$)'
    OR value ~* 'span_attributions'
    OR value ~* 'CONTEXT_PTRS:[^\r\n]*\.sql'
    OR value ~* '/scripts/sql/'
  FROM scope_text;
$$;

CREATE OR REPLACE FUNCTION public.tram_enforce_proof_gate()
RETURNS TRIGGER AS $$
DECLARE
  completion_text text;
  task_receipt text;
  requires_db_proof boolean;
  has_real_git_proof boolean;
  has_real_deploy_proof boolean;
  has_git_or_deploy_fields boolean;
  has_db_proof boolean;
  has_db_before_count boolean;
  has_db_after_count boolean;
  has_db_rows_affected boolean;
  claims_repo_paths boolean;
BEGIN
  IF NEW.kind = 'completion' THEN
    NEW.governance_flags := COALESCE(NEW.governance_flags, '[]'::jsonb);
    completion_text := concat_ws(
      E'\n',
      COALESCE(NEW.content, ''),
      COALESCE(NEW.proof, '')
    );
    task_receipt := COALESCE(
      NULLIF(NEW.completes_receipt, ''),
      NULLIF(NEW.in_reply_to, '')
    );

    has_real_git_proof := completion_text ~* 'GIT_PROOF:\s*[a-f0-9]{7,40}';
    has_real_deploy_proof :=
      completion_text ~* 'DEPLOY_PROOF:\s*[^\s]'
      AND completion_text !~* 'DEPLOY_PROOF:\s*(N/A|NONE)(\b|\s|$)';
    has_git_or_deploy_fields :=
      completion_text ~* 'GIT_PROOF:\s*[^\r\n]+'
      OR completion_text ~* 'DEPLOY_PROOF:\s*[^\r\n]+';
    has_db_proof := completion_text ~* 'DB_PROOF:\s*[^\s]';
    has_db_before_count := completion_text ~* 'before_count\s*[:=]\s*\d+';
    has_db_after_count := completion_text ~* 'after_count\s*[:=]\s*\d+';
    has_db_rows_affected := completion_text ~* 'rows_affected\s*[:=]\s*\d+';
    requires_db_proof := public.tram_scope_requires_db_proof(
      task_receipt,
      NEW.content,
      NEW.proof
    );
    claims_repo_paths := completion_text ~* '(^|[[:space:]])(ora/|docs/|src/|camber/|orbit/)';

    IF requires_db_proof THEN
      IF NOT has_db_proof THEN
        NEW.proof_compliant := false;
        NEW.governance_flags := NEW.governance_flags
          || jsonb_build_array(jsonb_build_object(
            'rule', 'PROOF_GATE_V2',
            'violation', 'DB task missing DB_PROOF. file_written/GIT_PROOF/DEPLOY_PROOF alone is insufficient',
            'task_receipt', task_receipt,
            'detected_at', now()::text
          ));
        NEW.governance_hold := true;
        RETURN NEW;
      END IF;

      IF NOT (
        (has_db_before_count AND has_db_after_count)
        OR has_db_rows_affected
      ) THEN
        NEW.proof_compliant := false;
        NEW.governance_flags := NEW.governance_flags
          || jsonb_build_array(jsonb_build_object(
            'rule', 'PROOF_GATE_V2',
            'violation', 'DB_PROOF must include before_count/after_count or rows_affected',
            'task_receipt', task_receipt,
            'detected_at', now()::text
          ));
        NEW.governance_hold := true;
        RETURN NEW;
      END IF;

      NEW.proof_compliant := true;
      RETURN NEW;
    END IF;

    IF has_git_or_deploy_fields THEN
      IF has_real_git_proof OR has_real_deploy_proof THEN
        NEW.proof_compliant := true;
      ELSE
        IF claims_repo_paths THEN
          NEW.proof_compliant := false;
          NEW.governance_flags := NEW.governance_flags
            || jsonb_build_array(jsonb_build_object(
              'rule', 'PROOF_GATE',
              'violation', 'Claims repo artifacts but GIT_PROOF/DEPLOY_PROOF are only N/A',
              'detected_at', now()::text
            ));
          NEW.governance_hold := true;
        ELSE
          NEW.proof_compliant := true;
        END IF;
      END IF;
    ELSE
      NEW.proof_compliant := false;
      NEW.governance_flags := NEW.governance_flags
        || jsonb_build_array(jsonb_build_object(
          'rule', 'PROOF_GATE',
          'violation', 'Completion missing proof fields entirely',
          'detected_at', now()::text
        ));
      NEW.governance_hold := true;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
