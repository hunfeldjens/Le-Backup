#!/usr/bin/env bash

function backup_files() {
  local source pattern
  local excludes=()
  source="$(job_get source)"
  Message "$JOB_NAME: Quellpfad: $source"
  Message "$JOB_NAME: Packe die Quelldaten ($ARCHIVE). Anwendungen laufen weiter."
  while IFS= read -r -d '' pattern; do
    if [[ "$ARCHIVE" == zip ]]; then
      excludes+=("$pattern")
    else
      excludes+=("--exclude=$pattern")
    fi
  done < <(job_list exclude)
  archive_create "$source" "$PARTIAL" "$ARCHIVE" "${excludes[@]+${excludes[@]}}"
}
