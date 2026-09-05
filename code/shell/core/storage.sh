#!/usr/bin/env bash

LEGACY_ARCHIVE_PATTERN='^([A-Za-z0-9][A-Za-z0-9_-]*)_([0-9]{8})T([0-9]{6})Z-([0-9]{1,10})\.(zip|tar(\.(gz|bz2|zst))?)(\.age)?$'
DATED_ARCHIVE_PATTERN='^([0-9]{4}-[0-9]{2}-[0-9]{2})-([1-9][0-9]{0,8})-([A-Za-z0-9][A-Za-z0-9_-]*)\.(zip|tar(\.(gz|bz2|zst))?)(\.age)?$'
ENCRYPTED_ARCHIVE_PATTERN='\.(zip|tar(\.(gz|bz2|zst))?)\.age$'
LEGACY_METADATA_FORMAT=le-backup-manager-6.3
ENCRYPTED_METADATA_FORMAT=le-backup-manager-6.3-age
ARCHIVE_ENCRYPTION=age

function managed_name() {
  [[ "$1" =~ $DATED_ARCHIVE_PATTERN || "$1" =~ $LEGACY_ARCHIVE_PATTERN ]]
}

function encrypted_name() {
  [[ "$1" =~ $ENCRYPTED_ARCHIVE_PATTERN ]]
}

function archive_sort_record() {
  local filename="$1"
  local job="$2"
  local day number

  if [[ "$filename" =~ $DATED_ARCHIVE_PATTERN ]]; then
    [[ "${BASH_REMATCH[3]}" == "$job" ]] || return 1
    day="${BASH_REMATCH[1]//-/}"
    number="${BASH_REMATCH[2]}"
    printf '%s1%09d\t%s\n' "$day" "$number" "$filename"
  elif [[ "$filename" =~ $LEGACY_ARCHIVE_PATTERN ]]; then
    [[ "${BASH_REMATCH[1]}" == "$job" ]] || return 1
    printf '%s0%s%010d\t%s\n' \
      "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$((10#${BASH_REMATCH[4]}))" "$filename"
  else
    return 1
  fi
}

function managed_job_name() {
  archive_sort_record "$1" "$2" >/dev/null
}

function sort_archive_names() {
  local job="$1"
  local filename
  shift

  for filename in "$@"; do
    archive_sort_record "$filename" "$job" || return 1
  done | LC_ALL=C sort -ru | cut -f 2
}

function file_owner() {
  stat -c '%u' -- "$1" 2>/dev/null || stat -f '%u' "$1"
}

function file_mode() {
  stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

function file_links() {
  stat -c '%h' -- "$1" 2>/dev/null || stat -f '%l' "$1"
}

function storage_checksum() {
  local checksum

  if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum -- "$1")"
  else
    checksum="$(shasum -a 256 -- "$1")"
  fi

  printf '%s\n' "${checksum%% *}"
}

function private_directory() {
  local directory="$1"
  local parent="$directory"

  while [[ "$parent" != / && "$parent" != . ]]; do
    [[ ! -L "$parent" ]] || die "Zielordner dürfen keine Symlinks enthalten: $parent"
    parent="$(dirname -- "$parent")"
  done

  mkdir -p -- "$directory"
  [[ "$(file_owner "$directory")" == "$(id -u)" ]] || die "Zielordner gehört einem anderen Benutzer: $directory"
  chmod 700 "$directory"
}

function storage_next_filename() {
  local directory="$1"
  local name="$2"
  local extension="$3"
  local category="$4"
  local day="$BACKUP_DATE"
  local counter_directory="$ROOT/state/names/$category/$day"
  local counter="$counter_directory/$name.counter"
  local number=0 filename temporary

  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die 'Ungültiges Backup-Datum.'
  private_directory "$counter_directory"

  if [[ -e "$counter" || -L "$counter" ]]; then
    [[ -f "$counter" && ! -L "$counter" ]] || die 'Ungültige Backup-Laufnummerdatei.'
    [[ "$(file_owner "$counter")" == "$(id -u)" && "$(file_links "$counter")" == 1 ]] || die 'Unsichere Backup-Laufnummerdatei.'
    IFS= read -r number < "$counter" || die 'Backup-Laufnummer ist nicht lesbar.'
    [[ "$number" =~ ^[1-9][0-9]{0,8}$ ]] || die 'Ungültige gespeicherte Backup-Laufnummer.'
  fi

  while true; do
    (( number < 999999999 )) || die 'Maximale Anzahl täglicher Backups erreicht.'
    number=$((number + 1))
    filename="$day-$number-$name.$extension"
    if [[ ! -e "$directory/$filename" && ! -L "$directory/$filename" && \
          ! -e "$directory/$filename.meta.json" && ! -L "$directory/$filename.meta.json" ]]; then
      break
    fi
  done

  # Die reservierte Nummer bleibt auch nach lokaler Löschung oder einem Abbruch erhalten.
  temporary="$(mktemp "$counter_directory/.counter.XXXXXX")"
  printf '%s\n' "$number" > "$temporary"
  mv -- "$temporary" "$counter"
  printf '%s\n' "$filename"
}

function storage_check_space() {
  local directory="$1"
  local minimum_mb="$2"
  local available_kb

  available_kb="$(df -Pk "$directory" | awk 'NR == 2 { print $4 }')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || die "Freier Speicher konnte nicht ermittelt werden."
  (( available_kb >= minimum_mb * 1024 )) || die "Zu wenig freier Speicher für einen neuen Backup-Lauf."
}

function storage_complete() {
  local file="$1"
  local job="$2"
  local archive_format="$3"
  local checksum bytes filename

  filename="$(basename -- "$file")"
  managed_job_name "$filename" "$job" || die "Ungültiger Archivname."
  [[ -f "$file" && ! -L "$file" ]] || die "Archiv fehlt oder ist ein Symlink."

  checksum="$(storage_checksum "$file")"
  bytes="$(stat -c '%s' -- "$file" 2>/dev/null || stat -f '%z' "$file")"

  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" json \
    format "$ENCRYPTED_METADATA_FORMAT" job "$job" archive "$filename" \
    encryption "$ARCHIVE_ENCRYPTION" archive_format "$archive_format" \
    sha256 "$checksum" bytes "$bytes" completed_at "$(date -u '+%FT%TZ')" > "$file.meta.json.tmp"

  mv -- "$file.meta.json.tmp" "$file.meta.json"
}

function storage_prune() {
  local directory="$1"
  local job="$2"
  local keep="$3"
  local file filename metadata format listing count=0
  local candidates=()

  for file in "$directory"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    filename="$(basename -- "$file")"
    managed_job_name "$filename" "$job" || continue

    metadata="$file.meta.json"
    [[ -f "$metadata" && ! -L "$metadata" ]] || continue
    format="$(json_get "$metadata" format)"
    case "$format" in
      "$LEGACY_METADATA_FORMAT") ;;
      "$ENCRYPTED_METADATA_FORMAT")
        encrypted_name "$filename" || continue
        [[ "$(json_get "$metadata" encryption)" == "$ARCHIVE_ENCRYPTION" ]] || continue ;;
      *) continue ;;
    esac
    [[ "$(json_get "$metadata" job)" == "$job" ]] || continue
    [[ "$(json_get "$metadata" archive)" == "$filename" ]] || continue

    candidates+=("$filename")
  done

  (( ${#candidates[@]} > keep )) || return 0
  listing="$(sort_archive_names "$job" "${candidates[@]}")" || return 1

  while IFS= read -r filename; do
    count=$((count + 1))
    (( count > keep )) || continue

    rm -f -- "$directory/$filename" "$directory/$filename.meta.json" || return 1
    Message "Altes Backup entfernt: $filename"
  done <<< "$listing"
}

function storage_cleanup() {
  local directory="$1"
  local filename

  filename="$(basename -- "$directory")"
  [[ "$filename" == .incomplete-* && -d "$directory" && ! -L "$directory" ]] || return 1
  rm -rf -- "$directory"
}

function storage_status() {
  local result="$1"
  local failures="$2"
  local status_file="$ROOT/state/run-$RUN_ID.json"
  local temporary

  temporary="$(mktemp "$ROOT/state/.status.XXXXXX")"

  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" json \
    run_id "$RUN_ID" result "$result" failures "$failures" \
    time "$(date -u '+%FT%TZ')" log_file "$LOG_FILE" \
    phase "${CURRENT_PHASE:-}" current_job "${CURRENT_JOB:-}" \
    completed_jobs "${COMPLETED_JOBS:-0}" total_jobs "${BACKUP_TOTAL:-0}" \
    completed_transfers "${COMPLETED_TRANSFERS:-0}" total_transfers "${TRANSFERS:-0}" > "$temporary"

  mv -- "$temporary" "$status_file"
  temporary="$(mktemp "$ROOT/state/.status.XXXXXX")"
  cp -- "$status_file" "$temporary"
  mv -- "$temporary" "$ROOT/state/latest.json"
}
