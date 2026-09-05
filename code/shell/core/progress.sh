#!/usr/bin/env bash

function relay_line() {
  local context="$1"
  local line="$2"

  [[ -n "$line" ]] || return 0
  if [[ "$line" == '[Le-Backup] '* ]]; then
    printf '%s\n' "$line" || return 1
    if [[ -n "${LOG_FILE:-}" ]]; then
      printf '%s\n' "$line" >> "$LOG_FILE" || return 1
    fi
    return 0
  fi

  case "$line" in
    *[Ww]arning*|*WARN*|*Warnung*|HINWEIS:*) warningMessage "$context: $line" ;;
    *[Ee]rror*|*[Ff]ehler*|*FEHLER*|*[Ff]ailed*|*[Dd]enied*) redMessage "$context: $line" ;;
    *) log_message AUSGABE "$context: $line" ;;
  esac || return 1

  if [[ "$line" == *'Host key verification failed'* ]]; then
    warningMessage "$context: SSH konnte die Server-Identität nicht bestätigen. Einmalig ausführen: bash create-backup.sh --setup-ssh-host"
  fi
}

function relay_output() {
  local context="$1"
  local started=$SECONDS
  local last_update=$SECONDS
  local line buffer="" result elapsed read_started
  local read_options=(-r -t 1)

  # Bash 3 verwirft Teilzeilen bei einem Timeout; dort einzelne Zeichen lesen.
  if (( BASH_VERSINFO[0] < 4 )); then
    read_options+=(-n 1)
  fi

  while true; do
    line=""
    read_started=$SECONDS
    if IFS= read "${read_options[@]}" line; then
      if (( BASH_VERSINFO[0] < 4 )) && [[ -n "$line" ]]; then
        buffer+="$line"
      else
        relay_line "$context" "$buffer$line" || return 1
        buffer=""
      fi
    else
      result=$?
      buffer+="$line"
      # Bash 3 meldet auch einen Timeout mit Exitcode 1 statt mit > 128.
      if (( result <= 128 )) && ! (( BASH_VERSINFO[0] < 4 && SECONDS > read_started )); then
        relay_line "$context" "$buffer" || return 1
        break
      fi
    fi

    if (( PROGRESS_INTERVAL > 0 && SECONDS - last_update >= PROGRESS_INTERVAL )); then
      elapsed=$((SECONDS - started))
      Message "$context ist noch aktiv; Laufzeit: ${elapsed} Sekunden." || return 1
      last_update=$SECONDS
    fi
  done
}

function run_logged() {
  local context="$1"
  shift
  LOG_FILE= "$@" 2>&1 | relay_output "$context"
}
