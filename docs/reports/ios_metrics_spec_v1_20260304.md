# iOS Truth-Forcing Metrics Spec

**Goal**: Establish self-evaluating metrics for iOS triage surfaces (swipe, picker) to measure learning loop effectiveness, latency, and failure rates.

## Proposed Metrics

### 1. `pick_time_p90` (Time to Pick)
- **Definition**: The p90 duration (in milliseconds) from when an attribution truth surface (like the picker overlay or swipe card) is rendered on screen until the user makes an explicit selection (pick, dismiss, or confirm).
- **Purpose**: Measures cognitive load and surface friction. If pick times are high, the surface is too complex or options are poorly ordered.
- **Source**: Client telemetry.

### 2. `undo_rate` (Correction Rate)
- **Definition**: The percentage of completed picks/swipes that are subsequently overridden, modified, or "undone" by the user within the same session.
- **Purpose**: Measures confidence and accuracy. A high undo rate signals accidental interactions, confusing UI, or poor default selections.
- **Source**: Client telemetry.

### 3. `write_fail_rate` (Error Rate)
- **Definition**: The percentage of truth-forcing writes (API requests to edge functions/backend to commit the pick) that fail with HTTP 4xx/5xx (e.g., 401/403 auth locks, 500 server errors).
- **Purpose**: Tracks operational reliability of the learning loop. If writes drop, the loop is broken.
- **Source**: Server DB (`diagnostic_logs`).

### 4. `mislabel_proxy` (Downstream Re-correction)
- **Definition**: The rate at which an iOS-originated truth attribution (where `reason = 'ios_app'`) is later overridden by another operator or process.
- **Purpose**: Measures the ground-truth validity of the iOS operator's choice. 
- **Source**: Server DB (`override_log`).

---

## Data Sourcing & Query Sketch

### A. Client Telemetry Requirements (DEV Action)

To accurately compute `pick_time_p90` and `undo_rate`, the iOS client must emit specific events into `diagnostic_logs`. 
**Required Event Payload (JSON)**:
```json
{
  "function_name": "ios_telemetry",
  "log_level": "info",
  "message": "triage_surface_interaction",
  "metadata": {
    "surface_type": "swipe_card | picker_overlay",
    "interaction_id": "cll_...",
    "action": "confirm | reject | pick | dismiss | undo",
    "duration_ms": 1250,
    "selected_project_id": "uuid",
    "previous_project_id": "uuid"
  }
}
```
*Action for DEV*: Instrument these properties in the existing iOS analytics/telemetry layer, dispatching to the DB.

### B. Server Logs / DB Queries (DATA Implementation)

*Assuming the client events route into `diagnostic_logs`.*

**1. Query for `pick_time_p90` (PostgreSQL)**
```sql
SELECT 
  percentile_cont(0.90) WITHIN GROUP (ORDER BY (metadata->>'duration_ms')::numeric) AS pick_time_p90_ms
FROM public.diagnostic_logs
WHERE function_name = 'ios_telemetry'
  AND message = 'triage_surface_interaction'
  AND metadata->>'action' IN ('confirm', 'pick')
  AND created_at >= NOW() - INTERVAL '7 days';
```

**2. Query for `undo_rate`**
```sql
WITH interactions AS (
  SELECT 
    COUNT(*) AS total_picks,
    COUNT(*) FILTER (WHERE metadata->>'action' = 'undo') AS undo_picks
  FROM public.diagnostic_logs
  WHERE function_name = 'ios_telemetry'
    AND message = 'triage_surface_interaction'
    AND created_at >= NOW() - INTERVAL '7 days'
)
SELECT 
  total_picks,
  undo_picks,
  ROUND((undo_picks::numeric / NULLIF(total_picks, 0)) * 100, 2) AS undo_rate_pct
FROM interactions;
```

**3. Query for `write_fail_rate`**
```sql
-- Evaluates backend write errors for the specific edge function receiving the iOS edits
SELECT 
  ROUND((COUNT(*) FILTER (WHERE log_level = 'error' OR metadata->>'status_code' IN ('401','403','500'))::numeric / NULLIF(COUNT(*), 0)) * 100, 2) AS fail_rate_pct
FROM public.diagnostic_logs
WHERE function_name = 'api_write_attribution' -- Adjust to actual endpoint name
  AND metadata->>'client_type' = 'ios'
  AND created_at >= NOW() - INTERVAL '7 days';
```

**4. Query for `mislabel_proxy`**
```sql
WITH ios_claims AS (
  SELECT id AS override_id, entity_key
  FROM public.override_log
  WHERE reason = 'ios_app'
    AND created_at >= NOW() - INTERVAL '7 days'
), corrections AS (
  SELECT o2.entity_key
  FROM public.override_log o2
  JOIN ios_claims i ON o2.entity_key = i.entity_key AND o2.created_at > i.created_at
  WHERE o2.reason != 'ios_app'
)
SELECT 
  (SELECT COUNT(*) FROM ios_claims) AS total_ios_claims,
  (SELECT COUNT(DISTINCT entity_key) FROM corrections) AS corrected_claims,
  ROUND(( (SELECT COUNT(DISTINCT entity_key) FROM corrections)::numeric / NULLIF((SELECT COUNT(*) FROM ios_claims), 0) ) * 100, 2) AS mislabel_rate_pct;
```

---

## Next Steps
- **DEV**: Review the required client JSON telemetry payload and add instrumentation.
- **DATA**: Once telemetry flows, formalize the above queries into a materialized view (`v_ios_truth_metrics`) or a daily cron snapshot.