# Bootstrap Review Queue Invalid Auth Probe

- Timestamp UTC: 2026-03-02T19:24:31Z
- Endpoint: `https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/bootstrap-review?action=queue&limit=1`
- Probe loop: 50 requests
- Headers: `apikey` + `Authorization: Bearer` using anon key from `ios/CamberRedline/CamberRedline/Config.xcconfig`

## Results
- `200`: 50
- `403`: 0
- `000` (request/connection failure): 0

No `sb-request-id` values were observed for 403 responses because no 403s occurred.
