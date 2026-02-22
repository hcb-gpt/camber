-- assembler_diagnostics: tracks evidence-assembler + decision-auditor execution
-- per span. Written by segment-call (orchestrator), never by the LLM layers.
CREATE TABLE assembler_diagnostics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  span_id UUID NOT NULL REFERENCES conversation_spans(id),
  run_id UUID NOT NULL,
  assembler_triggered BOOLEAN NOT NULL DEFAULT false,
  auditor_triggered BOOLEAN NOT NULL DEFAULT false,
  gating_reasons TEXT[],
  evidence_brief JSONB,
  audit_report JSONB,
  auditor_verdict TEXT CHECK (auditor_verdict IN ('confirm','downgrade','escalate')),
  assembler_iterations INT,
  assembler_tool_calls INT,
  assembler_wall_clock_ms INT,
  auditor_iterations INT,
  auditor_tool_calls INT,
  auditor_wall_clock_ms INT,
  tool_call_log JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_assembler_diag_span ON assembler_diagnostics(span_id);
CREATE INDEX idx_assembler_diag_verdict ON assembler_diagnostics(auditor_verdict)
  WHERE auditor_verdict IS NOT NULL;
