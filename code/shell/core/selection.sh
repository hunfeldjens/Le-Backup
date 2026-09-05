#!/usr/bin/env bash

function check_archive_metadata() {
  local source="$1"
  local filename="$2"
  local job="$3"
  local archive="$source/$filename"
  local metadata="$archive.meta.json"
  local format

  managed_job_name "$filename" "$job" || return 1
  [[ -f "$archive" && ! -L "$archive" ]] || return 1
  [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
  [[ "$(json_get "$metadata" archive)" == "$filename" ]] || return 1
  [[ "$(json_get "$metadata" job)" == "$job" ]] || return 1
  format="$(json_get "$metadata" format)"

  case "$format" in
    "$LEGACY_METADATA_FORMAT") return 0 ;;
    "$ENCRYPTED_METADATA_FORMAT")
      encrypted_name "$filename" || return 1
      [[ "$(json_get "$metadata" encryption)" == "$ARCHIVE_ENCRYPTION" ]] ;;
    *) return 1 ;;
  esac
}

function check_encrypted_archive_metadata() {
  local source="$1"
  local filename="$2"
  local job="$3"
  local metadata="$source/$filename.meta.json"

  check_archive_metadata "$source" "$filename" "$job" || return 1
  encrypted_name "$filename" || return 1
  [[ "$(json_get "$metadata" format)" == "$ENCRYPTED_METADATA_FORMAT" ]]
}

function select_transfers() {
  local source="$1"
  local job="$2"
  local keep="$3"
  local file filename listing count=0
  local candidates=()

  [[ -d "$source" && ! -L "$source" ]] || die 'Rsync-Quelle fehlt oder ist ein Symlink.'

  for file in "$source"/*; do
    filename="$(basename -- "$file")"
    check_encrypted_archive_metadata "$source" "$filename" "$job" || continue
    candidates+=("$filename")
  done

  (( ${#candidates[@]} > 0 )) || die 'Keine fertigen verschlüsselten Backups dieses Jobs gefunden.'
  listing="$(sort_archive_names "$job" "${candidates[@]}")"

  while IFS= read -r filename; do
    count=$((count + 1))
    (( count <= keep )) || break

    printf '%s\0%s.meta.json\0' "$filename" "$filename"
  done <<< "$listing"
}

function select_remote_deletions() {
  local listing_file="$1"
  local job="$2"
  local keep="$3"
  local filename listing count=0
  local candidates=()

  while IFS= read -r filename; do
    managed_job_name "$filename" "$job" || continue
    candidates+=("$filename")
  done < "$listing_file"

  (( ${#candidates[@]} > keep )) || return 0
  listing="$(sort_archive_names "$job" "${candidates[@]}")"

  while IFS= read -r filename; do
    count=$((count + 1))

    if (( count > keep )); then
      printf '%s\0' "$filename"
    fi
  done <<< "$listing"
}
