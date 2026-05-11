#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file
require_command python3

mkdir -p "${LOGS_DIR}"
touch "${CLEANUP_LOG_FILE}"

log_with_timestamp "${CLEANUP_LOG_FILE}" "cleanup daemon started"

while true; do
    shopt -s nullglob
    for state_file in "${STATE_DIR}"/*.json; do
        env_id="$(basename "${state_file}" .json)"
        if python3 - "${state_file}" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
created = datetime.fromisoformat(data["created_at"].replace("Z", "+00:00"))
ttl_seconds = int(data["ttl_seconds"])
expired = datetime.now(timezone.utc) > created + timedelta(seconds=ttl_seconds)
sys.exit(0 if expired else 1)
PY
        then
            log_with_timestamp "${CLEANUP_LOG_FILE}" "ttl expired for ${env_id}, destroying environment"
            if bash "${SCRIPT_DIR}/destroy_env.sh" "${env_id}" >>"${CLEANUP_LOG_FILE}" 2>&1; then
                log_with_timestamp "${CLEANUP_LOG_FILE}" "destroyed expired environment ${env_id}"
            else
                log_with_timestamp "${CLEANUP_LOG_FILE}" "failed to destroy expired environment ${env_id}"
            fi
        fi
    done
    shopt -u nullglob
    sleep 60
done
