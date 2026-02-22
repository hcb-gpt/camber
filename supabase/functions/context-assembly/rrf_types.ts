/**
 * Shared types for RRF fusion module.
 * Mirrors the ProjectFactRow interface from index.ts to avoid circular imports.
 */

export interface ProjectFactRow {
  project_id: string;
  as_of_at: string;
  observed_at: string;
  fact_kind: string;
  fact_payload: any;
  evidence_event_id: string | null;
  interaction_id: string | null;
}
