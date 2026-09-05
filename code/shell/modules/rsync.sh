#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
PLAN="$1"
INDEX="$2"
source "$ROOT/code/shell/core/common.sh"
source "$ROOT/code/shell/core/storage.sh"
source "$ROOT/code/shell/core/selection.sh"
require_root

function transfer_get() {
  config_get "transfers.$INDEX.$1"
}

function remote() {
  bash "$ROOT/code/shell/core/ssh.sh" "$1" "$CREDENTIALS" "${@:2}"
}

function verify_local_archives() {
  local filename checksum

  while IFS= read -r -d '' filename; do
    managed_name "$filename" || continue
    check_archive_metadata "$SOURCE" "$filename" "$JOB_NAME" || die 'Archiv wurde verändert. Keine lokale Löschung.'
    checksum="$(storage_checksum "$SOURCE/$filename")"
    if [[ "$checksum" != "$(json_get "$SOURCE/$filename.meta.json" sha256)" ]]; then
      die 'Lokale Prüfsumme stimmt nicht. Übertragung und Löschung abgebrochen.'
    fi
  done < "$WORK/selection"
}

function transfer_cleanup() {
  local result=$?
  trap - EXIT INT TERM HUP

  if (( result != 0 )); then
    redMessage "Rsync $JOB_NAME: $TRANSFER_PHASE fehlgeschlagen (Exitcode $result)."
  fi
  if [[ -n "$WORK" ]]; then
    if ! storage_cleanup "$WORK"; then
      redMessage "Rsync $JOB_NAME: Temporäre Arbeitsdateien konnten nicht entfernt werden."
      if (( result == 0 )); then
        result=1
      fi
    fi
  fi
  exit "$result"
}

JOB_NAME="Job $INDEX"
WORK=""
TRANSFER_PHASE='Verbindungseinstellungen laden'
trap transfer_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

SOURCE="$(transfer_get source)"
DESTINATION="$(transfer_get destination)"
JOB_NAME="$(transfer_get job)"
KEEP="$(transfer_get keep_backups)"
DRY_RUN="$(transfer_get dry_run)"
DELETE_LOCAL="$(transfer_get delete_local_after_transfer)"
CREDENTIALS="$(transfer_get credentials_file)"
ADDRESS="$(remote address)"
TRANSPORT="$(remote transport)"
OPTIONS=(
  --archive
  --checksum
  --recursive
  --safe-links
  --protect-args
  --delay-updates
  --partial-dir=.rsync-partial
  --chmod=Du=rwx,Dgo=,Fu=rw,Fgo=
  "--timeout=$(transfer_get timeout_seconds)"
  -e "$TRANSPORT"
)

WORK="$(mktemp -d "$ROOT/state/.incomplete-transfer.XXXXXX")"

if [[ "$DRY_RUN" == true ]]; then
  OPTIONS+=(--dry-run)
fi

TRANSFER_PHASE='Fertige Archive auswählen'
select_transfers "$SOURCE" "$JOB_NAME" "$KEEP" > "$WORK/selection"
OPTIONS+=(--from0 "--files-from=$WORK/selection")
ARCHIVE_COUNT=0
while IFS= read -r -d '' filename; do
  if managed_name "$filename"; then
    ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))
  fi
done < "$WORK/selection"
Message "$JOB_NAME: $ARCHIVE_COUNT fertige Archive für Rsync ausgewählt."

if [[ "$DELETE_LOCAL" == true ]]; then
  TRANSFER_PHASE='Lokale Prüfsummen vor der Übertragung prüfen'
  Message "$JOB_NAME: Prüfe lokale SHA-256-Prüfsummen vor der Übertragung."
  verify_local_archives
fi

if [[ "$DRY_RUN" == false ]]; then
  TRANSFER_PHASE='SSH-Verbindung und Remote-Ordner vorbereiten'
  Message "$JOB_NAME: Verbinde per SSH und bereite den Remote-Ordner vor."
  remote mkdir "$DESTINATION"
fi
TRANSFER_PHASE='Rsync-Upload'
Message "$JOB_NAME: Starte Rsync nach $DESTINATION (Testlauf: $DRY_RUN)."
rsync "${OPTIONS[@]}" --ignore-existing -- "${SOURCE%/}/" "$ADDRESS:$DESTINATION/"

if [[ "$DRY_RUN" == true ]]; then
  Message "TESTLAUF: Keine Remote-Ordner angelegt und keine Backups gelöscht."
  exit 0
fi

# Gleiche Namen dürfen nach einer Neuinstallation keine Remote-Archive überschreiben.
TRANSFER_PHASE='Remote-Prüfsummenvergleich'
Message "$JOB_NAME: Upload beendet. Vergleiche die lokalen und entfernten Archive per Prüfsumme."
rsync "${OPTIONS[@]}" --dry-run --out-format='%i %n' -- \
  "${SOURCE%/}/" "$ADDRESS:$DESTINATION/" > "$WORK/verification"
if [[ -s "$WORK/verification" ]]; then
  while IFS= read -r difference; do
    redMessage "$JOB_NAME: Remote-Abweichung: $difference"
  done < "$WORK/verification"
  die 'Remote-Vergleich meldet Unterschiede oder eine Namenskollision. Lokale Archive bleiben erhalten.'
fi

Message "$JOB_NAME: Remote-Vergleich erfolgreich. Prüfe die Aufbewahrung auf dem Storage-Server."
TRANSFER_PHASE='Remote-Archive auflisten'
remote listing "$DESTINATION" > "$WORK/listing"
TRANSFER_PHASE='Remote-Aufbewahrung prüfen'
select_remote_deletions "$WORK/listing" "$JOB_NAME" "$KEEP" > "$WORK/old"

while IFS= read -r -d '' old; do
  protected=false
  while IFS= read -r -d '' selected; do
    if [[ "$old" == "$selected" ]]; then
      protected=true
      break
    fi
  done < "$WORK/selection"
  [[ "$protected" == false ]] || continue

  TRANSFER_PHASE='Alte Remote-Archive entfernen'
  remote remove-file "$DESTINATION" "$old"
  Message "Altes Remote-Backup entfernt: $old"
done < "$WORK/old"

if [[ "$DELETE_LOCAL" == true ]]; then
  TRANSFER_PHASE='Lokale Prüfsummen nach der Übertragung prüfen'
  Message "$JOB_NAME: Übertragung erfolgreich. Prüfe und entferne die übertragenen lokalen Kopien."
  verify_local_archives

  TRANSFER_PHASE='Übertragene lokale Kopien entfernen'
  while IFS= read -r -d '' filename; do
    managed_name "$filename" || continue
    rm -- "$SOURCE/$filename" "$SOURCE/$filename.meta.json"
    Message "Übertragen und geprüft; lokale Kopie entfernt: $filename"
  done < "$WORK/selection"
else
  Message "$JOB_NAME: Die lokalen Archive bleiben erhalten."
fi
