#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/code/shell/core/common.sh"
source "$ROOT/code/shell/core/storage.sh"
source "$ROOT/code/shell/core/preflight.sh"
source "$ROOT/code/shell/core/dependencies.sh"
source "$ROOT/code/shell/core/multiplexer.sh"
source "$ROOT/code/shell/core/progress.sh"
require_root

FOREGROUND=false
WAIT=false
CHECK=false
LIST=false
RSYNC_ONLY=false
TYPE=""
CONFIG=""
SELECTORS=()
ORIGINAL_ARGS=("$@")

while (( $# > 0 )); do
  case "$1" in
    --foreground) FOREGROUND=true ;;
    --wait) WAIT=true ;;
    --check) CHECK=true ;;
    --list) LIST=true ;;
    --status)
      if [[ -f "$ROOT/state/latest.json" ]]; then
        "$BACKUP_PYTHON" -m json.tool "$ROOT/state/latest.json"
      else
        printf 'Bisher kein Backup-Lauf vorhanden.\n'
      fi
      exit 0 ;;
    --rsync-only) RSYNC_ONLY=true ;;
    --full-server) SELECTORS+=(Root-Server) ;;
    --config|--type)
      (( $# >= 2 )) || die "Wert für $1 fehlt."
      if [[ "$1" == --config ]]; then
        CONFIG="$2"
      else
        TYPE="$2"
        case "$TYPE" in files|mysql|docker|software) ;; *) die "--type: files, mysql, docker oder software angeben." ;; esac
      fi
      shift ;;
    --*) die "Unbekannte Option: $1" ;;
    -*) SELECTORS+=("${1#-}") ;;
    *) die "Jobauswahl mit Bindestrich angeben, beispielsweise -ApplicationData." ;;
  esac
  shift
done

require_command "$BACKUP_PYTHON"
"$BACKUP_PYTHON" -c 'import yaml' 2>/dev/null || die "PyYAML fehlt (Debian/Ubuntu: python3-yaml)."
PLAN="$(mktemp "$ROOT/state/.plan.XXXXXX")"
trap 'rm -f -- "$PLAN"' EXIT
CONFIG_ACTION=plan

if [[ "$LIST" == true ]]; then
  CONFIG_ACTION=inventory
fi

"$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" "$CONFIG_ACTION" "$ROOT" "$CONFIG" "$TYPE" \
  "${SELECTORS[@]+${SELECTORS[@]}}" > "$PLAN"
COUNT="$(config_length jobs)"
TRANSFERS="$(config_length transfers)"
BACKUP_TOTAL="$COUNT"
if [[ "$RSYNC_ONLY" == true ]]; then
  BACKUP_TOTAL=0
fi

if [[ "$LIST" == true ]]; then
  for (( index=0; index<COUNT; index++ )); do
    printf '%-25s %-8s aktiv=%s\n' \
      "$(config_get "jobs.$index.name")" \
      "$(config_get "jobs.$index.type")" \
      "$(config_get "jobs.$index.enabled")"
  done

  for (( index=0; index<TRANSFERS; index++ )); do
    printf '%-25s rsync\n' "$(config_get "transfers.$index.job")"
  done
  exit 0
fi

dependencies_plan
if [[ "$RSYNC_ONLY" == false ]]; then
  preflight_jobs
fi

preflight_transfers
Message 'Vorprüfung erfolgreich.'
if [[ "$CHECK" == true ]]; then
  exit 0
fi

if [[ "$RSYNC_ONLY" == true ]]; then
  (( TRANSFERS > 0 )) || die 'Keine aktiven Rsync-Ziele ausgewählt. rsync.enabled beim Job prüfen.'
else
  (( COUNT > 0 )) || die "Keine aktiven Jobs für diese Auswahl."
fi

MULTIPLEXER="$(config_get general_settings.multiplexer)"
SESSION="$(config_get general_settings.session_name)"
SOCKET="$ROOT/state/tmux.sock"
SCREEN_DIRECTORY="$ROOT/state/screen"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"

if [[ "$FOREGROUND" == false ]]; then
  multiplexer_start "${ORIGINAL_ARGS[@]+${ORIGINAL_ARGS[@]}}"
  if [[ "$WAIT" == true ]]; then
    # Der Worker übernimmt die Laufsperre; das Warten hält sie nicht fest.
    rm -f -- "$PLAN"
    trap - EXIT
    exec 9>&-
    exec bash "$ROOT/code/shell/core/wait.sh" "$RUN_ID" "$SESSION" "$MULTIPLEXER"
  fi
  exit 0
fi

RUN_ID="${BACKUP_RUN_ID:-$RUN_ID}"
[[ "$RUN_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die 'Ungültige Laufkennung.'
export BACKUP_DATE="$(date '+%F')"
LOG_FILE=""
export -n LOG_FILE
PROGRESS_INTERVAL="$(config_get general_settings.progress_interval_seconds)"
if [[ "$(config_get general_settings.write_logs)" == true ]]; then
  LOG_DIR="$(config_get general_settings.log_directory)"
  private_directory "$LOG_DIR"
  LOG_FILE="$LOG_DIR/$(storage_next_filename "$LOG_DIR" backup log logs)"
  [[ ! -e "$LOG_FILE" && ! -L "$LOG_FILE" ]] || die "Logdatei existiert bereits."
  : > "$LOG_FILE"
fi
FAILURES=0
FINISHED=false
CURRENT_PHASE=preparation
CURRENT_JOB=""
COMPLETED_JOBS=0
COMPLETED_TRANSFERS=0

function manager_cleanup() {
  local result=$?
  trap - EXIT INT TERM HUP
  if [[ "$FINISHED" == false ]]; then
    redMessage "Backup-Lauf abgebrochen (Phase: $CURRENT_PHASE, Job: ${CURRENT_JOB:-keiner}, Exitcode $result)."
    storage_status aborted 1 || redMessage 'Abbruchstatus konnte nicht gespeichert werden.'
  fi
  rm -f -- "$PLAN"
  exit "$result"
}

trap manager_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
storage_status running 0
Message 'Backup-Lauf gestartet.'
Message "Auswahl: $BACKUP_TOTAL Backup-Jobs und $TRANSFERS Rsync-Ziele."
if [[ -n "$LOG_FILE" ]]; then
  Message "Laufprotokoll: $LOG_FILE"
else
  warningMessage 'Dateiprotokoll ausgeschaltet: Ausgaben erscheinen nur in der Konsole.'
fi
if [[ "$RSYNC_ONLY" == true ]]; then
  Message 'Nur Rsync: Es werden keine neuen Archive erstellt.'
elif (( TRANSFERS > 0 )); then
  Message 'Zuerst werden alle ausgewählten Backups erstellt. Rsync startet erst danach, wenn kein Backup fehlgeschlagen ist.'
else
  Message 'Rsync ist für diese Auswahl nicht aktiviert. Die Backups bleiben lokal.'
fi
SUCCESSFUL=()

if [[ "$RSYNC_ONLY" == false ]]; then
  for (( index=0; index<COUNT; index++ )); do
    JOB_NAME="$(config_get "jobs.$index.name")"
    CURRENT_PHASE=backup
    CURRENT_JOB="$JOB_NAME"
    storage_status running "$FAILURES"
    Message "Backup [$((index + 1))/$COUNT]: Starte $JOB_NAME ($(config_get "jobs.$index.type"))"
    if run_logged "Backup $JOB_NAME" bash "$ROOT/code/shell/job.sh" "$PLAN" "$index" "$RUN_ID"; then
      SUCCESSFUL+=("$index")
      COMPLETED_JOBS=$((COMPLETED_JOBS + 1))
      Message "Backup erfolgreich: $JOB_NAME ($COMPLETED_JOBS/$COUNT Jobs erfolgreich abgeschlossen)."
    else
      ERROR_CODE=$?
      FAILURES=$((FAILURES + 1))
      redMessage "Backup $JOB_NAME fehlgeschlagen (Exitcode $ERROR_CODE). Siehe die Meldungen dieses Schritts."
      if [[ "$(config_get general_settings.continue_on_error)" == false ]]; then
        break
      fi
    fi
  done
fi

if (( FAILURES == 0 )); then
  for (( index=0; index<TRANSFERS; index++ )); do
    CURRENT_PHASE=rsync
    CURRENT_JOB="$(config_get "transfers.$index.job")"
    storage_status running "$FAILURES"
    Message "Rsync [$((index + 1))/$TRANSFERS]: Starte Übertragung für $CURRENT_JOB."
    if run_logged "Rsync $CURRENT_JOB" bash "$ROOT/code/shell/modules/rsync.sh" "$PLAN" "$index"; then
      COMPLETED_TRANSFERS=$((COMPLETED_TRANSFERS + 1))
      Message "Rsync erfolgreich: $CURRENT_JOB ($COMPLETED_TRANSFERS/$TRANSFERS Übertragungen abgeschlossen)."
    else
      ERROR_CODE=$?
      FAILURES=$((FAILURES + 1))
      redMessage "Rsync $CURRENT_JOB fehlgeschlagen (Exitcode $ERROR_CODE). Lokale Archive bleiben erhalten."
      if [[ "$(config_get general_settings.continue_on_error)" == false ]]; then
        break
      fi
    fi
  done
else
  warningMessage 'Rsync und Aufbewahrungsbereinigung wegen Backup-Fehlern übersprungen.'
fi

if (( FAILURES == 0 )); then
  CURRENT_PHASE=retention
  CURRENT_JOB=""
  storage_status running 0
  Message 'Aufbewahrung: Prüfe die Anzahl der lokalen Backups.'
  for index in "${SUCCESSFUL[@]+${SUCCESSFUL[@]}}"; do
    JOB_NAME="$(config_get "jobs.$index.name")"
    if ! run_logged "Aufbewahrung $JOB_NAME" storage_prune \
      "$(config_get general_settings.backup_directory)/$JOB_NAME" "$JOB_NAME" \
      "$(config_get "jobs.$index.max_backups")"; then
      FAILURES=$((FAILURES + 1))
      redMessage "Lokale Aufbewahrungsbereinigung für $JOB_NAME fehlgeschlagen."
    fi
  done
fi

RESULT=success
if (( FAILURES > 0 )); then
  RESULT=failed
fi

CURRENT_PHASE=finished
CURRENT_JOB=""
storage_status "$RESULT" "$FAILURES"
FINISHED=true
if (( FAILURES == 0 )); then
  Message "Backup-Lauf erfolgreich beendet: $COMPLETED_JOBS Backups, $COMPLETED_TRANSFERS Übertragungen."
else
  redMessage "Backup-Lauf mit $FAILURES Fehlern beendet."
fi
(( FAILURES == 0 ))
