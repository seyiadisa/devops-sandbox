import os

from fastapi import FastAPI

app = FastAPI(title="DevOps Sandbox Demo App", version="0.1.0")


@app.get("/")
def read_root() -> dict[str, str]:
    return {
        "message": "Hello from a sandbox app template.",
        "status": "ready",
        "env_id": os.getenv("SANDBOX_ENV_ID", "unknown"),
        "env_name": os.getenv("SANDBOX_ENV_NAME", "unknown"),
    }


@app.get("/health")
def read_health() -> dict[str, str]:
    return {
        "status": "ok",
        "env_id": os.getenv("SANDBOX_ENV_ID", "unknown"),
        "env_name": os.getenv("SANDBOX_ENV_NAME", "unknown"),
    }
