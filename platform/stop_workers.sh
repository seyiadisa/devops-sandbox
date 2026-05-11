#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file

stop_background_script "${CLEANUP_PID_FILE}"
stop_background_script "${HEALTH_PID_FILE}"

printf 'Background workers stopped\n'
