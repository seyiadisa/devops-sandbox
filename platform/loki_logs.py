#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import UTC, datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_env_file() -> None:
    env_file = REPO_ROOT / ".env"
    if not env_file.exists():
        return
    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value.rstrip("/")


def _iso_to_ns(value: str) -> int:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return int(datetime.fromisoformat(value).timestamp() * 1_000_000_000)


def _query_loki(env_id: str, start_ns: int, end_ns: int, limit: int) -> list[tuple[int, str]]:
    loki_url = _required_env("LOKI_URL")
    params = urllib.parse.urlencode(
        {
            "query": f'{{sandbox_env="{env_id}"}}',
            "start": str(start_ns),
            "end": str(end_ns),
            "limit": str(limit),
            "direction": "backward",
        }
    )
    with urllib.request.urlopen(f"{loki_url}/loki/api/v1/query_range?{params}", timeout=30) as response:
        payload = json.load(response)

    streams = payload.get("data", {}).get("result", [])
    entries: list[tuple[int, str]] = []
    for stream in streams:
        for ts, line in stream.get("values", []):
            entries.append((int(ts), line))
    entries.sort(key=lambda item: item[0])
    return entries


def cmd_tail(args: argparse.Namespace) -> int:
    end_ns = int(datetime.now(UTC).timestamp() * 1_000_000_000)
    start_ns = end_ns - int(timedelta(hours=args.hours).total_seconds() * 1_000_000_000)
    for _, line in _query_loki(args.env, start_ns, end_ns, args.limit):
        print(line.rstrip("\n"))
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    start_ns = _iso_to_ns(args.start)
    end_ns = int(datetime.now(UTC).timestamp() * 1_000_000_000)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [line.rstrip("\n") for _, line in _query_loki(args.env, start_ns, end_ns, args.limit)]
    output_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Query Loki logs for sandbox environments.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    tail_parser = subparsers.add_parser("tail", help="Print recent logs for an environment.")
    tail_parser.add_argument("--env", required=True)
    tail_parser.add_argument("--limit", type=int, default=100)
    tail_parser.add_argument("--hours", type=int, default=24)
    tail_parser.set_defaults(func=cmd_tail)

    export_parser = subparsers.add_parser("export", help="Export logs for an environment to a file.")
    export_parser.add_argument("--env", required=True)
    export_parser.add_argument("--start", required=True)
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--limit", type=int, default=5000)
    export_parser.set_defaults(func=cmd_export)

    return parser


def main() -> int:
    _load_env_file()
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
