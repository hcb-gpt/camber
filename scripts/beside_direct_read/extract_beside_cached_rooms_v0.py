#!/usr/bin/env python3
"""
Beside direct-read prototype v0.

Reads a cached `cached_rooms.json` export, base64-decodes each `room` blob,
extracts stable message/call events, normalizes timestamps, and emits:
1) extraction output JSON
2) optional ingest-stub payload for downstream wiring
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
from pathlib import Path
from typing import Any, Dict, List, Optional

APPLE_EPOCH_UTC = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
SOURCE_TAG = "beside_direct_read_v0"


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def maybe_unwrap_0(node: Any) -> Any:
    if isinstance(node, dict) and "_0" in node and len(node) == 1:
        return node["_0"]
    return node


def normalize_timestamp_to_utc(value: Any) -> Optional[str]:
    """
    Normalize heterogeneous Beside timestamps:
    - Unix milliseconds (e.g. 1772237091000)
    - Unix seconds (>= 946684800)
    - CFAbsoluteTime seconds since 2001-01-01 (common in local cache)
    """
    if value is None:
        return None

    if isinstance(value, str):
        s = value.strip()
        if not s:
            return None
        try:
            numeric = float(s)
        except ValueError:
            try:
                parsed = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
                return parsed.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
            except ValueError:
                return None
    elif isinstance(value, (int, float)):
        numeric = float(value)
    else:
        return None

    if numeric > 1e11:
        parsed = dt.datetime.fromtimestamp(numeric / 1000.0, tz=dt.timezone.utc)
    elif numeric >= 946684800:
        parsed = dt.datetime.fromtimestamp(numeric, tz=dt.timezone.utc)
    elif numeric >= 0:
        parsed = APPLE_EPOCH_UTC + dt.timedelta(seconds=numeric)
    else:
        parsed = dt.datetime.fromtimestamp(numeric, tz=dt.timezone.utc)

    return parsed.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def safe_json_loads(raw: str) -> Optional[Dict[str, Any]]:
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def decode_room_blob(room_blob_b64: str) -> Dict[str, Any]:
    raw_bytes = base64.b64decode(room_blob_b64)
    as_text = raw_bytes.decode("utf-8", errors="replace")
    decoded = safe_json_loads(as_text)
    if decoded is None:
        raise ValueError("room blob did not decode into a JSON object")
    return decoded


def pick_thread_id(room: Dict[str, Any], entity: Dict[str, Any]) -> str:
    for candidate in (
        entity.get("chatId"),
        room.get("id"),
        (room.get("chat") or {}).get("id"),
    ):
        if isinstance(candidate, str) and candidate.startswith("prv_"):
            return candidate
    return "prv_unknown"


def parse_summary_text(serialized_summary: Any, summary: Any) -> Optional[str]:
    if isinstance(summary, str) and summary.strip():
        return summary.strip()

    if isinstance(serialized_summary, str) and serialized_summary.strip():
        raw = serialized_summary.strip()
        parsed = safe_json_loads(raw)
        if parsed and isinstance(parsed.get("summary"), str) and parsed["summary"].strip():
            return parsed["summary"].strip()
        return raw
    return None


def extract_event_from_room(room: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    last_entity = room.get("lastEntity")
    if not isinstance(last_entity, dict):
        return None

    msg_wrapper = last_entity.get("message")
    if isinstance(msg_wrapper, dict):
        msg = maybe_unwrap_0(msg_wrapper)
        if isinstance(msg, dict):
            thread_id = pick_thread_id(room, msg)
            event_id = msg.get("id")
            if not isinstance(event_id, str) or not event_id.startswith("msg_"):
                return None
            occurred_at_utc = normalize_timestamp_to_utc(
                msg.get("sentAt") or msg.get("updatedAt") or room.get("updatedDate")
            )
            return {
                "source": SOURCE_TAG,
                "event_type": "message",
                "thread_id": thread_id,
                "event_id": event_id,
                "occurred_at_utc": occurred_at_utc,
                "text": (msg.get("text") or "").strip() or None,
                "metadata": {
                    "sender_user_id": msg.get("senderUserId"),
                    "sender_inbox_id": msg.get("senderInboxId"),
                    "author_id": msg.get("authorId"),
                    "title_for_room": room.get("titleForRoom"),
                },
                "raw": {
                    "message": msg,
                    "room_updated_date": room.get("updatedDate"),
                },
            }

    call_wrapper = last_entity.get("call")
    if isinstance(call_wrapper, dict):
        call = maybe_unwrap_0(call_wrapper)
        if isinstance(call, dict):
            thread_id = pick_thread_id(room, call)
            event_id = call.get("id")
            if not isinstance(event_id, str) or not event_id.startswith("cll_"):
                return None
            occurred_at_utc = normalize_timestamp_to_utc(
                call.get("initiatedAt")
                or call.get("finishedAt")
                or call.get("updatedAt")
                or room.get("updatedDate")
            )
            return {
                "source": SOURCE_TAG,
                "event_type": "call",
                "thread_id": thread_id,
                "event_id": event_id,
                "occurred_at_utc": occurred_at_utc,
                "text": parse_summary_text(call.get("serializedSummary"), call.get("summary")),
                "metadata": {
                    "status": call.get("status"),
                    "caller_id": call.get("callerId"),
                    "recipient_id": call.get("recipientId"),
                    "share_url": call.get("shareURL"),
                    "title_for_room": room.get("titleForRoom"),
                },
                "raw": {
                    "call": call,
                    "room_updated_date": room.get("updatedDate"),
                },
            }

    return None


def build_ingest_stub(events: List[Dict[str, Any]]) -> Dict[str, Any]:
    records = []
    for event in events:
        records.append(
            {
                "source_tag": SOURCE_TAG,
                "event_type": event["event_type"],
                "event_id": event["event_id"],
                "thread_id": event["thread_id"],
                "occurred_at_utc": event["occurred_at_utc"],
                "text": event.get("text"),
                "metadata": event.get("metadata", {}),
            }
        )
    return {
        "version": "beside_direct_read_ingest_stub_v0",
        "generated_at_utc": utc_now_iso(),
        "record_count": len(records),
        "records": records,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract message/call events from Beside cached_rooms.json")
    parser.add_argument(
        "--input",
        required=True,
        help="Path to cached_rooms.json",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to extraction output JSON",
    )
    parser.add_argument(
        "--ingest-stub-output",
        default="",
        help="Optional path to write stable ingest-stub payload JSON",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).expanduser()
    output_path = Path(args.output).expanduser()

    payload = json.loads(input_path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        raise RuntimeError("cached_rooms.json must be a top-level JSON array")

    events: List[Dict[str, Any]] = []
    decode_errors: List[Dict[str, Any]] = []

    for idx, row in enumerate(payload, start=1):
        if not isinstance(row, dict):
            decode_errors.append({"row_index": idx, "error": "row_not_object"})
            continue
        if row.get("typeName") != "Room":
            continue
        room_blob = row.get("room")
        if not isinstance(room_blob, str) or not room_blob.strip():
            decode_errors.append({"row_index": idx, "error": "missing_room_blob"})
            continue

        try:
            room = decode_room_blob(room_blob)
        except Exception as exc:  # noqa: BLE001
            decode_errors.append({"row_index": idx, "error": f"decode_failed:{exc}"})
            continue

        event = extract_event_from_room(room)
        if event is not None:
            events.append(event)

    extraction = {
        "version": "beside_direct_read_extract_v0",
        "source_tag": SOURCE_TAG,
        "generated_at_utc": utc_now_iso(),
        "input_path": str(input_path),
        "rooms_total": len(payload),
        "events_extracted": len(events),
        "decode_errors": decode_errors,
        "events": events,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(extraction, indent=2) + "\n", encoding="utf-8")

    if args.ingest_stub_output:
        stub_path = Path(args.ingest_stub_output).expanduser()
        stub_path.parent.mkdir(parents=True, exist_ok=True)
        stub = build_ingest_stub(events)
        stub_path.write_text(json.dumps(stub, indent=2) + "\n", encoding="utf-8")

    print(
        f"extracted={len(events)} rooms_total={len(payload)} decode_errors={len(decode_errors)} "
        f"output={output_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
