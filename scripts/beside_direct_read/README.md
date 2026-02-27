# Beside Direct-Read Prototype v0

This prototype reads Beside's local room cache (`cached_rooms.json`), decodes each base64 `room` blob, extracts one stable event per room (`message` or `call`), normalizes timestamps, and emits an ingest-ready stub payload.

## Script

`extract_beside_cached_rooms_v0.py`

## Timestamp Normalization

The parser normalizes three timestamp formats into `occurred_at_utc`:

1. Unix milliseconds (`1772237091000`)
2. Unix seconds (`1772237091`)
3. Apple CFAbsoluteTime seconds since `2001-01-01T00:00:00Z` (`793899283.778`)

## Usage

```bash
python3 scripts/beside_direct_read/extract_beside_cached_rooms_v0.py \
  --input scripts/beside_direct_read/fixtures/cached_rooms.synthetic.json \
  --output proofs/dev2_beside_direct_read_extract_v0_synthetic_20260227.json \
  --ingest-stub-output proofs/dev2_beside_direct_read_ingest_stub_v0_synthetic_20260227.json
```

## Fixture

Synthetic fixture (contains one message room and one call room):

`scripts/beside_direct_read/fixtures/cached_rooms.synthetic.json`

