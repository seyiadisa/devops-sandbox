#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file
require_command docker
require_command python3

ENV_ID="${1:-}"
if [[ -z "${ENV_ID}" ]]; then
    printf 'Usage: %s <env_id>\n' "$0" >&2
    exit 1
fi

STATE_FILE="$(state_file_path "${ENV_ID}")"
if [[ ! -f "${STATE_FILE}" ]]; then
    printf 'State file not found for %s\n' "${ENV_ID}" >&2
    exit 1
fi

LOG_DIR="$(logs_dir_path "${ENV_ID}")"
ARCHIVE_TARGET="${ARCHIVE_DIR}/${ENV_ID}"
NGINX_CONF_FILE="$(nginx_conf_path "${ENV_ID}")"

CONTAINER_NAME="$(state_json_get "${STATE_FILE}" "container_name")"
NETWORK_NAME="$(state_json_get "${STATE_FILE}" "network")"
LOG_PID="$(state_json_get "${STATE_FILE}" "log_pid" || true)"

update_state_file "${STATE_FILE}" '{"status":"destroying"}'

if [[ -n "${LOG_PID:-}" ]] && kill -0 "${LOG_PID}" >/dev/null 2>&1; then
    kill "${LOG_PID}" >/dev/null 2>&1 || true
    wait "${LOG_PID}" 2>/dev/null || true
fi

mapfile -t CONTAINERS < <(docker ps -aq --filter "label=sandbox.env=${ENV_ID}")
if [[ "${#CONTAINERS[@]}" -gt 0 ]]; then
    docker rm -f "${CONTAINERS[@]}" >/dev/null
elif docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    docker network rm "${NETWORK_NAME}" >/dev/null
fi

if [[ -f "${NGINX_CONF_FILE}" ]]; then
    rm -f "${NGINX_CONF_FILE}"
    if docker container inspect "${NGINX_CONTAINER_NAME}" >/dev/null 2>&1; then
        reload_nginx
    fi
fi

if [[ -d "${LOG_DIR}" ]]; then
    mkdir -p "${ARCHIVE_DIR}"
    rm -rf "${ARCHIVE_TARGET}"
    mv "${LOG_DIR}" "${ARCHIVE_TARGET}"
fi

rm -f "${STATE_FILE}"

printf 'Environment destroyed: %s\n' "${ENV_ID}"
