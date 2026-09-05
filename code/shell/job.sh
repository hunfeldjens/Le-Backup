#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PLAN="$1"
JOB_INDEX="$2"
RUN_ID="$3"
source "$ROOT/code/shell/core/common.sh"
require_root
source "$ROOT/code/shell/core/storage.sh"
source "$ROOT/code/shell/modules/files.sh"
source "$ROOT/code/shell/modules/mysql.sh"
source "$ROOT/code/shell/modules/docker.sh"
source "$ROOT/code/shell/modules/software.sh"
source "$ROOT/code/shell/modules/full-server.sh"

JOB_NAME="$(job_get name)"
TYPE="$(job_get type)"
ARCHIVE="$(job_get archiving_method)"
TARGET="$(config_get general_settings.backup_directory)/$JOB_NAME"
RECIPIENT_FILE="$(config_get encryption.recipient_file)"
private_directory "$TARGET"
storage_check_space "$TARGET" "$(config_get general_settings.minimum_free_mb)"
FILENAME="$(storage_next_filename "$TARGET" "$JOB_NAME" "$ARCHIVE.age" archives)"
WORK="$(mktemp -d "$TARGET/.incomplete-$RUN_ID.XXXXXX")"
PARTIAL="$WORK/${FILENAME%.age}"
ENCRYPTED="$WORK/$FILENAME"

function job_cleanup() {
  local result=$?
  trap - EXIT INT TERM HUP
  storage_cleanup "$WORK" || result=1
  if (( result != 0 )); then
    redMessage "Job $JOB_NAME wurde mit Exitcode $result abgebrochen."
  fi
  exit "$result"
}

trap job_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

Message "$JOB_NAME: Erstelle $FILENAME."
case "$TYPE" in
  files) backup_files ;;
  mysql) backup_mysql ;;
  docker) backup_docker ;;
  software) backup_software ;;
  full-server) backup_full_server ;;
esac
Message "$JOB_NAME: Prüfe das erstellte Archiv."
archive_verify "$PARTIAL" "$ARCHIVE"
Message "$JOB_NAME: Verschlüssele das geprüfte Archiv mit age."
age --encrypt --recipients-file "$RECIPIENT_FILE" --output "$ENCRYPTED" "$PARTIAL"
[[ -s "$ENCRYPTED" ]] || die 'Das verschlüsselte Archiv ist leer.'
rm -- "$PARTIAL"
FINAL="$TARGET/$FILENAME"
[[ ! -e "$FINAL" && ! -L "$FINAL" ]] || die 'Archivziel existiert bereits. Es wird nichts überschrieben.'
mv -- "$ENCRYPTED" "$FINAL"
Message "$JOB_NAME: Berechne die SHA-256-Prüfsumme und schreibe die Begleitdatei."
storage_complete "$FINAL" "$JOB_NAME" "$ARCHIVE"
Message "$JOB_NAME: Archiv fertig und geprüft: $FILENAME"
