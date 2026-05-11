#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file

mkdir -p "${STATE_DIR}"

start_background_script "$(cleanup_pid_file_path)" "$(cleanup_log_file_path)" bash "${SCRIPT_DIR}/cleanup_daemon.sh"
start_background_script "$(health_pid_file_path)" "$(health_monitor_log_file_path)" bash "${REPO_ROOT}/monitor/health_poller.sh"

printf 'Background workers started\n'
