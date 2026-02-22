# Service Relay SQL Pack (Gift Artifact)

Use this as copy/paste verification for reliability + exposure lanes.

## 1) Embed Acceptance Snapshot
```sql
SELECT
  COUNT(*) FILTER (WHERE embedding IS NOT NULL AND created_at >= now() - interval '24 hours') AS embedded_24h,
  COUNT(*) FILTER (WHERE embedding IS NOT NULL AND created_at >= now() - interval '2 hours')  AS embedded_2h,
  MAX(created_at) FILTER (WHERE embedding IS NOT NULL)                                         AS latest_embedded_claim_at,
  EXTRACT(EPOCH FROM (now() - MAX(created_at) FILTER (WHERE embedding IS NOT NULL))) / 3600.0 AS hours_since_latest_embedded,
  COUNT(*) FILTER (WHERE embedding IS NULL AND created_at >= now() - interval '24 hours')      AS unembedded_24h
FROM public.journal_claims;
```

## 2) Financial Exposure Semantics Check
```sql
SELECT
  COUNT(*) AS total_rows,
  COUNT(*) FILTER (
    WHERE COALESCE(total_committed,0) + COALESCE(total_invoiced,0) + COALESCE(total_pending,0) = 0
  ) AS zero_only_rows,
  COUNT(*) FILTER (
    WHERE COALESCE(total_committed,0) + COALESCE(total_invoiced,0) + COALESCE(total_pending,0) > 0
  ) AS positive_rows,
  SUM(total_committed) AS sum_total_committed,
  SUM(total_invoiced)  AS sum_total_invoiced,
  SUM(total_pending)   AS sum_total_pending,
  SUM(item_count)      AS sum_item_count
FROM public.v_financial_exposure;
```

## 3) Delta Template (Before/After)
```sql
WITH now_metrics AS (
  SELECT
    COUNT(*) FILTER (WHERE embedding IS NOT NULL AND created_at >= now() - interval '24 hours') AS embedded_24h,
    COUNT(*) FILTER (WHERE embedding IS NULL AND created_at >= now() - interval '24 hours')      AS unembedded_24h
  FROM public.journal_claims
)
SELECT
  embedded_24h,
  unembedded_24h
FROM now_metrics;
```

## 4) 5-Line Runbook Snippet
1. Run query (1) and save output as baseline.
2. Execute bounded writer/backfill action.
3. Re-run query (1) and check `embedded_24h` up / `unembedded_24h` down.
4. Run query (2) to avoid financial semantic regressions.
5. Paste before/after + query text in completion receipt.
