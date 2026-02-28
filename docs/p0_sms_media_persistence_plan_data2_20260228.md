# P0 SMS Media Persistence Plan (DATA-2, 2026-02-28)

## Problem statement
Current SMS pipeline persists message text but not attachment metadata. Read-path APIs therefore have no stable attachment records to sign/serve, which explains black/empty image render states.

## DB proof (current gap)
Validated with:
- `scripts/sql/p0_sms_media_missing_proof_data2_20260228.sql`

Representative message IDs with picture intent but no persisted attachment fields:
- `msg_06EA2XAASSS538WKD3MYSRWPT0`
- `msg_06EA2XKZ81SH5AE0JXD7A4D1WG`

For both rows, `calls_raw.raw_snapshot_json` contains no structured attachment keys (`attachment`, `attachments`, `media_url`, `image_url` all false), and schema has no dedicated SMS attachment table/columns.

## MVP schema proposal
### 1) `public.sms_message_attachments`
Purpose: canonical persisted attachment metadata keyed to SMS message.

Columns:
- `id uuid primary key default gen_random_uuid()`
- `message_id text not null` (FK target: `sms_messages.message_id`)
- `interaction_id text null` (FK-like pointer to `calls_raw.interaction_id`, typically `sms_msg_*`)
- `attachment_index integer not null default 0`
- `provider text not null` (e.g., `beside`)
- `provider_attachment_id text null`
- `storage_provider text not null` (e.g., `supabase_storage`, `s3`)
- `storage_key text not null` (stable object key; no signed URL persisted)
- `mime_type text null`
- `filename text null`
- `size_bytes bigint null`
- `width integer null`
- `height integer null`
- `sha256 text null`
- `source_payload jsonb not null default '{}'::jsonb`
- `captured_at_utc timestamptz null`
- `ingested_at_utc timestamptz not null default now()`
- `updated_at_utc timestamptz not null default now()`

Constraints/Indexes:
- Unique: `(message_id, attachment_index)`
- Unique (optional if provider id reliable): `(provider, provider_attachment_id)`
- Indexes: `(message_id)`, `(interaction_id)`, `(storage_key)`

### 2) `public.v_sms_messages_with_attachments` (read helper)
Purpose: one-row-per-message projection with `attachments jsonb[]` shape for API emitters.

Output shape (per attachment object):
- `attachment_id`
- `provider`
- `storage_provider`
- `storage_key`
- `mime_type`
- `filename`
- `size_bytes`
- `width`
- `height`

## Minimal implementation plan (ingest -> persist -> signed URL)
1. Ingest extraction:
- In SMS ingest/assembler, parse provider payload attachment list (if present).
- Normalize each attachment into the schema above.

2. Persist:
- Upsert into `sms_message_attachments` by `(message_id, attachment_index)` (idempotent).
- Persist only stable storage identity (`storage_provider`, `storage_key`), never short-lived signed URLs.

3. Read-time signing:
- At API read path (`redline-thread` / context packet), load message attachments by `message_id`.
- Resolve signed URLs just-in-time from `storage_key` with short TTL.
- Emit signed URL fields in response only (not DB): `url`, `thumbnail_url`, `expires_at`.

4. API contract:
- Add `messages[].attachments[]`:
  - `attachment_id`, `mime_type`, `filename`, `size_bytes`, `width`, `height`
  - `url`, `thumbnail_url`, `expires_at`

## Queue after MVP
1. Historical backfill:
- Pull available attachment metadata from provider history where recoverable.
- Populate `sms_message_attachments` with `source_payload.backfill=true`.

2. Contract hardening:
- Add schema-level checks for required fields when `storage_key` is present.
- Add monitor for messages that reference picture/photo keywords but have zero attachments.

3. UI follow-through:
- Render image cards from `messages[].attachments[]`.
- Tap-to-open using signed URL.

