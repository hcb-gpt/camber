# bootstrap-review queue probe (20260302T193415Z)

Decision-relevant datapoint: do we still see intermittent **403 invalid_auth** on **bootstrap-review?action=queue** reads (post-PR353 merge)?

## Request
- URL: `https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/bootstrap-review?action=queue&limit=1`
- Headers: `apikey: <anon>` and `Authorization: Bearer <anon>`
- Anon key: `eyJhbGciOiJIUzI1…cxewGmuWio`
- Requests: `60` (curl max-time `10s`)
- Elapsed: `116.9s`
- function_version (from body): `bootstrap-review_v1.3.2`

## Results
- HTTP 000: `2`
- HTTP 200: `58`

## Edge regions
- `us-east-1`: `58`

## Samples
- 200 sb-request-id: `019cb009-7ece-7911-802b-b0ac2c36c952`
- 000/transport: `curl: (28) Operation timed out after 10006 milliseconds with 0 bytes received`
