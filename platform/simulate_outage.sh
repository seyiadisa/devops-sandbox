#!/usr/bin/env bash

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
    printf 'Usage: %s --env <env-id> --mode <crash|pause|network|recover|stress>\n' "$0" >&2
    exit 1
fi

STATE_FILE="$(state_file_path "${ENV_ID}")"
if [[ ! -f "${STATE_FILE}" ]]; then
    printf 'State file not found for %s\n' "${ENV_ID}" >&2
    exit 1
fi

CONTAINER_NAME="$(state_json_get "${STATE_FILE}" "container_name")"
CONTAINER_ID="$(state_json_get "${STATE_FILE}" "container_id")"
LOG_DIR="$(logs_dir_path "${ENV_ID}")"
APP_LOG="${LOG_DIR}/app.log"
ROLE="$(docker inspect -f '{{ index .Config.Labels "sandbox.role" }}' "${CONTAINER_NAME}")"

if [[ "${ROLE}" != "app" ]] || [[ "${CONTAINER_NAME}" == *nginx* ]] || [[ "${CONTAINER_NAME}" == *daemon* ]]; then
    printf 'Refusing to simulate outage against non-sandbox app container: %s\n' "${CONTAINER_NAME}" >&2
    exit 1
fi

record_outage() {
    local mode="$1"
    local meta_json="$2"
    local mode_json
    mode_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${mode}")"
    update_state_file "${STATE_FILE}" "{\"outage_mode\": ${mode_json}, \"outage_meta\": ${meta_json}}"
}

case "${MODE}" in
    crash)
        docker kill "${CONTAINER_NAME}" >/dev/null
        record_outage "crash" '{}'
        ;;
    pause)
        docker pause "${CONTAINER_NAME}" >/dev/null
        record_outage "pause" '{}'
        ;;
    network)
        docker network disconnect "${EDGE_NETWORK}" "${CONTAINER_NAME}" >/dev/null
        EDGE_NETWORK_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${EDGE_NETWORK}")"
        record_outage "network" "{\"edge_network\": ${EDGE_NETWORK_JSON}}"
        ;;
    recover)
        PREVIOUS_MODE="$(state_json_get "${STATE_FILE}" "outage_mode" || true)"
        case "${PREVIOUS_MODE}" in
            crash)
                docker start "${CONTAINER_NAME}" >/dev/null
                LOG_PID="$(state_json_get "${STATE_FILE}" "log_pid" || true)"
                if [[ -z "${LOG_PID}" ]] || ! kill -0 "${LOG_PID}" >/dev/null 2>&1; then
                    NEW_LOG_PID="$(start_log_shipper "${CONTAINER_ID}" "${APP_LOG}")"
                    update_state_file "${STATE_FILE}" "{\"log_pid\": ${NEW_LOG_PID}}"
                fi
                ;;
            pause)
                docker unpause "${CONTAINER_NAME}" >/dev/null
                ;;
            network)
                docker network connect "${EDGE_NETWORK}" "${CONTAINER_NAME}" >/dev/null 2>&1 || true
                ;;
            stress)
                docker exec "${CONTAINER_NAME}" pkill -f stress-ng >/dev/null 2>&1 || true
                ;;
            *)
                printf 'No recoverable outage mode recorded for %s\n' "${ENV_ID}" >&2
                exit 1
                ;;
        esac
        update_state_file "${STATE_FILE}" '{"outage_mode": null, "outage_meta": {}}'
        ;;
    stress)
        if docker exec "${CONTAINER_NAME}" sh -c 'command -v stress-ng >/dev/null 2>&1'; then
            docker exec -d "${CONTAINER_NAME}" sh -c 'stress-ng --cpu 1 --timeout 120s'
            record_outage "stress" '{}'
        else
            printf 'stress-ng is not installed in the sandbox app image.\n' >&2
            exit 1
        fi
        ;;
    *)
        printf 'Unsupported outage mode: %s\n' "${MODE}" >&2
        exit 1
        ;;
esac

printf 'Outage action complete: %s for %s\n' "${MODE}" "${ENV_ID}"
