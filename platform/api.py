from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI

APP_ROOT = Path(__file__).resolve().parent.parent
ENVS_DIR = APP_ROOT / "envs"

app = FastAPI(
    title="DevOps Sandbox Control API",
    version="0.1.0",
    description="Base control plane scaffold for the devops-sandbox platform.",
)


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_datetime(value: str) -> datetime | None:
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _ttl_remaining_seconds(state: dict[str, Any]) -> int | None:
    created_at = state.get("created_at")
    ttl_seconds = state.get("ttl_seconds")
    if not created_at or ttl_seconds is None:
        return None

    created = _parse_datetime(str(created_at))
    if created is None:
        return None

    elapsed = int((_utc_now() - created).total_seconds())
    return max(int(ttl_seconds) - elapsed, 0)


def _read_env_states() -> list[dict[str, Any]]:
    states: list[dict[str, Any]] = []
    if not ENVS_DIR.exists():
        return states

    for state_file in sorted(ENVS_DIR.glob("*.json")):
        try:
            state = json.loads(state_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue

        state["ttl_remaining_seconds"] = _ttl_remaining_seconds(state)
        states.append(state)

    return states


@app.get("/")
def read_root() -> dict[str, Any]:
    return {
        "service": "devops-sandbox-control-api",
        "status": "ok",
        "message": "Step 1 scaffold is running.",
        "docs": "/docs",
    }


@app.get("/health")
def read_health() -> dict[str, Any]:
    return {
        "status": "ok",
        "service": "api",
        "project": os.getenv("PROJECT_NAME", "devops-sandbox"),
        "timestamp": _utc_now().isoformat(),
    }


@app.get("/envs")
def list_envs() -> dict[str, Any]:
    items = _read_env_states()
    return {
        "items": items,
        "count": len(items),
        "message": "Lifecycle endpoints will be implemented in the next step.",
    }
