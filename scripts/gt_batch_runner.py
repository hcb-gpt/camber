#!/usr/bin/env python3
"""
GT Regression Batch Runner v1

Produces deterministic batch artifacts under:
  /Users/chadbarlow/Desktop/gt_batch_runs/<timestamp>/

Input format (gt_batch_v1.csv or gt_batch_v1.json):
- interaction_id (required)
- span_index (optional)
- span_id (optional)
- expected_project_id (optional)
- expected_project_name_contains (optional)
- expected_decision (optional: assign|review|none)
- notes (optional)
- tags (optional)
- row_id (optional)
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
DECISION_ALLOWED = {"assign", "review", "none", ""}

INPUT_FIELDS = [
    "row_id",
    "interaction_id",
    "span_index",
    "span_id",
    "expected_project_id",
    "expected_project_name_contains",
    "expected_decision",
    "notes",
    "tags",
]

RESULT_FIELDS = [
    "row_id",
    "interaction_id",
    "run_interaction_id",
    "span_selector",
    "resolved_span_id",
    "resolved_span_index",
    "expected_project_id",
    "expected_project_name_contains",
    "expected_decision",
    "actual_project_id",
    "actual_project_name",
    "actual_decision",
    "actual_confidence",
    "actual_prompt_version",
    "actual_model_id",
    "actual_reason_codes",
    "actual_reasoning",
    "char_start",
    "char_end",
    "has_expectation",
    "is_correct",
    "error",
    "notes",
    "tags",
]

TRIGGER_FIELDS = [
    "interaction_id",
    "run_interaction_id",
    "mode",
    "ok",
    "http_status",
    "error",
    "idempotency_key",
    "shadow_id",
    "response_file",
]


def utc_stamp() -> str:
    return dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def ensure_env(var: str) -> str:
    val = os.environ.get(var, "").strip()
    if not val:
        raise RuntimeError(f"missing required env var: {var}")
    return val


def sql_quote(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def run_psql_sql(database_url: str, psql_bin: str, sql: str) -> str:
    cmd = [
        psql_bin,
        database_url,
        "-X",
        "-v",
        "ON_ERROR_STOP=1",
        "-A",
        "-t",
        "-F",
        "\t",
        "-c",
        sql,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "psql failed")
    return proc.stdout.strip()


def post_json(url: str, payload: dict, headers: dict, timeout: int) -> Tuple[int, object]:
    payload_json = json.dumps(payload)
    cmd = [
        "curl",
        "-sS",
        "-X",
        "POST",
        "-w",
        "\n__HTTP_STATUS__:%{http_code}\n",
        "--max-time",
        str(timeout),
        url,
    ]
    for key, value in headers.items():
        cmd.extend(["-H", f"{key}: {value}"])
    cmd.extend(["--data", payload_json])

    proc = subprocess.run(cmd, capture_output=True, text=True)
    stdout = proc.stdout or ""
    stderr = (proc.stderr or "").strip()

    marker = "__HTTP_STATUS__:"
    status = 0
    body = stdout
    if marker in stdout:
        body, _, tail = stdout.rpartition(marker)
        status_str = tail.strip().splitlines()[0] if tail.strip() else "0"
        try:
            status = int(status_str)
        except ValueError:
            status = 0
        body = body.rstrip("\n")

    if not body and stderr:
        return status, {"error": stderr}

    try:
        parsed = json.loads(body) if body else {}
    except json.JSONDecodeError:
        parsed = {"raw": body}

    if proc.returncode != 0 and status == 0 and not isinstance(parsed, dict):
        return 0, {"error": stderr or "curl_failed"}
    if proc.returncode != 0 and status == 0 and isinstance(parsed, dict) and "error" not in parsed:
        parsed["error"] = stderr or "curl_failed"

    return status, parsed


def normalize_field(value: object) -> str:
    if value is None:
        return ""
    return str(value).strip()


def load_rows(input_path: Path) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    suffix = input_path.suffix.lower()

    if suffix == ".json":
        payload = json.loads(input_path.read_text(encoding="utf-8"))
        if isinstance(payload, dict) and isinstance(payload.get("rows"), list):
            payload = payload["rows"]
        if not isinstance(payload, list):
            raise RuntimeError("json input must be an array or {\"rows\": [...]}")
        for idx, raw in enumerate(payload, start=1):
            if not isinstance(raw, dict):
                raise RuntimeError(f"json row {idx} is not an object")
            row = {k: normalize_field(raw.get(k, "")) for k in INPUT_FIELDS}
            if not row["row_id"]:
                row["row_id"] = f"row_{idx:04d}"
            rows.append(row)
    elif suffix == ".csv":
        with input_path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            if reader.fieldnames is None:
                raise RuntimeError("csv input is missing header")
            normalized_headers = {h.strip() for h in reader.fieldnames if h}
            if "interaction_id" not in normalized_headers:
                raise RuntimeError("csv input must include interaction_id header")
            for idx, raw in enumerate(reader, start=1):
                row = {k: normalize_field(raw.get(k, "")) for k in INPUT_FIELDS}
                if not row["row_id"]:
                    row["row_id"] = f"row_{idx:04d}"
                rows.append(row)
    else:
        raise RuntimeError("input must be .csv or .json")

    if not rows:
        raise RuntimeError("input has no rows")

    for idx, row in enumerate(rows, start=1):
        iid = row["interaction_id"]
        if not iid or not ID_RE.match(iid):
            raise RuntimeError(f"row {idx}: invalid interaction_id '{iid}'")
        if row["span_index"]:
            try:
                int(row["span_index"])
            except ValueError as exc:
                raise RuntimeError(f"row {idx}: invalid span_index '{row['span_index']}'") from exc
        if row["span_id"] and not ID_RE.match(row["span_id"]):
            raise RuntimeError(f"row {idx}: invalid span_id '{row['span_id']}'")

        decision = row["expected_decision"].lower()
        if decision not in DECISION_ALLOWED:
            raise RuntimeError(
                f"row {idx}: expected_decision must be one of assign|review|none (got '{row['expected_decision']}')"
            )
        row["expected_decision"] = decision

    return rows


def selector_for_row(row: Dict[str, str]) -> Tuple[str, str]:
    if row["span_id"]:
        return "span_id", row["span_id"]
    if row["span_index"]:
        return "span_index", row["span_index"]
    return "span_index", "0"


def query_row_actual(
    database_url: str,
    psql_bin: str,
    run_interaction_id: str,
    row: Dict[str, str],
) -> Dict[str, str]:
    selector_type, selector_value = selector_for_row(row)

    if selector_type == "span_id":
        span_filter = f"cs.id = {sql_quote(selector_value)}"
    else:
        span_filter = f"cs.span_index = {int(selector_value)}"

    sql = f"""
with target_span as (
  select cs.id, cs.span_index, cs.char_start, cs.char_end
  from conversation_spans cs
  where cs.interaction_id = {sql_quote(run_interaction_id)}
    and cs.is_superseded = false
    and {span_filter}
  order by cs.created_at desc nulls last, cs.id desc
  limit 1
),
latest_attr as (
  select
    sa.*,
    row_number() over (
      partition by sa.span_id
      order by coalesce(sa.attributed_at, sa.applied_at_utc) desc nulls last, sa.id desc
    ) as rn
  from span_attributions sa
  join target_span ts on ts.id = sa.span_id
),
latest_review as (
  select rq.span_id, rq.reason_codes::text as reason_codes
  from review_queue rq
  join target_span ts on ts.id = rq.span_id
  order by rq.created_at desc nulls last, rq.id desc
  limit 1
)
select
  coalesce(ts.id::text,''),
  coalesce(ts.span_index::text,''),
  coalesce(ts.char_start::text,''),
  coalesce(ts.char_end::text,''),
  coalesce(la.project_id::text,''),
  coalesce(p.name,''),
  coalesce(la.decision,''),
  coalesce(la.confidence::text,''),
  coalesce(la.prompt_version,''),
  coalesce(la.model_id,''),
  coalesce(lr.reason_codes,''),
  coalesce(la.reasoning,'')
from target_span ts
left join latest_attr la on la.rn = 1
left join projects p on p.id = la.project_id
left join latest_review lr on lr.span_id = ts.id;
""".strip()

    out = run_psql_sql(database_url, psql_bin, sql)
    if not out:
        return {
            "resolved_span_id": "",
            "resolved_span_index": "",
            "char_start": "",
            "char_end": "",
            "actual_project_id": "",
            "actual_project_name": "",
            "actual_decision": "",
            "actual_confidence": "",
            "actual_prompt_version": "",
            "actual_model_id": "",
            "actual_reason_codes": "",
            "actual_reasoning": "",
            "error": "span_not_found",
        }

    cols = out.split("\t")
    while len(cols) < 12:
        cols.append("")

    return {
        "resolved_span_id": cols[0],
        "resolved_span_index": cols[1],
        "char_start": cols[2],
        "char_end": cols[3],
        "actual_project_id": cols[4],
        "actual_project_name": cols[5],
        "actual_decision": cols[6].lower(),
        "actual_confidence": cols[7],
        "actual_prompt_version": cols[8],
        "actual_model_id": cols[9],
        "actual_reason_codes": cols[10],
        "actual_reasoning": cols[11],
        "error": "",
    }


def bool_to_str(val: bool) -> str:
    return "true" if val else "false"


def compute_correctness(row: Dict[str, str], actual: Dict[str, str]) -> Tuple[bool, bool]:
    has_expectation = any(
        [
            row["expected_project_id"] != "",
            row["expected_project_name_contains"] != "",
            row["expected_decision"] != "",
        ]
    )
    if not has_expectation:
        return False, True

    if actual.get("error"):
        return True, False

    expected_decision = row["expected_decision"].lower().strip()
    expected_project_id = row["expected_project_id"].strip()
    expected_project_name_contains = row["expected_project_name_contains"].strip().lower()

    actual_decision = actual.get("actual_decision", "").lower().strip()
    actual_project_id = actual.get("actual_project_id", "").strip()
    actual_project_name = actual.get("actual_project_name", "").lower().strip()

    ok = True
    if expected_decision and actual_decision != expected_decision:
        ok = False
    if expected_project_id and actual_project_id != expected_project_id:
        ok = False
    if expected_project_name_contains and expected_project_name_contains not in actual_project_name:
        ok = False

    return True, ok


def write_csv(path: Path, fieldnames: List[str], rows: List[Dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fieldnames})


def parse_metric_bool(value: str) -> bool:
    return value.strip().lower() == "true"


def get_float(value: Optional[float], places: int = 4) -> Optional[float]:
    if value is None:
        return None
    return round(value, places)


def compute_ratio(num: int, den: int) -> Optional[float]:
    if den == 0:
        return None
    return num / den


def maybe_load_baseline_metrics(baseline_arg: str, out_root: Path, current_run_dir: Path) -> Optional[Tuple[Path, dict]]:
    if baseline_arg:
        p = Path(baseline_arg)
        if p.is_dir():
            p = p / "metrics.json"
        if not p.exists():
            raise RuntimeError(f"baseline not found: {p}")
        return p, json.loads(p.read_text(encoding="utf-8"))

    candidates = []
    if out_root.exists():
        for child in out_root.iterdir():
            if child.is_dir() and child != current_run_dir and (child / "metrics.json").exists():
                candidates.append(child)
    if not candidates:
        return None

    candidates.sort(key=lambda c: c.name)
    chosen = candidates[-1]
    metrics_path = chosen / "metrics.json"
    return metrics_path, json.loads(metrics_path.read_text(encoding="utf-8"))


def preserve_baseline_artifacts(baseline_metrics_path: Path, run_dir: Path) -> Optional[Path]:
    source = baseline_metrics_path.expanduser().resolve()
    if not source.exists():
        return None

    preserve_root = run_dir / "baseline_preserved"
    preserve_root.mkdir(parents=True, exist_ok=True)

    # Preserve the full baseline run directory when diffing against metrics.json.
    if source.is_file() and source.name == "metrics.json":
        source_dir = source.parent
        target_dir = preserve_root / source_dir.name
        if target_dir.exists():
            shutil.rmtree(target_dir)
        shutil.copytree(source_dir, target_dir)
        target_metrics = target_dir / "metrics.json"
        return target_metrics if target_metrics.exists() else target_dir

    target_file = preserve_root / source.name
    shutil.copy2(source, target_file)
    return target_file


def run_preflight(database_url: str, psql_bin: str, supabase_url: str, headers: dict, first_interaction_id: str, run_id: str, timeout: int) -> bool:
    """Run preflight checks: DB connectivity + edge function reachability."""
    print("PREFLIGHT: checking DB connectivity...")
    try:
        run_psql_sql(database_url, psql_bin, "SELECT 1")
        print("  DB: OK")
    except Exception as e:
        print(f"  DB: FAILED ({e})")
        return False

    print("PREFLIGHT: checking edge function reachability...")
    idem_key = f"preflight-{run_id}"
    payload = {
        "interaction_id": first_interaction_id,
        "mode": "resegment_and_reroute",
        "idempotency_key": idem_key,
        "reason": "preflight_check",
        "requested_by": "gt_batch_runner_preflight",
        "force": False,
        "dry_run": True,
    }
    url = f"{supabase_url}/functions/v1/admin-reseed"
    status, resp = post_json(url, payload, headers, timeout=timeout)
    if status > 0:
        print(f"  Edge function: OK (HTTP {status})")
        return True
    else:
        print(f"  Edge function: FAILED (no HTTP response)")
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="GT regression batch runner v1")
    parser.add_argument("--input", required=True, help="path to gt_batch_v1 csv/json")
    parser.add_argument("--mode", choices=["shadow", "reseed", "none"], default="shadow")
    parser.add_argument(
        "--reseed-mode",
        choices=["resegment_and_reroute", "reseed_and_close_loop"],
        default="resegment_and_reroute",
    )
    parser.add_argument("--out-root", default="/Users/chadbarlow/Desktop/gt_batch_runs")
    parser.add_argument("--wait-seconds", type=int, default=6)
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--baseline", default="", help="optional prior run dir or metrics.json for diff")
    parser.add_argument("--force", action="store_true", help="pass force=true to admin-reseed (cascade delete before re-segment)")
    parser.add_argument("--preflight-only", action="store_true", help="run preflight checks then exit (no batch)")
    parser.add_argument("--rate-limit", type=int, default=0, help="max requests per minute (0=unlimited)")
    parser.add_argument("--max-consecutive-failures", type=int, default=3, help="abort after N consecutive trigger failures")
    parser.add_argument("--max-failure-pct", type=int, default=50, help="abort if failure %% exceeds N (checked after 5+ attempts)")
    args = parser.parse_args()

    supabase_url = ensure_env("SUPABASE_URL")
    service_role = ensure_env("SUPABASE_SERVICE_ROLE_KEY")
    edge_secret = ensure_env("EDGE_SHARED_SECRET")
    database_url = ensure_env("DATABASE_URL")
    psql_bin = os.environ.get("PSQL_PATH", "psql")

    input_path = Path(args.input).expanduser().resolve()
    if not input_path.exists():
        raise RuntimeError(f"input file not found: {input_path}")

    baseline_arg = args.baseline.strip()
    if baseline_arg:
        baseline_probe = Path(baseline_arg).expanduser()
        if baseline_probe.is_dir():
            baseline_probe = baseline_probe / "metrics.json"
        if not baseline_probe.exists():
            raise RuntimeError(f"baseline not found: {baseline_probe}")

    rows = load_rows(input_path)

    run_id = utc_stamp()
    out_root = Path(args.out_root).expanduser()
    run_dir = out_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    trigger_dir = run_dir / "trigger_responses"
    trigger_dir.mkdir(parents=True, exist_ok=True)

    (run_dir / "input_normalized.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    write_csv(run_dir / "input_normalized.csv", INPUT_FIELDS, rows)

    unique_interactions = sorted({r["interaction_id"] for r in rows})

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {service_role}",
        "apikey": service_role,
        "X-Edge-Secret": edge_secret,
        "X-Source": "admin-reseed",
    }

    # --- Preflight checks ---
    if unique_interactions:
        preflight_ok = run_preflight(
            database_url=database_url,
            psql_bin=psql_bin,
            supabase_url=supabase_url,
            headers=headers,
            first_interaction_id=unique_interactions[0],
            run_id=run_id,
            timeout=args.timeout_seconds,
        )
        if not preflight_ok:
            print("PREFLIGHT_FAILED")
            return 1
        if args.preflight_only:
            print("PREFLIGHT_OK")
            return 0
        print("PREFLIGHT_OK — proceeding with batch")

    trigger_rows: List[Dict[str, str]] = []
    interaction_map: Dict[str, str] = {}
    consecutive_failures = 0
    total_trigger_attempted = 0
    total_trigger_failed = 0
    abort_reason = ""
    abort_at_index = 0

    for idx, interaction_id in enumerate(unique_interactions, start=1):
        request_t0 = time.time()

        if args.mode == "none":
            interaction_map[interaction_id] = interaction_id
            trigger_rows.append(
                {
                    "interaction_id": interaction_id,
                    "run_interaction_id": interaction_id,
                    "mode": args.mode,
                    "ok": "true",
                    "http_status": "",
                    "error": "",
                    "idempotency_key": "",
                    "shadow_id": "",
                    "response_file": "",
                }
            )
            continue

        if args.mode == "shadow":
            shadow_id = f"cll_SHADOW_GTBATCH_{run_id}_{idx:03d}"
            payload = {
                "interaction_id": interaction_id,
                "shadow_id": shadow_id,
                "dry_run": False,
            }
            url = f"{supabase_url}/functions/v1/shadow-replay"
            idem_key = ""
        else:
            shadow_id = ""
            idem_key = f"gt-batch-{run_id}-{idx:03d}-{interaction_id}"
            payload = {
                "interaction_id": interaction_id,
                "mode": args.reseed_mode,
                "idempotency_key": idem_key,
                "reason": "gt_batch_runner_v1",
                "requested_by": "dev-1",
                "force": args.force,
            }
            url = f"{supabase_url}/functions/v1/admin-reseed"

        status, resp = post_json(url, payload, headers, timeout=args.timeout_seconds)
        # Retry once on 504 Gateway Timeout with 10s backoff
        if status == 504:
            print(f"  [{idx}/{len(unique_interactions)}] {interaction_id}: 504 timeout, retrying in 10s...")
            time.sleep(10)
            status, resp = post_json(url, payload, headers, timeout=args.timeout_seconds)
        response_file = trigger_dir / f"{interaction_id}.json"
        response_file.write_text(json.dumps({"http_status": status, "response": resp}, indent=2), encoding="utf-8")

        ok = status == 200 and isinstance(resp, dict) and bool(resp.get("ok", False))

        run_interaction_id = interaction_id
        error = ""
        if args.mode == "shadow":
            if ok:
                run_interaction_id = str(resp.get("shadow_id", "")).strip() or shadow_id
            else:
                run_interaction_id = ""
                error = str(resp.get("error") if isinstance(resp, dict) else "shadow_replay_failed")
        elif args.mode == "reseed":
            if not ok:
                error = str(resp.get("error") if isinstance(resp, dict) else "admin_reseed_failed")

        interaction_map[interaction_id] = run_interaction_id

        trigger_rows.append(
            {
                "interaction_id": interaction_id,
                "run_interaction_id": run_interaction_id,
                "mode": args.mode,
                "ok": bool_to_str(ok),
                "http_status": str(status),
                "error": error,
                "idempotency_key": idem_key,
                "shadow_id": shadow_id,
                "response_file": str(response_file),
            }
        )

        # --- Failure tracking / cost fuse ---
        total_trigger_attempted += 1
        if not ok:
            consecutive_failures += 1
            total_trigger_failed += 1
            if consecutive_failures >= args.max_consecutive_failures:
                abort_reason = f"consecutive_failures={consecutive_failures}"
                abort_at_index = idx
                print(f"ABORT: {abort_reason} at index {idx}")
                break
            if total_trigger_attempted >= 5:
                fail_pct = (total_trigger_failed / total_trigger_attempted) * 100
                if fail_pct >= args.max_failure_pct:
                    abort_reason = f"failure_pct={fail_pct:.1f}%"
                    abort_at_index = idx
                    print(f"ABORT: {abort_reason} at index {idx}")
                    break
        else:
            consecutive_failures = 0

        # --- Rate limiting ---
        if args.rate_limit > 0:
            min_interval_s = 60.0 / args.rate_limit
            elapsed = time.time() - request_t0
            if elapsed < min_interval_s:
                time.sleep(min_interval_s - elapsed)

    write_csv(run_dir / "trigger_results.csv", TRIGGER_FIELDS, trigger_rows)

    if args.mode in {"shadow", "reseed"} and args.wait_seconds > 0:
        time.sleep(args.wait_seconds)

    results: List[Dict[str, str]] = []
    failures: List[Dict[str, str]] = []

    for row in rows:
        run_interaction_id = interaction_map.get(row["interaction_id"], "")
        selector_type, selector_value = selector_for_row(row)

        actual = {
            "resolved_span_id": "",
            "resolved_span_index": "",
            "char_start": "",
            "char_end": "",
            "actual_project_id": "",
            "actual_project_name": "",
            "actual_decision": "",
            "actual_confidence": "",
            "actual_prompt_version": "",
            "actual_model_id": "",
            "actual_reason_codes": "",
            "actual_reasoning": "",
            "error": "",
        }

        trigger_ok = interaction_map.get(row["interaction_id"], "") != ""
        if not trigger_ok:
            actual["error"] = "trigger_failed"
        else:
            try:
                actual = query_row_actual(database_url, psql_bin, run_interaction_id, row)
            except Exception as e:  # noqa: BLE001
                actual["error"] = f"query_failed:{e}"

        has_expectation, is_correct = compute_correctness(row, actual)

        result = {
            "row_id": row["row_id"],
            "interaction_id": row["interaction_id"],
            "run_interaction_id": run_interaction_id,
            "span_selector": f"{selector_type}:{selector_value}",
            "resolved_span_id": actual["resolved_span_id"],
            "resolved_span_index": actual["resolved_span_index"],
            "expected_project_id": row["expected_project_id"],
            "expected_project_name_contains": row["expected_project_name_contains"],
            "expected_decision": row["expected_decision"],
            "actual_project_id": actual["actual_project_id"],
            "actual_project_name": actual["actual_project_name"],
            "actual_decision": actual["actual_decision"],
            "actual_confidence": actual["actual_confidence"],
            "actual_prompt_version": actual["actual_prompt_version"],
            "actual_model_id": actual["actual_model_id"],
            "actual_reason_codes": actual["actual_reason_codes"],
            "actual_reasoning": actual["actual_reasoning"],
            "char_start": actual["char_start"],
            "char_end": actual["char_end"],
            "has_expectation": bool_to_str(has_expectation),
            "is_correct": bool_to_str(is_correct),
            "error": actual["error"],
            "notes": row["notes"],
            "tags": row["tags"],
        }
        results.append(result)

        if parse_metric_bool(result["has_expectation"]) and not parse_metric_bool(result["is_correct"]):
            failures.append(result)

    write_csv(run_dir / "results.csv", RESULT_FIELDS, results)
    write_csv(run_dir / "failures.csv", RESULT_FIELDS, failures)

    total_rows = len(results)
    expected_rows = sum(1 for r in results if parse_metric_bool(r["has_expectation"]))
    correct_rows = sum(
        1
        for r in results
        if parse_metric_bool(r["has_expectation"]) and parse_metric_bool(r["is_correct"])
    )
    reviewed_rows = sum(1 for r in results if r["actual_decision"] == "review")
    decision_rows = sum(1 for r in results if r["actual_decision"] != "")

    homeowner_fail_count = 0
    staff_leak_count = 0
    multi_project_span_count = 0

    for r in results:
        tags_notes = f"{r['tags']} {r['notes']}".lower()
        if "sittler" in r["actual_project_name"].lower():
            staff_leak_count += 1

        reason_blob = f"{r['actual_reason_codes']} {r['actual_reasoning']}".lower()
        if (
            "multi_project" in reason_blob
            or "multi-project" in reason_blob
            or "needs_resegment" in reason_blob
            or "needs_resegmentation" in reason_blob
            or "mixed span" in reason_blob
        ):
            multi_project_span_count += 1

        homeowner_tagged = "homeowner" in tags_notes
        if homeowner_tagged:
            bad = False
            if r["actual_decision"] != "assign":
                bad = True
            elif r["expected_project_id"] and r["actual_project_id"] != r["expected_project_id"]:
                bad = True
            elif r["expected_project_name_contains"] and r["expected_project_name_contains"].lower() not in r[
                "actual_project_name"
            ].lower():
                bad = True
            if bad:
                homeowner_fail_count += 1

    run_interactions = sorted({r["run_interaction_id"] for r in results if r["run_interaction_id"]})
    missing_char_offsets_count = 0
    if run_interactions:
        in_list = ",".join(sql_quote(iid) for iid in run_interactions)
        sql_missing = f"""
select count(*)::int
from conversation_spans
where interaction_id in ({in_list})
  and is_superseded = false
  and (char_start is null or char_end is null);
""".strip()
        try:
            out = run_psql_sql(database_url, psql_bin, sql_missing)
            missing_char_offsets_count = int(out or "0")
        except Exception:
            missing_char_offsets_count = -1

    trigger_fail_count = sum(1 for t in trigger_rows if t["ok"] != "true")

    accuracy = compute_ratio(correct_rows, expected_rows)
    review_rate = compute_ratio(reviewed_rows, decision_rows)

    metrics = {
        "run_id": run_id,
        "run_dir": str(run_dir),
        "mode": args.mode,
        "reseed_mode": args.reseed_mode if args.mode == "reseed" else "",
        "input_file": str(input_path),
        "total_rows": total_rows,
        "expected_rows": expected_rows,
        "correct_rows": correct_rows,
        "accuracy": get_float(accuracy),
        "review_rate": get_float(review_rate),
        "homeowner_override_fail_count": homeowner_fail_count,
        "staff_leak_count": staff_leak_count,
        "multi_project_span_count": multi_project_span_count,
        "missing_char_offsets_count": missing_char_offsets_count,
        "trigger_fail_count": trigger_fail_count,
        "failures_count": len(failures),
        "abort_reason": abort_reason,
        "abort_at_index": abort_at_index,
        "generated_at_utc": dt.datetime.utcnow().isoformat() + "Z",
    }

    (run_dir / "metrics.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")

    baseline = maybe_load_baseline_metrics(baseline_arg, out_root, run_dir)
    diff_obj = None
    if baseline:
        baseline_path, baseline_metrics = baseline
        preserved_baseline_path = preserve_baseline_artifacts(baseline_path, run_dir)
        baseline_path_for_diff = preserved_baseline_path or baseline_path
        diff_obj = {
            "baseline_metrics": str(baseline_path_for_diff),
            "baseline_metrics_source": str(baseline_path),
            "baseline_metrics_preserved": str(preserved_baseline_path) if preserved_baseline_path else None,
            "delta_accuracy": None,
            "delta_review_rate": None,
            "delta_staff_leak_count": None,
            "delta_homeowner_override_fail_count": None,
            "delta_multi_project_span_count": None,
            "delta_missing_char_offsets_count": None,
        }

        def delta_float(cur_key: str, base_key: str) -> Optional[float]:
            cur = metrics.get(cur_key)
            base = baseline_metrics.get(base_key)
            if cur is None or base is None:
                return None
            return get_float(float(cur) - float(base), places=4)

        def delta_int(cur_key: str, base_key: str) -> Optional[int]:
            cur = metrics.get(cur_key)
            base = baseline_metrics.get(base_key)
            if cur is None or base is None:
                return None
            return int(cur) - int(base)

        diff_obj["delta_accuracy"] = delta_float("accuracy", "accuracy")
        diff_obj["delta_review_rate"] = delta_float("review_rate", "review_rate")
        diff_obj["delta_staff_leak_count"] = delta_int("staff_leak_count", "staff_leak_count")
        diff_obj["delta_homeowner_override_fail_count"] = delta_int(
            "homeowner_override_fail_count", "homeowner_override_fail_count"
        )
        diff_obj["delta_multi_project_span_count"] = delta_int(
            "multi_project_span_count", "multi_project_span_count"
        )
        diff_obj["delta_missing_char_offsets_count"] = delta_int(
            "missing_char_offsets_count", "missing_char_offsets_count"
        )
        (run_dir / "diff.json").write_text(json.dumps(diff_obj, indent=2), encoding="utf-8")

    lines = []
    lines.append("# GT Batch Runner Report (v1)")
    lines.append("")
    lines.append(f"- Run ID: `{run_id}`")
    lines.append(f"- Mode: `{args.mode}`")
    if args.mode == "reseed":
        lines.append(f"- Reseed mode: `{args.reseed_mode}`")
    lines.append(f"- Input: `{input_path}`")
    lines.append(f"- Output dir: `{run_dir}`")
    lines.append("")
    lines.append("## Metrics")
    lines.append(f"- accuracy: `{metrics['accuracy']}` ({correct_rows}/{expected_rows})")
    lines.append(f"- review_rate: `{metrics['review_rate']}` ({reviewed_rows}/{decision_rows})")
    lines.append(f"- homeowner_override_fail_count: `{homeowner_fail_count}`")
    lines.append(f"- staff_leak_count: `{staff_leak_count}`")
    lines.append(f"- multi_project_span_count: `{multi_project_span_count}`")
    lines.append(f"- missing_char_offsets_count: `{missing_char_offsets_count}`")
    lines.append(f"- trigger_fail_count: `{trigger_fail_count}`")
    lines.append(f"- failures_count: `{len(failures)}`")
    lines.append("")

    if diff_obj:
        lines.append("## Diff vs Baseline")
        lines.append(f"- baseline_metrics: `{diff_obj['baseline_metrics']}`")
        lines.append(f"- baseline_metrics_source: `{diff_obj['baseline_metrics_source']}`")
        if diff_obj["baseline_metrics_preserved"]:
            lines.append(f"- baseline_metrics_preserved: `{diff_obj['baseline_metrics_preserved']}`")
        lines.append(f"- delta_accuracy: `{diff_obj['delta_accuracy']}`")
        lines.append(f"- delta_review_rate: `{diff_obj['delta_review_rate']}`")
        lines.append(f"- delta_staff_leak_count: `{diff_obj['delta_staff_leak_count']}`")
        lines.append(
            f"- delta_homeowner_override_fail_count: `{diff_obj['delta_homeowner_override_fail_count']}`"
        )
        lines.append(f"- delta_multi_project_span_count: `{diff_obj['delta_multi_project_span_count']}`")
        lines.append(f"- delta_missing_char_offsets_count: `{diff_obj['delta_missing_char_offsets_count']}`")
        lines.append("")

    lines.append("## Artifacts")
    lines.append(f"- `{run_dir / 'summary.md'}`")
    lines.append(f"- `{run_dir / 'metrics.json'}`")
    lines.append(f"- `{run_dir / 'results.csv'}`")
    lines.append(f"- `{run_dir / 'failures.csv'}`")
    lines.append(f"- `{run_dir / 'trigger_results.csv'}`")
    if diff_obj:
        lines.append(f"- `{run_dir / 'diff.json'}`")
    lines.append("")
    lines.append("## Repro")
    lines.append("```bash")
    lines.append(
        f"python3 scripts/gt_batch_runner.py --input {input_path} --mode {args.mode} --out-root {out_root}"
    )
    lines.append("```")

    (run_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"GT_BATCH_RUN_READY {run_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
