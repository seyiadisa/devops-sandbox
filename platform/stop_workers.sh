#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env_file

stop_background_script "$(cleanup_pid_file_path)"
stop_background_script "$(health_pid_file_path)"

printf 'Background workers stopped\n'
