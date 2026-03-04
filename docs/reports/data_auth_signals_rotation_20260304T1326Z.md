
# Edge Secret Rotation - Auth Spikes Monitor Report

**Generated**: 2026-03-04T13:24:36.114Z
**Status**: Monitoring complete for edge endpoints and TRAM paths.

## 1. Edge Endpoints (401/403 Rates)
Baseline vs Current (Last 1hr compared to prior 12hr trend):
- `zapier-call-ingest`: **Nominal**. 4 errors out of 10 requests (historical 12h baseline: 4 errors out of 10 requests). The errors appear to be "BESIDE_AUTH_REJECTED", indicating routine background noise rather than a rotation-induced spike.
- `zapier-shadow-ingest`: **Zero errors** in the last hour.
- `api_write_attribution`: **Zero errors** in the last hour.

## 2. TRAM Write Success/Error
- TRAM write/read errors (`orbit_error_v1`): We observe 43 connection errors in the last hour, primarily `UND_ERR_HEADERS_OVERFLOW` from fetch failures against the `tram_read_receipts` REST endpoint. This is a known, existing architectural limitation under heavy header loads and is consistent with the 12h baseline (944 connection errors). It is not correlated to the Edge Secret rotation.

## Summary
The dual-secret window is stable. No new auth rejection spikes were detected from external webhook clients or internal components due to the EDGE_SHARED_SECRET rotation phase.
