#!/usr/bin/env bash

function backup_software() {
  local path destination other covered
  local paths=()
  Message "$JOB_NAME: Stelle die nativen Software-Konfigurationen zusammen."

  while IFS= read -r -d '' path; do
    paths+=("$path")
  done < <(job_list paths)

  while IFS= read -r -d '' path; do
    if [[ -e "$path" ]]; then
      paths+=("$path")
    else
      warningMessage "$JOB_NAME: Optionaler Software-Pfad nicht vorhanden, wird übersprungen: $path"
    fi
  done < <(job_list optional_paths)

  (( ${#paths[@]} > 0 )) || die 'Kein konfigurierter Software-Pfad vorhanden.'
  mkdir -- "$WORK/data"
  mkdir -- "$WORK/data/files"

  for path in "${paths[@]}"; do
    [[ -r "$path" && ( -f "$path" || -d "$path" ) ]] || die "Software-Pfad fehlt oder ist nicht lesbar: $path"

    covered=false

    for other in "${paths[@]}"; do
      if [[ "$path" == "$other/"* ]]; then
        covered=true
        break
      fi
    done

    [[ "$covered" == false ]] || continue

    destination="$WORK/data/files$path"
    mkdir -p -- "$(dirname -- "$destination")"
    if [[ ! -e "$destination" ]]; then
      cp -a -- "$path" "$destination"
    fi
  done

  Message "$JOB_NAME: Packe die gesammelten Konfigurationen ($ARCHIVE)."
  archive_create "$WORK/data" "$PARTIAL" "$ARCHIVE"
}
