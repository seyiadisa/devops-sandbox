#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/platform/common.sh"

load_env_file
require_command python3

health_monitor_log_file="$(health_monitor_log_file_path)"
touch "${health_monitor_log_file}"
log_with_timestamp "${health_monitor_log_file}" "health poller started"

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
if data.get("status") != "destroying":
    data["status"] = "healthy"
'
        else
            [[ -f "${state_file}" ]] || continue
            previous_failures="$(python3 - "${health_log}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print(0)
    raise SystemExit

count = 0
for line in reversed(path.read_text(encoding="utf-8").splitlines()):
    if " status=" not in line:
        continue
    status_token = line.split("status=", 1)[1].split()[0]
    try:
        status_code = int(status_token)
    except ValueError:
        break
    if 200 <= status_code < 400:
        break
    count += 1
print(count - 1 if count > 0 else 0)
PY
)"
            append_json_state_file "${state_file}" '
if int("'"${previous_failures}"'") + 1 >= 3 and data.get("status") != "destroying":
    data["status"] = "degraded"
'
            failure_count="$((previous_failures + 1))"
            if [[ "${previous_failures}" -lt 3 && "${failure_count}" -ge 3 ]]; then
                warning="WARNING: ${env_id} is degraded after ${failure_count} consecutive health check failures"
                printf '%s\n' "${warning}"
                log_with_timestamp "${health_monitor_log_file}" "${warning}"
            fi
        fi
    done
    shopt -u nullglob
    sleep 30
done
