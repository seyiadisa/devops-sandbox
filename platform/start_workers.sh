#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file

mkdir -p "${STATE_DIR}"

start_background_script "${CLEANUP_PID_FILE}" bash "${SCRIPT_DIR}/cleanup_daemon.sh"
start_background_script "${HEALTH_PID_FILE}" bash "${REPO_ROOT}/monitor/health_poller.sh"

printf 'Background workers started\n'
