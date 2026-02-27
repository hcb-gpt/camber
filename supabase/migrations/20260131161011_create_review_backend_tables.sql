-- review_backend_contract: review_resolutions + review_receipts
-- Extends review_queue for resolution pointers

-- 1) Ensure review_queue has resolution tracking columns
ALTER TABLE IF EXISTS review_queue
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS resolved_by uuid,
  ADD COLUMN IF NOT EXISTS resolution_id uuid;

-- 2) review_resolutions (append-only)
CREATE TABLE IF NOT EXISTS review_resolutions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid NOT NULL REFERENCES review_queue(id) ON DELETE CASCADE,
  span_id uuid NOT NULL REFERENCES conversation_spans(id),
  interaction_id text NOT NULL,
  generation int NOT NULL,
  action text NOT NULL CHECK (action IN ('approve','change','unknown')),
  change_payload jsonb,
  actor_id uuid NOT NULL,
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS review_resolutions_actor_idem_uq
  ON review_resolutions(actor_id, idempotency_key);

CREATE INDEX IF NOT EXISTS review_resolutions_item_idx
  ON review_resolutions(item_id);

-- 3) review_receipts (append-only)
CREATE TABLE IF NOT EXISTS review_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid NOT NULL REFERENCES review_queue(id) ON DELETE CASCADE,
  resolution_id uuid NOT NULL REFERENCES review_resolutions(id) ON DELETE CASCADE,
  receipt_type text NOT NULL,
  receipt jsonb NOT NULL,
  actor_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS review_receipts_item_idx
  ON review_receipts(item_id);

CREATE INDEX IF NOT EXISTS review_receipts_resolution_idx
  ON review_receipts(resolution_id);

COMMENT ON TABLE review_resolutions IS 'Append-only log of review item resolutions (approve/change/unknown)';
COMMENT ON TABLE review_receipts IS 'Append-only receipts attached to resolutions';;
