#!/usr/bin/env python3
"""
Batch orchestrator for admin-reseed backfills.

Purpose:
- Find interactions that do not currently have active conversation spans
- Call admin-reseed for each interaction with bounded request rate
- Continue on failures and emit retry artifacts
- Print progress every N interactions (default: 50)

Required env vars:
- SUPABASE_URL
- SUPABASE_SERVICE_ROLE_KEY
- EDGE_SHARED_SECRET
- ORIGIN_SESSION
- CLAIM_RECEIPT

Example:
  python3 scripts/admin_reseed_batch_backfill.py \
    --mode resegment_only \
    --max-per-minute 5 \
    --progress-every 50
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


REST_PAGE_SIZE = 1000


@dataclass
class RunStats:
    total_candidates: int = 0
    attempted: int = 0
    succeeded: int = 0
    skipped_locked: int = 0
    failed: int = 0


def _utc_stamp() -> str:
    return datetime.now(tz=UTC).strftime("%Y%m%dT%H%M%SZ")


def _require_env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def _require_claim_env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        raise RuntimeError(f"Missing required claim context env var: {name}")
    if name == "CLAIM_RECEIPT" and not value.startswith("claim__"):
        raise RuntimeError(f"CLAIM_RECEIPT must begin with 'claim__' (got: {value})")
    return value


def _json_request(
    url: str,
    *,
    method: str,
    headers: dict[str, str],
    payload: dict[str, Any] | None = None,
    timeout: int = 60,
) -> tuple[int, Any]:
    body = None
    req_headers = dict(headers)
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        req_headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = int(resp.status)
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        status = int(exc.code)
        raw = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
    except Exception as exc:
        return 0, {"error": f"request_failed: {exc}"}

    try:
        data = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        data = {"raw": raw}
    return status, data


def _fetch_table_ids(
    base_url: str,
    service_key: str,
    table: str,
    *,
    where: str | None = None,
) -> list[str]:
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }
    ids: list[str] = []
    offset = 0

    while True:
        params = {
            "select": "interaction_id",
            "limit": str(REST_PAGE_SIZE),
            "offset": str(offset),
        }
        if table == "interactions":
            params["order"] = "interaction_id.asc"
        if where:
            key, value = where.split("=", 1)
            params[key] = value

        query = urllib.parse.urlencode(params)
        url = f"{base_url}/rest/v1/{table}?{query}"
        status, data = _json_request(url, method="GET", headers=headers, timeout=60)
        if status == 0:
            raise RuntimeError(f"Failed to read {table}: {data.get('error', 'unknown_error')}")
        if status >= 400:
            raise RuntimeError(f"Failed to read {table}: HTTP {status} {data}")
        if not isinstance(data, list):
            break

        batch = [str(row.get("interaction_id")) for row in data if row.get("interaction_id")]
        ids.extend(batch)
        if len(data) < REST_PAGE_SIZE:
            break
        offset += len(data)

    return ids


def _list_unsegmented_interactions(base_url: str, service_key: str) -> list[str]:
    # Exclude interactions explicitly marked as nonsegmentable (e.g. empty/null transcript)
    # to prevent infinite reseed loops.
    try:
        all_interactions = _fetch_table_ids(
            base_url,
            service_key,
            "interactions",
            where="is_nonsegmentable=eq.false",
        )
    except RuntimeError as exc:
        print(
            f"[admin-reseed-batch] WARN: falling back to unfiltered interactions scan "
            f"(is_nonsegmentable column missing?): {exc}",
            file=sys.stderr,
        )
        all_interactions = _fetch_table_ids(base_url, service_key, "interactions")
    active_spans = set(
        _fetch_table_ids(
            base_url,
            service_key,
            "conversation_spans",
            where="is_superseded=eq.false",
        )
    )
    return [iid for iid in all_interactions if iid not in active_spans]


def _call_admin_reseed(
    *,
    base_url: str,
    service_key: str,
    edge_secret: str,
    origin_session: str,
    claim_receipt: str,
    interaction_id: str,
    mode: str,
    reason: str,
    idempotency_prefix: str,
) -> tuple[str, int, dict[str, Any], float]:
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "X-Edge-Secret": edge_secret,
        "X-Source": "admin-reseed",
        "X-Origin-Session": origin_session,
        "X-Claim-Receipt": claim_receipt,
    }
    payload = {
        "interaction_id": interaction_id,
        "reason": reason,
        "idempotency_key": f"{idempotency_prefix}:{interaction_id}",
        "mode": mode,
        "requested_by": origin_session,
        "claim_receipt": claim_receipt,
    }
    url = f"{base_url}/functions/v1/admin-reseed"
    t0 = time.time()
    status, data = _json_request(url, method="POST", headers=headers, payload=payload, timeout=180)
    elapsed = (time.time() - t0) * 1000.0

    if status == 200 and isinstance(data, dict) and data.get("ok") is True:
        return "success", status, data, elapsed

    if status == 409 and isinstance(data, dict) and data.get("error") == "human_lock_present":
        return "skipped_human_lock", status, data, elapsed

    return "failed", status, data if isinstance(data, dict) else {"raw": data}, elapsed


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Batch orchestrator for admin-reseed backfills")
    parser.add_argument(
        "--mode",
        choices=["resegment_only", "resegment_and_reroute"],
        default="resegment_only",
        help="Mode passed to admin-reseed",
    )
    parser.add_argument(
        "--max-per-minute",
        type=float,
        default=5.0,
        help="Max admin-reseed calls per minute (default: 5)",
    )
    parser.add_argument("--progress-every", type=int, default=50, help="Progress interval (default: 50)")
    parser.add_argument("--limit", type=int, default=0, help="Optional cap on number of candidates")
    parser.add_argument("--offset", type=int, default=0, help="Skip first N candidates")
    parser.add_argument("--dry-run", action="store_true", help="List candidates only; do not call admin-reseed")
    parser.add_argument(
        "--reason",
        default="segmentation_backfill_phase2",
        help="Reason string sent to admin-reseed",
    )
    parser.add_argument(
        "--output-dir",
        default="",
        help="Optional output directory. Default: artifacts/reseed_backfill_<timestamp>",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()

    try:
        base_url = _require_env("SUPABASE_URL").rstrip("/")
        service_key = _require_env("SUPABASE_SERVICE_ROLE_KEY")
        edge_secret = _require_env("EDGE_SHARED_SECRET")
        origin_session = _require_claim_env("ORIGIN_SESSION")
        claim_receipt = _require_claim_env("CLAIM_RECEIPT")
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    stamp = _utc_stamp()
    output_dir = Path(args.output_dir) if args.output_dir else Path("artifacts") / f"reseed_backfill_{stamp}"
    output_dir.mkdir(parents=True, exist_ok=True)

    csv_path = output_dir / "results.csv"
    failures_path = output_dir / "failed_interactions.txt"
    summary_path = output_dir / "summary.json"

    print("=== admin-reseed batch orchestrator ===")
    print(f"timestamp: {stamp}")
    print(f"mode: {args.mode}")
    print(f"max_per_minute: {args.max_per_minute}")
    print(f"progress_every: {args.progress_every}")
    print(f"output_dir: {output_dir}")
    print(f"origin_session: {origin_session}")
    print(f"claim_receipt: {claim_receipt}")

    try:
        candidates = _list_unsegmented_interactions(base_url, service_key)
    except Exception as exc:
        print(f"ERROR: failed to list candidates: {exc}", file=sys.stderr)
        return 1

    if args.offset > 0:
        candidates = candidates[args.offset :]
    if args.limit > 0:
        candidates = candidates[: args.limit]

    stats = RunStats(total_candidates=len(candidates))
    print(f"candidates_without_active_spans: {stats.total_candidates}")

    if stats.total_candidates == 0:
        print("Nothing to do.")
        return 0

    if args.dry_run:
        dry_run_file = output_dir / "dry_run_candidates.txt"
        dry_run_file.write_text("\n".join(candidates) + "\n", encoding="utf-8")
        print(f"dry-run complete: wrote candidate list to {dry_run_file}")
        return 0

    min_interval_s = 60.0 / max(args.max_per_minute, 0.01)
    idempotency_prefix = f"backfill:{stamp}"
    failures: list[str] = []

    with csv_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            [
                "index",
                "interaction_id",
                "result",
                "http_status",
                "latency_ms",
                "error",
            ]
        )

        for index, interaction_id in enumerate(candidates, start=1):
            request_t0 = time.time()
            result, http_status, response_data, latency_ms = _call_admin_reseed(
                base_url=base_url,
                service_key=service_key,
                edge_secret=edge_secret,
                origin_session=origin_session,
                claim_receipt=claim_receipt,
                interaction_id=interaction_id,
                mode=args.mode,
                reason=args.reason,
                idempotency_prefix=idempotency_prefix,
            )

            stats.attempted += 1
            error_text = ""
            if result == "success":
                stats.succeeded += 1
            elif result == "skipped_human_lock":
                stats.skipped_locked += 1
                error_text = "human_lock_present"
            else:
                stats.failed += 1
                failures.append(interaction_id)
                error_text = json.dumps(response_data, separators=(",", ":"), ensure_ascii=True)[:400]

            writer.writerow(
                [
                    index,
                    interaction_id,
                    result,
                    http_status,
                    round(latency_ms, 1),
                    error_text,
                ]
            )
            csv_file.flush()

            if index % max(args.progress_every, 1) == 0 or index == stats.total_candidates:
                print(
                    "progress "
                    f"{index}/{stats.total_candidates} | "
                    f"ok={stats.succeeded} "
                    f"locked={stats.skipped_locked} "
                    f"failed={stats.failed}"
                )

            elapsed_s = time.time() - request_t0
            sleep_s = min_interval_s - elapsed_s
            if sleep_s > 0:
                time.sleep(sleep_s)

    failures_path.write_text("\n".join(failures) + ("\n" if failures else ""), encoding="utf-8")

    summary = {
        "timestamp_utc": stamp,
        "mode": args.mode,
        "max_per_minute": args.max_per_minute,
        "progress_every": args.progress_every,
        "origin_session": origin_session,
        "claim_receipt": claim_receipt,
        "total_candidates": stats.total_candidates,
        "attempted": stats.attempted,
        "succeeded": stats.succeeded,
        "skipped_human_lock": stats.skipped_locked,
        "failed": stats.failed,
        "results_csv": str(csv_path),
        "failed_ids_file": str(failures_path),
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print("=== complete ===")
    print(json.dumps(summary, indent=2))
    if stats.failed > 0:
        print(
            "retry guidance: rerun with --offset/--limit and failed_interactions list from "
            f"{failures_path}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
