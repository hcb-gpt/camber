#!/usr/bin/env python3
"""
Run forensic checks for journal_runs -> journal_claims run_id propagation mismatches.

Usage:
  scripts/journal_runid_mismatch_forensics.py
  scripts/journal_runid_mismatch_forensics.py --out .temp/journal_runid_mismatch.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from datetime import datetime, timezone

import psycopg


def load_env(repo_root: str) -> None:
    loader = os.path.join(repo_root, "scripts", "load-env.sh")
    if not os.path.exists(loader):
        return
    proc = subprocess.run(
        ["bash", "-lc", f"source {loader} >/dev/null 2>&1; env"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.startswith("SUPABASE_") or k in {"DATABASE_URL", "EDGE_SHARED_SECRET"}:
            os.environ[k] = v


def run_forensics(conn: psycopg.Connection, limit: int) -> dict:
    summary_sql = """
    with runs as (
      select
        run_id,
        call_id,
        project_id,
        started_at,
        completed_at,
        claims_extracted,
        config->>'mode' as run_mode,
        nullif(config->>'source_run_id','')::uuid as source_run_id
      from public.journal_runs
      where coalesce(claims_extracted, 0) > 0
    ),
    claim_counts as (
      select run_id, count(*)::int as claim_rows
      from public.journal_claims
      group by run_id
    ),
    source_claim_counts as (
      select run_id, count(*)::int as source_claim_rows
      from public.journal_claims
      group by run_id
    ),
    joined as (
      select
        r.*,
        coalesce(c.claim_rows, 0) as claim_rows,
        coalesce(sc.source_claim_rows, 0) as source_claim_rows,
        case
          when r.run_mode = 'consolidate' then
            case
              when r.source_run_id is null then 'consolidate_no_source_run'
              when coalesce(sc.source_claim_rows, 0) > 0 then 'consolidate_source_has_claims'
              else 'consolidate_source_missing_claims'
            end
          else
            case
              when coalesce(c.claim_rows, 0) = 0 then 'direct_run_missing_claims'
              else 'direct_run_has_claims'
            end
        end as mismatch_class
      from runs r
      left join claim_counts c on c.run_id = r.run_id
      left join source_claim_counts sc on sc.run_id = r.source_run_id
    )
    select
      count(*) filter (
        where started_at >= now() - interval '24 hours'
          and mismatch_class in ('direct_run_missing_claims', 'consolidate_source_missing_claims')
      ) as true_mismatches_24h,
      count(*) filter (
        where started_at >= now() - interval '7 days'
          and mismatch_class in ('direct_run_missing_claims', 'consolidate_source_missing_claims')
      ) as true_mismatches_7d,
      count(*) filter (
        where mismatch_class in ('direct_run_missing_claims', 'consolidate_source_missing_claims')
      ) as true_mismatches_all,
      count(*) filter (where started_at >= now() - interval '24 hours' and mismatch_class = 'consolidate_no_source_run')
        as ambiguous_consolidate_24h,
      count(*) filter (where started_at >= now() - interval '7 days' and mismatch_class = 'consolidate_no_source_run')
        as ambiguous_consolidate_7d,
      count(*) filter (where started_at >= now() - interval '24 hours') as runs_24h_with_claims_extracted,
      count(*) filter (where started_at >= now() - interval '7 days') as runs_7d_with_claims_extracted,
      count(*) filter (where run_mode = 'consolidate') as consolidate_runs,
      count(*) filter (where run_mode is distinct from 'consolidate') as non_consolidate_runs
    from joined;
    """
    top_sql = """
    with runs as (
      select
        run_id,
        call_id,
        project_id,
        started_at,
        completed_at,
        claims_extracted,
        config->>'mode' as run_mode,
        nullif(config->>'source_run_id','')::uuid as source_run_id
      from public.journal_runs
      where coalesce(claims_extracted, 0) > 0
    ),
    claim_counts as (
      select run_id, count(*)::int as claim_rows
      from public.journal_claims
      group by run_id
    ),
    source_claim_counts as (
      select run_id, count(*)::int as source_claim_rows
      from public.journal_claims
      group by run_id
    ),
    joined as (
      select
        r.run_id, r.call_id, r.project_id, r.started_at, r.completed_at,
        r.claims_extracted,
        r.run_mode,
        r.source_run_id,
        coalesce(c.claim_rows, 0) as claim_rows,
        coalesce(sc.source_claim_rows, 0) as source_claim_rows,
        case
          when r.run_mode = 'consolidate' then
            case
              when r.source_run_id is null then 'consolidate_no_source_run'
              when coalesce(sc.source_claim_rows, 0) > 0 then 'consolidate_source_has_claims'
              else 'consolidate_source_missing_claims'
            end
          else
            case
              when coalesce(c.claim_rows, 0) = 0 then 'direct_run_missing_claims'
              else 'direct_run_has_claims'
            end
        end as mismatch_class
      from runs r
      left join claim_counts c on c.run_id = r.run_id
      left join source_claim_counts sc on sc.run_id = r.source_run_id
    )
    select
      run_id,
      call_id,
      project_id,
      started_at,
      completed_at,
      claims_extracted,
      run_mode,
      source_run_id,
      claim_rows,
      source_claim_rows,
      mismatch_class
    from joined
    where mismatch_class in ('direct_run_missing_claims', 'consolidate_source_missing_claims', 'consolidate_no_source_run')
    order by started_at desc nulls last
    limit %(limit)s;
    """

    with conn.cursor() as cur:
        cur.execute(summary_sql)
        s = cur.fetchone()
        summary = {
            "true_mismatches_24h": s[0],
            "true_mismatches_7d": s[1],
            "true_mismatches_all": s[2],
            "ambiguous_consolidate_24h": s[3],
            "ambiguous_consolidate_7d": s[4],
            "runs_24h_with_claims_extracted": s[5],
            "runs_7d_with_claims_extracted": s[6],
            "consolidate_runs": s[7],
            "non_consolidate_runs": s[8],
        }
        cur.execute(top_sql, {"limit": limit})
        cols = [d.name for d in cur.description]
        top = [dict(zip(cols, row)) for row in cur.fetchall()]

    return {"summary": summary, "top_affected": top}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--out", type=str, default="")
    args = parser.parse_args()

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    load_env(repo_root)
    db = os.environ.get("DATABASE_URL")
    if not db:
        raise SystemExit("ERROR: DATABASE_URL is required")

    with psycopg.connect(db) as conn:
        data = run_forensics(conn, max(1, min(args.limit, 100)))

    payload = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "check": "journal_runid_mismatch_forensics",
        **data,
    }
    text = json.dumps(payload, indent=2, default=str)
    if args.out:
        out = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
