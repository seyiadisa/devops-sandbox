#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

refresh_runtime_config() {
    # shellcheck disable=SC2034
    PROJECT_NAME="${PROJECT_NAME:-devops-sandbox}"
    EDGE_NETWORK="${EDGE_NETWORK:-${DOCKER_NETWORK:-devops-sandbox-edge}}"
    API_PORT="${API_PORT:-8000}"
    NGINX_PORT="${NGINX_PORT:-8080}"
    SANDBOX_IMAGE="${SANDBOX_IMAGE:-${PROJECT_NAME}-sandbox-app}"
    SANDBOX_INTERNAL_PORT="${SANDBOX_INTERNAL_PORT:-8000}"
    DEFAULT_TTL_MINUTES="${DEFAULT_TTL_MINUTES:-30}"
    NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-${PROJECT_NAME}-nginx}"
    STATE_DIR="${REPO_ROOT}/envs"
    LOGS_DIR="${REPO_ROOT}/logs"
    ARCHIVE_DIR="${LOGS_DIR}/archived"
    NGINX_CONF_DIR="${REPO_ROOT}/nginx/conf.d"
    SANDBOX_DOCKERFILE="${REPO_ROOT}/sandbox_app/Dockerfile"
    # shellcheck disable=SC2034
    CLEANUP_LOG_FILE="${LOGS_DIR}/cleanup.log"
    # shellcheck disable=SC2034
    HEALTH_MONITOR_LOG_FILE="${LOGS_DIR}/health-monitor.log"
    # shellcheck disable=SC2034
    CLEANUP_PID_FILE="${STATE_DIR}/cleanup_daemon.pid"
    # shellcheck disable=SC2034
    HEALTH_PID_FILE="${STATE_DIR}/health_poller.pid"
}

refresh_runtime_config

mkdir -p "${STATE_DIR}" "${LOGS_DIR}" "${ARCHIVE_DIR}" "${NGINX_CONF_DIR}"

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "${cmd}" >&2
        exit 1
    fi
}

load_env_file() {
    local env_file="${REPO_ROOT}/.env"
    if [[ -f "${env_file}" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "${env_file}"
        set +a
    fi
    refresh_runtime_config
    mkdir -p "${STATE_DIR}" "${LOGS_DIR}" "${ARCHIVE_DIR}" "${NGINX_CONF_DIR}"
}

state_file_path() {
    printf '%s/%s.json\n' "${STATE_DIR}" "$1"
}

logs_dir_path() {
    printf '%s/%s\n' "${LOGS_DIR}" "$1"
}

nginx_conf_path() {
    printf '%s/%s.conf\n' "${NGINX_CONF_DIR}" "$1"
}

timestamp_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

generate_env_id() {
    printf 'env-%s-%s\n' "$(date -u +%Y%m%d%H%M%S)" "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
}

state_json_get() {
    local file="$1"
    local key="$2"
    python3 - "$file" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
value = data.get(key)
if value is None:
    sys.exit(1)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

write_state_file() {
    local target_file="$1"
    local json_payload="$2"
    local tmp_file
    tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"
    printf '%s\n' "${json_payload}" >"${tmp_file}"
    mv "${tmp_file}" "${target_file}"
}

update_state_file() {
    local target_file="$1"
    local patch_json="$2"
    local tmp_file
    tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"
    python3 - "${target_file}" "${patch_json}" "${tmp_file}" <<'PY'
import json
import sys
from pathlib import Path

target = Path(sys.argv[1])
patch = json.loads(sys.argv[2])
tmp = Path(sys.argv[3])
data = json.loads(target.read_text(encoding="utf-8"))
data.update(patch)
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
    mv "${tmp_file}" "${target_file}"
}

append_json_state_file() {
    local target_file="$1"
    local update_python="$2"
    local tmp_file
    tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"
    python3 - "${target_file}" "${tmp_file}" <<PY
import json
import sys
from pathlib import Path

target = Path(sys.argv[1])
tmp = Path(sys.argv[2])
data = json.loads(target.read_text(encoding="utf-8"))
${update_python}
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
    mv "${tmp_file}" "${target_file}"
}

ensure_edge_network() {
    if ! docker network inspect "${EDGE_NETWORK}" >/dev/null 2>&1; then
        docker network create "${EDGE_NETWORK}" >/dev/null
    fi
}

ensure_sandbox_image() {
    if ! docker image inspect "${SANDBOX_IMAGE}" >/dev/null 2>&1; then
        docker build -t "${SANDBOX_IMAGE}" -f "${SANDBOX_DOCKERFILE}" "${REPO_ROOT}" >/dev/null
    fi
}

reload_nginx() {
    docker exec "${NGINX_CONTAINER_NAME}" nginx -s reload >/dev/null
}

env_url() {
    local env_id="$1"
    local host="${SANDBOX_BASE_URL:-http://localhost:${NGINX_PORT}}"
    printf '%s/envs/%s/\n' "${host%/}" "${env_id}"
}

log_with_timestamp() {
    local log_file="$1"
    shift
    printf '[%s] %s\n' "$(timestamp_utc)" "$*" >>"${log_file}"
}

start_log_shipper() {
    local container_id="$1"
    local app_log="$2"
    nohup docker logs -f "${container_id}" >>"${app_log}" 2>&1 &
    printf '%s\n' "$!"
}

start_background_script() {
    local pid_file="$1"
    shift
    if [[ -f "${pid_file}" ]]; then
        local existing_pid
        existing_pid="$(cat "${pid_file}")"
        if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" >/dev/null 2>&1; then
            return 0
        fi
        rm -f "${pid_file}"
    fi
    nohup "$@" >/dev/null 2>&1 &
    printf '%s\n' "$!" >"${pid_file}"
}

stop_background_script() {
    local pid_file="$1"
    if [[ -f "${pid_file}" ]]; then
        local pid
        pid="$(cat "${pid_file}")"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
            kill "${pid}" >/dev/null 2>&1 || true
            wait "${pid}" 2>/dev/null || true
        fi
        rm -f "${pid_file}"
    fi
}
