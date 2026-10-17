#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
if [[ ! -d "$TASK_ROOT/dist/DualSpace.app" ]]; then
    "$TASK_ROOT/scripts/build.sh"
fi
open "$TASK_ROOT/dist/DualSpace.app"
