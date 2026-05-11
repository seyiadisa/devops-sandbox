#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file
require_command docker

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_ID="${2:-}"
            shift 2
            ;;
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${ENV_ID}" || -z "${MODE}" ]]; then
    printf 'Usage: %s --env <env-id> --mode <crash|pause|network|recover>\n' "$0" >&2
    exit 1
fi

STATE_FILE="$(state_file_path "${ENV_ID}")"
if [[ ! -f "${STATE_FILE}" ]]; then
    printf 'State file not found for %s\n' "${ENV_ID}" >&2
    exit 1
fi

CONTAINER_NAME="$(state_json_get "${STATE_FILE}" "container_name")"
ROLE="$(docker inspect -f '{{ index .Config.Labels "sandbox.role" }}' "${CONTAINER_NAME}")"

if [[ "${ROLE}" != "app" ]] || [[ "${CONTAINER_NAME}" == *nginx* ]] || [[ "${CONTAINER_NAME}" == *daemon* ]]; then
    printf 'Refusing to simulate outage against non-sandbox app container: %s\n' "${CONTAINER_NAME}" >&2
    exit 1
fi

case "${MODE}" in
    crash)
        docker kill "${CONTAINER_NAME}" >/dev/null
        ;;
    pause)
        docker pause "${CONTAINER_NAME}" >/dev/null
        ;;
    network)
        docker network disconnect "${EDGE_NETWORK}" "${CONTAINER_NAME}" >/dev/null
        ;;
    recover)
        docker start "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        docker unpause "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        docker network connect "${EDGE_NETWORK}" "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        ;;
    *)
        printf 'Unsupported outage mode: %s\n' "${MODE}" >&2
        exit 1
        ;;
esac

printf 'Outage action complete: %s for %s\n' "${MODE}" "${ENV_ID}"
