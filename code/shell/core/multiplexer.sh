#!/usr/bin/env bash

function multiplexer_alive() {
  if [[ "$MULTIPLEXER" == tmux ]]; then
    tmux -S "$SOCKET" has-session -t "=$SESSION" >/dev/null 2>&1
  else
    SCREENDIR="$SCREEN_DIRECTORY" screen -S "$SESSION" -Q windows >/dev/null 2>&1
  fi
}

function multiplexer_start() {
  local command=(
    env "BACKUP_PYTHON=$BACKUP_PYTHON" "PATH=$PATH" "BACKUP_RUN_ID=$RUN_ID"
    bash "$ROOT/create-backup.sh" --worker "$@"
  )

  require_command "$MULTIPLEXER"

  if multiplexer_alive; then
    die "Die $MULTIPLEXER-Session $SESSION läuft bereits."
  fi

  if [[ "$MULTIPLEXER" == tmux ]]; then
    tmux -S "$SOCKET" -f /dev/null new-session -d -s "$SESSION" -c "$ROOT" "${command[@]}" 9>&-
    printf 'Ansehen: tmux -S %q attach -t %q\n' "$SOCKET" "$SESSION"
  else
    private_directory "$SCREEN_DIRECTORY"
    (
      cd -- "$ROOT"
      SCREENDIR="$SCREEN_DIRECTORY" SYSSCREENRC=/dev/null \
        screen -c /dev/null -d -m -S "$SESSION" "${command[@]}" 9>&-
    )
    printf 'Ansehen: SCREENDIR=%q screen -r %q\n' "$SCREEN_DIRECTORY" "$SESSION"
  fi

  Message "Backup in $MULTIPLEXER gestartet: $SESSION"
}
