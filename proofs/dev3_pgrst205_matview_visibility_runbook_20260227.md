# PGRST205 Matview Visibility Runbook (DEV-3)

Date: 2026-02-27
Scope: Supabase/PostgREST returning `PGRST205` for a new materialized view endpoint.

## Symptom

REST call returns HTTP 404 with:
- `code: PGRST205`
- `message: Could not find the table 'public.<matview_name>' in the schema cache`

Example probe:
```bash
curl -i -G "$SUPABASE_REST_URL/redline_contacts_mv" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Prefer: count=exact" \
  --data-urlencode "select=*" \
  --data-urlencode "limit=1"
```

## Decision tree

1. Confirm object exists in DB first (not a cache issue if object is absent).
2. If object exists, confirm grants + schema exposure.
3. Trigger PostgREST schema cache reload.
4. Verify endpoint/path appears and query succeeds.

## Step-by-step (SQL Editor)

### 1) Existence check
```sql
select to_regclass('public.redline_contacts_mv') as obj;

select schemaname, matviewname
from pg_matviews
where schemaname = 'public'
  and matviewname = 'redline_contacts_mv';
```

Expected:
- non-null `obj`
- one row in `pg_matviews`

If missing:
- migration not applied in this environment; apply migration first (or create MV manually), then continue.

### 2) Permission check/grants
```sql
grant select on public.redline_contacts_mv to anon, authenticated, service_role;
```

(Use least privilege for your API surface; for operator-only endpoints, keep `service_role` only.)

### 3) Refresh PostgREST schema cache
```sql
notify pgrst, 'reload schema';
```

If you also changed API config/schemas:
```sql
notify pgrst, 'reload config';
```

### 4) Verification checklist

- REST probe no longer returns `PGRST205`.
- OpenAPI includes `/redline_contacts_mv` path:
```bash
tmp=$(mktemp)
curl -sS "$SUPABASE_URL/rest/v1/" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" > "$tmp"
jq -r '.paths | keys[]' "$tmp" | rg '/redline_contacts_mv'
rm -f "$tmp"
```
- Endpoint query returns 200 and data/count:
```bash
curl -sS -G "$SUPABASE_REST_URL/redline_contacts_mv" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Prefer: count=exact" \
  --data-urlencode "select=*" \
  --data-urlencode "limit=1"
```

## Notes

- `PGRST205` can be either cache staleness OR object absence in target env; always run existence check first.
- In this environment snapshot, `redline_contacts_mv` endpoint returned `PGRST205`, so run the tree above before assuming stale cache only.
