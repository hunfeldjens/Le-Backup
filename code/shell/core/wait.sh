#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source "$ROOT/code/shell/core/common.sh"
source "$ROOT/code/shell/core/multiplexer.sh"
require_root

RUN_ID="$1"
SESSION="$2"
MULTIPLEXER="$3"
SOCKET="$ROOT/state/tmux.sock"
SCREEN_DIRECTORY="$ROOT/state/screen"
STATUS_FILE="$ROOT/state/run-$RUN_ID.json"

while true; do
  if [[ -f "$STATUS_FILE" ]]; then
    RESULT="$(json_get "$STATUS_FILE" result)"

    if [[ "$RESULT" != running ]]; then
      Message "Backup beendet: $RESULT"
      [[ "$RESULT" == success ]]
      exit $?
    fi
  fi

  if ! multiplexer_alive; then
    if [[ -f "$STATUS_FILE" && "$(json_get "$STATUS_FILE" result)" == success ]]; then
      exit 0
    fi

    die "$MULTIPLEXER endete ohne erfolgreiches Backup-Ergebnis."
  fi

  sleep 1
done
