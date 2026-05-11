#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/platform/common.sh"

load_env_file
require_command python3

touch "${HEALTH_MONITOR_LOG_FILE}"
log_with_timestamp "${HEALTH_MONITOR_LOG_FILE}" "health poller started"

check_env_health() {
    local state_file="$1"
    python3 - "${state_file}" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

state_path = Path(sys.argv[1])
if not state_path.exists():
    sys.exit(2)
state = json.loads(state_path.read_text(encoding="utf-8"))
url = state["url"].rstrip("/") + "/health"
started = time.perf_counter()
status = 0
try:
    with urllib.request.urlopen(url, timeout=10) as response:
        status = response.getcode()
except urllib.error.HTTPError as exc:
    status = exc.code
except Exception:
    status = 0
latency_ms = int((time.perf_counter() - started) * 1000)
print(json.dumps({"status": status, "latency_ms": latency_ms}))
PY
}

while true; do
    shopt -s nullglob
    for state_file in "${STATE_DIR}"/*.json; do
        [[ -f "${state_file}" ]] || continue
        env_id="$(basename "${state_file}" .json)"
        env_log_dir="${LOGS_DIR}/${env_id}"
        health_log="${env_log_dir}/health.log"
        mkdir -p "${env_log_dir}"

        if ! result="$(check_env_health "${state_file}")"; then
            continue
        fi
        [[ -f "${state_file}" ]] || continue
        status_code="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['status'])" "${result}")"
        latency_ms="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['latency_ms'])" "${result}")"

        printf '[%s] status=%s latency_ms=%s\n' "$(timestamp_utc)" "${status_code}" "${latency_ms}" >>"${health_log}"

        if [[ "${status_code}" -ge 200 && "${status_code}" -lt 400 ]]; then
            [[ -f "${state_file}" ]] || continue
            append_json_state_file "${state_file}" '
data["consecutive_failures"] = 0
data["last_health_status"] = int("'"${status_code}"'")
data["last_latency_ms"] = int("'"${latency_ms}"'")
if data.get("status") != "destroying":
    data["status"] = "healthy"
'
        else
            [[ -f "${state_file}" ]] || continue
            previous_failures="$(state_json_get "${state_file}" "consecutive_failures" || printf '0')"
            append_json_state_file "${state_file}" '
failures = int(data.get("consecutive_failures", 0)) + 1
data["consecutive_failures"] = failures
data["last_health_status"] = int("'"${status_code}"'")
data["last_latency_ms"] = int("'"${latency_ms}"'")
if failures >= 3 and data.get("status") != "destroying":
    data["status"] = "degraded"
'
            failure_count="$(state_json_get "${state_file}" "consecutive_failures" || printf '0')"
            if [[ "${previous_failures}" -lt 3 && "${failure_count}" -ge 3 ]]; then
                warning="WARNING: ${env_id} is degraded after ${failure_count} consecutive health check failures"
                printf '%s\n' "${warning}"
                log_with_timestamp "${HEALTH_MONITOR_LOG_FILE}" "${warning}"
            fi
        fi
    done
    shopt -u nullglob
    sleep 30
done
