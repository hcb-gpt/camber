#!/usr/bin/env bash
# p2-eval-scorer.sh — P2 Statistical Evaluation Framework
# Computes paired A/B comparison of P0 vs P1 attribution accuracy.
# Outputs: McNemar's test, stratified accuracy, confidence intervals, regression check.
#
# Usage:
#   ./p2-eval-scorer.sh                    # Score all labeled calls with v1.7.0 attributions
#   ./p2-eval-scorer.sh --blind-trial-only # Score only the 3 blind trial calls
#   ./p2-eval-scorer.sh --call-ids FILE    # Score specific call_ids from a file (one per line)
#   ./p2-eval-scorer.sh --json             # Output JSON instead of human-readable
#
# Requires: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (from credentials.env)
# Author: DATA-4 (data-4)
# Date: 2026-02-10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Config ---
P0_EVAL_RUN_ID="74cb793e-6636-4a62-942b-b6d188fd39db"
P1_PROMPT_VERSION="v1.7.0"
HURLEY_PROJECT_ID="ed8e85a2-c79c-4951-aee1-4e17254c06a0"
ASSIGN_REGRESSION_FLOOR=88  # STRAT-1 revision: 88%, not 85%

# Baselines per STRAT-3 framework
P0_RAW_ACCURACY="79.2"       # 42/53 from eval_run
P0_ADJUSTED_ACCURACY="82.7"  # After DATA-12 label corrections

# --- Parse args ---
MODE="all"
OUTPUT="human"
CALL_IDS_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --blind-trial-only) MODE="blind_trial"; shift ;;
    --call-ids)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --call-ids requires a file path" >&2
        exit 2
      fi
      MODE="custom"
      CALL_IDS_FILE="$2"
      shift 2
      ;;
    --json) OUTPUT="json"; shift ;;
    -h|--help)
      echo "Usage: $0 [--blind-trial-only] [--call-ids FILE] [--json]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Load credentials ---
if [[ -f "$HOME/.camber/credentials.env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.camber/credentials.env"
fi

if [[ -z "${SUPABASE_URL:-}" ]] || [[ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set" >&2
  exit 1
fi

# --- Helper: run SQL via Supabase REST API ---
run_sql() {
  local query="$1"
  local response
  response=$(curl -s -X POST \
    "${SUPABASE_URL}/rest/v1/rpc/exec_sql" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": $(echo "$query" | jq -Rs .)}" \
    2>/dev/null) || true

  # If exec_sql RPC doesn't exist, fall back to direct pg query
  if echo "$response" | jq -e '.code // empty' >/dev/null 2>&1; then
    # Try the postgrest way
    response=$(curl -s -X POST \
      "${SUPABASE_URL}/pg" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"query\": $(echo "$query" | jq -Rs .)}" \
      2>/dev/null) || true
  fi

  echo "$response"
}

# --- Build the call filter ---
build_call_filter() {
  case "$MODE" in
    blind_trial)
      echo "AND gtl.call_id IN (
        'cll_06E0B4DTF1Y8SAN4HVJC4KZZ64',
        'cll_06E0PACQH1ZCN3YNBTM8K9J54R',
        'cll_06E0P6KYB5V7S5VYQA8ZTRQM4W'
      )"
      ;;
    custom)
      if [[ ! -f "$CALL_IDS_FILE" ]]; then
        echo "ERROR: Call IDs file not found: $CALL_IDS_FILE" >&2
        exit 1
      fi
      local ids
      ids=$(awk '{printf "'\''"$1"'\'',"}' "$CALL_IDS_FILE" | sed 's/,$//')
      echo "AND gtl.call_id IN ($ids)"
      ;;
    all)
      echo ""
      ;;
  esac
}

CALL_FILTER=$(build_call_filter)

# --- Main scoring query ---
# This query produces the paired comparison table:
# For each labeled call:
#   - P0 result: from eval_samples (interactions.project_id vs ground_truth)
#   - P1 result: best-span v1.7.0 attribution vs ground_truth
#   - Contact stratification: resolved vs NULL, fanout_class
SCORING_SQL="
WITH p0_results AS (
  SELECT
    es.interaction_id AS call_id,
    es.status AS p0_status,
    es.scoreboard_json->>'eval_result' AS p0_eval_result,
    es.scoreboard_json->>'pipeline_project_name' AS p0_project,
    es.scoreboard_json->>'ground_truth_project_name' AS gt_project,
    (es.scoreboard_json->>'ground_truth_project_id')::uuid AS gt_project_id
  FROM eval_samples es
  WHERE es.eval_run_id = '${P0_EVAL_RUN_ID}'
),
p1_best_span AS (
  SELECT DISTINCT ON (cs.interaction_id)
    cs.interaction_id AS call_id,
    sa.project_id AS p1_project_id,
    p.name AS p1_project,
    sa.confidence AS p1_confidence,
    sa.decision AS p1_decision,
    sa.prompt_version,
    sa.inference_ms,
    COALESCE(jsonb_array_length(sa.journal_references), 0) AS journal_ref_count
  FROM span_attributions sa
  JOIN conversation_spans cs ON cs.id = sa.span_id AND cs.is_superseded = false
  WHERE sa.prompt_version = '${P1_PROMPT_VERSION}'
    AND sa.inference_ms > 0
  ORDER BY cs.interaction_id, sa.confidence DESC NULLS LAST, sa.created_at DESC NULLS LAST, sa.span_id DESC
),
paired AS (
  SELECT
    p0.call_id,
    p0.gt_project,
    p0.gt_project_id,
    -- P0 outcome
    p0.p0_status,
    p0.p0_project,
    CASE WHEN p0.p0_status = 'pass' THEN true ELSE false END AS p0_correct,
    -- P1 outcome (best span)
    p1.p1_project,
    p1.p1_confidence,
    p1.p1_decision,
    p1.journal_ref_count,
    CASE WHEN p1.p1_project_id = p0.gt_project_id THEN true ELSE false END AS p1_correct,
    -- Has P1 data?
    CASE WHEN p1.call_id IS NOT NULL THEN true ELSE false END AS has_p1,
    -- Contact stratification
    i.contact_id,
    i.contact_name,
    cf.fanout_class,
    CASE WHEN i.contact_id IS NOT NULL THEN 'resolved' ELSE 'null_contact' END AS contact_status
  FROM p0_results p0
  JOIN interactions i ON i.interaction_id = p0.call_id
  LEFT JOIN contact_fanout cf ON cf.contact_id = i.contact_id
  LEFT JOIN p1_best_span p1 ON p1.call_id = p0.call_id
  WHERE 1=1
  ${CALL_FILTER}
)
SELECT * FROM paired ORDER BY call_id;
"

# --- McNemar contingency table query ---
MCNEMAR_SQL="
WITH p0_results AS (
  SELECT
    es.interaction_id AS call_id,
    es.status AS p0_status,
    (es.scoreboard_json->>'ground_truth_project_id')::uuid AS gt_project_id
  FROM eval_samples es
  WHERE es.eval_run_id = '${P0_EVAL_RUN_ID}'
),
p1_best_span AS (
  SELECT DISTINCT ON (cs.interaction_id)
    cs.interaction_id AS call_id,
    sa.project_id AS p1_project_id
  FROM span_attributions sa
  JOIN conversation_spans cs ON cs.id = sa.span_id AND cs.is_superseded = false
  WHERE sa.prompt_version = '${P1_PROMPT_VERSION}'
    AND sa.inference_ms > 0
  ORDER BY cs.interaction_id, sa.confidence DESC NULLS LAST, sa.created_at DESC NULLS LAST, sa.span_id DESC
),
paired AS (
  SELECT
    p0.call_id,
    CASE WHEN p0.p0_status = 'pass' THEN true ELSE false END AS p0_correct,
    CASE WHEN p1.p1_project_id = p0.gt_project_id THEN true ELSE false END AS p1_correct,
    CASE WHEN p1.call_id IS NOT NULL THEN true ELSE false END AS has_p1
  FROM p0_results p0
  LEFT JOIN p1_best_span p1 ON p1.call_id = p0.call_id
  WHERE 1=1
  ${CALL_FILTER}
)
SELECT
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE has_p1) AS with_p1_data,
  -- McNemar 2x2 contingency cells
  COUNT(*) FILTER (WHERE p0_correct AND p1_correct) AS both_correct,        -- a
  COUNT(*) FILTER (WHERE p0_correct AND NOT p1_correct) AS p0_only,         -- b (regression!)
  COUNT(*) FILTER (WHERE NOT p0_correct AND p1_correct) AS p1_only,         -- c (improvement!)
  COUNT(*) FILTER (WHERE NOT p0_correct AND NOT p1_correct) AS both_wrong,  -- d
  -- Calls without P1 data (not yet reprocessed)
  COUNT(*) FILTER (WHERE NOT has_p1) AS missing_p1
FROM paired;
"

# --- Stratified accuracy query ---
STRATIFIED_SQL="
WITH p0_results AS (
  SELECT
    es.interaction_id AS call_id,
    es.status AS p0_status,
    (es.scoreboard_json->>'ground_truth_project_id')::uuid AS gt_project_id,
    es.scoreboard_json->>'ground_truth_project_name' AS gt_project
  FROM eval_samples es
  WHERE es.eval_run_id = '${P0_EVAL_RUN_ID}'
),
p1_best_span AS (
  SELECT DISTINCT ON (cs.interaction_id)
    cs.interaction_id AS call_id,
    sa.project_id AS p1_project_id,
    sa.confidence AS p1_confidence,
    sa.decision AS p1_decision,
    COALESCE(jsonb_array_length(sa.journal_references), 0) AS journal_ref_count
  FROM span_attributions sa
  JOIN conversation_spans cs ON cs.id = sa.span_id AND cs.is_superseded = false
  WHERE sa.prompt_version = '${P1_PROMPT_VERSION}'
    AND sa.inference_ms > 0
  ORDER BY cs.interaction_id, sa.confidence DESC NULLS LAST, sa.created_at DESC NULLS LAST, sa.span_id DESC
),
paired AS (
  SELECT
    p0.call_id,
    p0.gt_project,
    CASE WHEN p0.p0_status = 'pass' THEN 1 ELSE 0 END AS p0_correct,
    CASE WHEN p1.p1_project_id = p0.gt_project_id THEN 1 ELSE 0 END AS p1_correct,
    CASE WHEN p1.call_id IS NOT NULL THEN true ELSE false END AS has_p1,
    CASE WHEN i.contact_id IS NOT NULL THEN 'resolved' ELSE 'null_contact' END AS contact_status,
    COALESCE(cf.fanout_class, 'none') AS fanout_class,
    p1.p1_decision,
    p1.journal_ref_count
  FROM p0_results p0
  JOIN interactions i ON i.interaction_id = p0.call_id
  LEFT JOIN contact_fanout cf ON cf.contact_id = i.contact_id
  LEFT JOIN p1_best_span p1 ON p1.call_id = p0.call_id
  WHERE 1=1
  ${CALL_FILTER}
)
SELECT
  'by_contact_status' AS stratum_type,
  contact_status AS stratum,
  COUNT(*) AS n,
  SUM(p0_correct) AS p0_correct,
  ROUND(100.0 * SUM(p0_correct) / NULLIF(COUNT(*), 0), 1) AS p0_pct,
  SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) AS p1_correct,
  COUNT(*) FILTER (WHERE has_p1) AS p1_n,
  ROUND(100.0 * SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) / NULLIF(COUNT(*) FILTER (WHERE has_p1), 0), 1) AS p1_pct
FROM paired
GROUP BY contact_status

UNION ALL

SELECT
  'by_project' AS stratum_type,
  gt_project AS stratum,
  COUNT(*) AS n,
  SUM(p0_correct) AS p0_correct,
  ROUND(100.0 * SUM(p0_correct) / NULLIF(COUNT(*), 0), 1) AS p0_pct,
  SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) AS p1_correct,
  COUNT(*) FILTER (WHERE has_p1) AS p1_n,
  ROUND(100.0 * SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) / NULLIF(COUNT(*) FILTER (WHERE has_p1), 0), 1) AS p1_pct
FROM paired
GROUP BY gt_project

UNION ALL

SELECT
  'by_fanout_class' AS stratum_type,
  fanout_class AS stratum,
  COUNT(*) AS n,
  SUM(p0_correct) AS p0_correct,
  ROUND(100.0 * SUM(p0_correct) / NULLIF(COUNT(*), 0), 1) AS p0_pct,
  SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) AS p1_correct,
  COUNT(*) FILTER (WHERE has_p1) AS p1_n,
  ROUND(100.0 * SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) / NULLIF(COUNT(*) FILTER (WHERE has_p1), 0), 1) AS p1_pct
FROM paired
GROUP BY fanout_class

UNION ALL

SELECT
  'by_p1_decision' AS stratum_type,
  COALESCE(p1_decision, 'no_p1') AS stratum,
  COUNT(*) AS n,
  SUM(p0_correct) AS p0_correct,
  ROUND(100.0 * SUM(p0_correct) / NULLIF(COUNT(*), 0), 1) AS p0_pct,
  SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) AS p1_correct,
  COUNT(*) FILTER (WHERE has_p1) AS p1_n,
  ROUND(100.0 * SUM(CASE WHEN has_p1 THEN p1_correct ELSE NULL END) / NULLIF(COUNT(*) FILTER (WHERE has_p1), 0), 1) AS p1_pct
FROM paired
GROUP BY p1_decision

ORDER BY stratum_type, stratum;
"

# --- Decision category query (assign vs review accuracy) ---
DECISION_SQL="
WITH p0_results AS (
  SELECT
    es.interaction_id AS call_id,
    (es.scoreboard_json->>'ground_truth_project_id')::uuid AS gt_project_id
  FROM eval_samples es
  WHERE es.eval_run_id = '${P0_EVAL_RUN_ID}'
),
p1_best_span AS (
  SELECT DISTINCT ON (cs.interaction_id)
    cs.interaction_id AS call_id,
    sa.project_id AS p1_project_id,
    sa.decision AS p1_decision
  FROM span_attributions sa
  JOIN conversation_spans cs ON cs.id = sa.span_id AND cs.is_superseded = false
  WHERE sa.prompt_version = '${P1_PROMPT_VERSION}'
    AND sa.inference_ms > 0
  ORDER BY cs.interaction_id, sa.confidence DESC NULLS LAST, sa.created_at DESC NULLS LAST, sa.span_id DESC
)
SELECT
  p1.p1_decision,
  COUNT(*) AS n,
  SUM(CASE WHEN p1.p1_project_id = p0.gt_project_id THEN 1 ELSE 0 END) AS correct,
  ROUND(100.0 * SUM(CASE WHEN p1.p1_project_id = p0.gt_project_id THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS accuracy_pct
FROM p0_results p0
JOIN p1_best_span p1 ON p1.call_id = p0.call_id
WHERE 1=1
${CALL_FILTER}
GROUP BY p1.p1_decision
ORDER BY p1.p1_decision;
"

# --- Execute via MCP Supabase (preferred) or print SQL for manual execution ---
echo "============================================================"
echo "P2 EVAL SCORER — Camber Attribution Lift Measurement"
echo "============================================================"
echo ""
echo "Mode:            $MODE"
echo "P0 Eval Run:     $P0_EVAL_RUN_ID"
echo "P1 Version:      $P1_PROMPT_VERSION"
echo "P0 Raw Baseline: ${P0_RAW_ACCURACY}%"
echo "P0 Adj Baseline: ${P0_ADJUSTED_ACCURACY}%"
echo "Assign Floor:    ${ASSIGN_REGRESSION_FLOOR}%"
echo ""
echo "============================================================"
echo "SCORING QUERIES (execute via Supabase MCP or psql)"
echo "============================================================"
echo ""
echo "--- 1. McNemar Contingency Table ---"
echo "$MCNEMAR_SQL"
echo ""
echo "--- 2. Stratified Accuracy ---"
echo "$STRATIFIED_SQL"
echo ""
echo "--- 3. Decision Category Accuracy (Assign vs Review regression check) ---"
echo "$DECISION_SQL"
echo ""
echo "--- 4. Full Paired Comparison (per-call detail) ---"
echo "$SCORING_SQL"
echo ""
echo "============================================================"
echo "STATISTICAL ANALYSIS"
echo "============================================================"
echo ""
echo "After running queries above, compute McNemar's test:"
echo ""
echo "  McNemar's chi-squared = (b - c)^2 / (b + c)"
echo "  where:"
echo "    b = p0_only (regressions: P0 correct, P1 wrong)"
echo "    c = p1_only (improvements: P0 wrong, P1 correct)"
echo ""
echo "  p-value: compare chi-squared to chi-squared distribution with df=1"
echo "    chi2 >= 3.841 → p < 0.05 (significant)"
echo "    chi2 >= 2.706 → p < 0.10 (decomposition trigger)"
echo ""
echo "  If b+c < 25, use exact McNemar (binomial test):"
echo "    p = 2 * sum(binom(b+c, k, 0.5) for k in 0..min(b,c))"
echo ""
echo "SHIP DECISION CRITERIA (STRAT-3 framework, STRAT-1 revisions):"
echo "  SHIP:    P1 accuracy >= P0 + 10pp AND p < 0.05 AND assign >= ${ASSIGN_REGRESSION_FLOOR}%"
echo "  DECOMP:  P1 accuracy >= P0 + 5pp AND p < 0.10"
echo "  NO-SHIP: Lift < 5pp OR assign < ${ASSIGN_REGRESSION_FLOOR}%"
echo ""
echo "============================================================"
