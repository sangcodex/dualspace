#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
if [[ -x "$TASK_ROOT/.build/release/dualspace-cli" ]]; then
    CLI="$TASK_ROOT/.build/release/dualspace-cli"
elif [[ -x "$TASK_ROOT/.build/debug/dualspace-cli" ]]; then
    CLI="$TASK_ROOT/.build/debug/dualspace-cli"
else
    "$TASK_ROOT/scripts/build.sh"
    CLI="$TASK_ROOT/.build/release/dualspace-cli"
fi
export DUALSPACE_HOME="${DUALSPACE_HOME:-$TASK_ROOT/.local}"
exec "$CLI" "$@"
