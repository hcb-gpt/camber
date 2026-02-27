-- Migration 020: Expand canonical FOR_SESSION token support.
WITH source_values AS (
  SELECT
    m.receipt,
    COALESCE(
      NULLIF(btrim(m.for_session), ''),
      (regexp_match(COALESCE(m.content, ''), '(?im)^\s*FOR_SESSION\s*[:=]\s*(.+)$'))[1],
      (regexp_match(COALESCE(m.content, ''), '(?im)^\s*FORSESSION\s*[:=]\s*(.+)$'))[1]
    ) AS raw_value
  FROM public.tram_messages m
),
split_tokens AS (
  SELECT
    s.receipt,
    p.ord,
    lower(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            btrim(p.part),
            '^[`"''\(\[\{<\s]+',
            '',
            'g'
          ),
          '([[:space:]]|\().*$',
          '',
          'g'
        ),
        '[`"''\)\]\}>.,;:!?]+$',
        '',
        'g'
      )
    ) AS normalized_token
  FROM source_values s
  CROSS JOIN LATERAL regexp_split_to_table(COALESCE(s.raw_value, ''), ',') WITH ORDINALITY AS p(part, ord)
  WHERE COALESCE(s.raw_value, '') <> ''
),
valid_tokens AS (
  SELECT receipt, ord, normalized_token
  FROM split_tokens
  WHERE normalized_token ~ '^[a-z]+-(?:vp|[a-z0-9_-]*[0-9][a-z0-9_-]*)$'
),
dedup AS (
  SELECT receipt, normalized_token, MIN(ord) AS first_ord
  FROM valid_tokens
  GROUP BY receipt, normalized_token
),
aggregated AS (
  SELECT receipt, string_agg(normalized_token, ',' ORDER BY first_ord) AS canonical_for_session
  FROM dedup
  GROUP BY receipt
)
UPDATE public.tram_messages m
SET for_session = a.canonical_for_session
FROM aggregated a
WHERE m.receipt = a.receipt
  AND COALESCE(m.for_session, '') IS DISTINCT FROM COALESCE(a.canonical_for_session, '');

-- Rows with invalid/no-valid targets should not retain malformed session locks.
UPDATE public.tram_messages m
SET for_session = NULL
WHERE m.for_session IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM (
      SELECT lower(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              btrim(token_part),
              '^[`"''\(\[\{<\s]+',
              '',
              'g'
            ),
            '([[:space:]]|\().*$',
            '',
            'g'
          ),
          '[`"''\)\]\}>.,;:!?]+$',
          '',
          'g'
        )
      ) AS token
      FROM regexp_split_to_table(m.for_session, ',') AS token_part
    ) t
    WHERE t.token ~ '^[a-z]+-(?:vp|[a-z0-9_-]*[0-9][a-z0-9_-]*)$'
  );;
