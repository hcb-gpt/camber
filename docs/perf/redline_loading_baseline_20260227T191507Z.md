# Redline Loading Baseline (20260227T191507Z)

- Base URL:   https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/redline-thread
- First contact id used:   c9b2d3e4-f5a6-7890-bcde-f01234567890
- Goal bar: 5x improvement target => p95 <= 1.0s under same conditions.

## Endpoint stats (time_total seconds)

- html_shell: runs=15, status=200, p50=0.301641, p95=0.333611, avg=0.29963573333333327, p95_ttfb=0.330218
- projects: runs=15, status=200, p50=0.299549, p95=0.321228, avg=0.30049986666666667, p95_ttfb=0.317088
- thread_first_contact: runs=15, status=200, p50=1.151301, p95=1.198826, avg=1.1360036, p95_ttfb=1.198390

## Deployed redline-thread metadata

```json
{
  "name": "redline-thread",
  "version": 31,
  "entrypoint_path": "file:///home/runner/work/camber-calls/camber-calls/supabase/functions/redline-thread/index.ts",
  "verify_jwt": false,
  "updated_at": 1772217559251
}
```
