-- Striking Signals Table
-- Stores per-span "striking sense" detections from striking-detect Edge Function
-- Part of the Journal/World Model project

CREATE TABLE IF NOT EXISTS striking_signals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  span_id UUID NOT NULL,
  interaction_id TEXT NOT NULL,
  call_id TEXT,

  -- Striking score (0.0 to 1.0)
  striking_score NUMERIC NOT NULL CHECK (striking_score >= 0 AND striking_score <= 1),

  -- Typed signals detected in the span
  signals JSONB NOT NULL DEFAULT '[]'::jsonb,
  -- Each signal: { "type": "decision_point|scope_change|financial_signal|...", "text": "...", "confidence": 0.0-1.0 }

  -- Primary signal type (highest confidence)
  primary_signal_type TEXT,

  -- Model metadata
  model_id TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  tokens_used INTEGER DEFAULT 0,
  inference_ms INTEGER DEFAULT 0,

  -- Lifecycle
  created_at TIMESTAMPTZ DEFAULT NOW(),

  -- Indexes handled below
  CONSTRAINT fk_striking_signals_span FOREIGN KEY (span_id) REFERENCES conversation_spans(id)
);
-- Performance indexes
CREATE INDEX idx_striking_signals_span ON striking_signals(span_id);
CREATE INDEX idx_striking_signals_interaction ON striking_signals(interaction_id);
CREATE INDEX idx_striking_signals_score ON striking_signals(striking_score DESC);
CREATE INDEX idx_striking_signals_high ON striking_signals(striking_score) WHERE striking_score >= 0.7;
CREATE INDEX idx_striking_signals_type ON striking_signals(primary_signal_type) WHERE primary_signal_type IS NOT NULL;
-- Unique constraint: one striking detection per span per model/prompt version
CREATE UNIQUE INDEX idx_striking_signals_upsert ON striking_signals(span_id, model_id, prompt_version);
