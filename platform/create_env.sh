#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file
require_command docker
require_command python3

NAME="${1:-}"
TTL_MINUTES="${2:-${DEFAULT_TTL_MINUTES}}"

if [[ -z "${NAME}" ]]; then
    printf 'Usage: %s <name> [ttl_minutes]\n' "$0" >&2
    exit 1
fi

if ! [[ "${TTL_MINUTES}" =~ ^[0-9]+$ ]] || [[ "${TTL_MINUTES}" -le 0 ]]; then
    printf 'TTL must be a positive integer number of minutes.\n' >&2
    exit 1
fi

ENV_ID="$(generate_env_id)"
STATE_FILE="$(state_file_path "${ENV_ID}")"
LOG_DIR="$(logs_dir_path "${ENV_ID}")"
NETWORK_NAME="${PROJECT_NAME}-${ENV_ID}"
CONTAINER_NAME="${PROJECT_NAME}-${ENV_ID}-app"
CREATED_AT="$(timestamp_utc)"
TTL_SECONDS="$((TTL_MINUTES * 60))"
URL="$(env_url "${ENV_ID}")"
NGINX_CONF_FILE="$(nginx_conf_path "${ENV_ID}")"

mkdir -p "${LOG_DIR}"

cleanup_on_failure() {
    set +e
    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
    fi
    if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
        docker network rm "${NETWORK_NAME}" >/dev/null 2>&1
    fi
    rm -f "${NGINX_CONF_FILE}" "${STATE_FILE}"
}

trap cleanup_on_failure ERR

ensure_edge_network
ensure_sandbox_image

echo "Creating Docker network: ${NETWORK_NAME}"
docker network create "${NETWORK_NAME}" >/dev/null

CONTAINER_ID="$(
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --label "sandbox.env=${ENV_ID}" \
        --label "sandbox.name=${NAME}" \
        --label "sandbox.role=app" \
        --env "SANDBOX_ENV_ID=${ENV_ID}" \
        --env "SANDBOX_ENV_NAME=${NAME}" \
        --network "${NETWORK_NAME}" \
        "${SANDBOX_IMAGE}"
)"

docker network connect "${EDGE_NETWORK}" "${CONTAINER_NAME}" >/dev/null

cat >"${NGINX_CONF_FILE}" <<EOF
location /envs/${ENV_ID}/ {
    rewrite ^/envs/${ENV_ID}/(.*)$ /\$1 break;
    proxy_pass http://${CONTAINER_NAME}:${SANDBOX_INTERNAL_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Sandbox-Env ${ENV_ID};
}
EOF

reload_nginx

STATE_JSON="$(
python3 - <<PY
import json

payload = {
    "id": "${ENV_ID}",
    "name": "${NAME}",
    "created_at": "${CREATED_AT}",
    "ttl_minutes": ${TTL_MINUTES},
    "ttl_seconds": ${TTL_SECONDS},
    "status": "healthy",
    "url": "${URL}",
    "network": "${NETWORK_NAME}",
    "edge_network": "${EDGE_NETWORK}",
    "container_id": "${CONTAINER_ID}",
    "container_name": "${CONTAINER_NAME}",
    "log_backend": "loki",
    "outage_mode": None,
    "outage_meta": {},
    "consecutive_failures": 0,
    "last_health_status": None,
    "last_latency_ms": None,
}
print(json.dumps(payload, indent=2))
PY
)"

write_state_file "${STATE_FILE}" "${STATE_JSON}"
trap - ERR

printf 'Environment created\n'
printf 'ID: %s\n' "${ENV_ID}"
printf 'URL: %s\n' "${URL}"
printf 'TTL: %s minutes\n' "${TTL_MINUTES}"
