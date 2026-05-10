from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

APP_ROOT = Path(__file__).resolve().parent.parent
ENVS_DIR = APP_ROOT / "envs"
LOGS_DIR = APP_ROOT / "logs"
PLATFORM_DIR = APP_ROOT / "platform"

app = FastAPI(
    title="DevOps Sandbox Control API",
    version="0.1.0",
    description="Base control plane scaffold for the devops-sandbox platform.",
)


class CreateEnvRequest(BaseModel):
    name: str = Field(min_length=1)
    ttl_minutes: int = Field(default=30, gt=0)


class OutageRequest(BaseModel):
    mode: str


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


def _state_file(env_id: str) -> Path:
    return ENVS_DIR / f"{env_id}.json"


def _read_state(env_id: str) -> dict[str, Any]:
    state_path = _state_file(env_id)
    if not state_path.exists():
        raise HTTPException(status_code=404, detail=f"Environment not found: {env_id}")

    try:
        data = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=500, detail=f"Failed to read state for {env_id}") from exc

    data["ttl_remaining_seconds"] = _ttl_remaining_seconds(data)
    return data


def _run_script(script_name: str, *args: str) -> subprocess.CompletedProcess[str]:
    script_path = PLATFORM_DIR / script_name
    return subprocess.run(
        ["bash", str(script_path), *args],
        cwd=APP_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def _read_tail(path: Path, line_count: int) -> list[str]:
    if not path.exists():
        return []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"Failed to read {path.name}") from exc
    return lines[-line_count:]


def _resolve_log_path(env_id: str, filename: str) -> Path:
    active_path = LOGS_DIR / env_id / filename
    if active_path.exists():
        return active_path
    return LOGS_DIR / "archived" / env_id / filename


def _prometheus_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


@app.get("/")
def read_root() -> dict[str, Any]:
    return {
        "service": "devops-sandbox-control-api",
        "status": "ok",
        "message": "DevOps sandbox control API is running.",
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


@app.post("/envs")
def create_env(payload: CreateEnvRequest) -> dict[str, Any]:
    result = _run_script("create_env.sh", payload.name, str(payload.ttl_minutes))
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=result.stderr.strip() or result.stdout.strip() or "Environment creation failed.",
        )

    env_id = ""
    for line in result.stdout.splitlines():
        if line.startswith("ID: "):
            env_id = line.split("ID: ", 1)[1].strip()
            break

    if not env_id:
        raise HTTPException(status_code=500, detail="Environment was created but ID could not be determined.")

    return {
        "message": "Environment created",
        "output": result.stdout.strip(),
        "environment": _read_state(env_id),
    }


@app.get("/envs")
def list_envs() -> dict[str, Any]:
    items = _read_env_states()
    return {
        "items": items,
        "count": len(items),
    }


@app.delete("/envs/{env_id}")
def destroy_env(env_id: str) -> dict[str, Any]:
    _read_state(env_id)
    result = _run_script("destroy_env.sh", env_id)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=result.stderr.strip() or result.stdout.strip() or f"Failed to destroy {env_id}",
        )
    return {
        "message": f"Destroyed {env_id}",
        "output": result.stdout.strip(),
    }


@app.get("/envs/{env_id}/logs")
def get_env_logs(env_id: str) -> dict[str, Any]:
    log_path = _resolve_log_path(env_id, "app.log")
    if not log_path.exists():
        _read_state(env_id)
    return {
        "env_id": env_id,
        "lines": _read_tail(log_path, 100),
    }


@app.get("/envs/{env_id}/health")
def get_env_health(env_id: str) -> dict[str, Any]:
    health_path = _resolve_log_path(env_id, "health.log")
    if not health_path.exists():
        _read_state(env_id)
    return {
        "env_id": env_id,
        "lines": _read_tail(health_path, 10),
    }


@app.post("/envs/{env_id}/outage")
def simulate_outage(env_id: str, payload: OutageRequest) -> dict[str, Any]:
    _read_state(env_id)
    result = _run_script("simulate_outage.sh", "--env", env_id, "--mode", payload.mode)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=result.stderr.strip() or result.stdout.strip() or f"Failed to simulate outage for {env_id}",
        )
    return {
        "message": f"Outage action {payload.mode} complete for {env_id}",
        "output": result.stdout.strip(),
        "environment": _read_state(env_id),
    }


@app.get("/metrics", include_in_schema=False, response_class=PlainTextResponse)
def metrics() -> str:
    items = _read_env_states()
    lines = [
        "# HELP sandbox_env_total Number of active sandbox environments",
        "# TYPE sandbox_env_total gauge",
        f"sandbox_env_total {len(items)}",
        "# HELP sandbox_env_ttl_remaining_seconds Remaining environment TTL in seconds",
        "# TYPE sandbox_env_ttl_remaining_seconds gauge",
        "# HELP sandbox_env_status Sandbox environment status where healthy=1 degraded=2 destroying=3 other=0",
        "# TYPE sandbox_env_status gauge",
    ]
    status_map = {"healthy": 1, "degraded": 2, "destroying": 3, "active": 1}
    for item in items:
        env_id = _prometheus_escape(str(item["id"]))
        name = _prometheus_escape(str(item["name"]))
        ttl = item.get("ttl_remaining_seconds")
        if ttl is not None:
            lines.append(f'sandbox_env_ttl_remaining_seconds{{env_id="{env_id}",name="{name}"}} {ttl}')
        status_value = status_map.get(str(item.get("status", "")), 0)
        lines.append(f'sandbox_env_status{{env_id="{env_id}",name="{name}"}} {status_value}')
    return "\n".join(lines) + "\n"
