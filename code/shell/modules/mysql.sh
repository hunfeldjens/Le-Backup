#!/usr/bin/env bash

function backup_mysql() {
  local credentials dump consistency database container
  local databases=() options=()
  credentials="$(job_get credentials_file)"
  dump="$(job_get dump_command)"
  consistency="$(job_get consistency)"
  container="$(job_get container)"

  while IFS= read -r -d '' database; do
    databases+=("$database")
  done < <(job_list databases)

  options=(
    "--defaults-file=$credentials"
    --quick
    --routines
    --triggers
    --events
    --hex-blob
    --no-tablespaces
  )

  if [[ "$consistency" == single-transaction ]]; then
    options+=(--single-transaction --skip-lock-tables)
  else
    options+=(--lock-all-tables)
    warningMessage "$JOB_NAME: Tabellensperren sind aktiviert und können Schreibzugriffe blockieren."
  fi

  if (( ${#databases[@]} == 0 )); then
    options+=(--all-databases)
  else
    options+=(--databases "${databases[@]}")
  fi

  mkdir -- "$WORK/data"

  if [[ -n "$container" ]]; then
    Message "$JOB_NAME: Erstelle SQL-Dump im laufenden Container $container."
    # Das Passwort wird über stdin übergeben, nicht als Argument oder Umgebungsvariable.
    docker exec -i "$container" sh -c '
      set -eu
      umask 077
      credentials=$(mktemp /tmp/backup-manager-dump.XXXXXX)

      trap '\''rm -f -- "$credentials"'\'' 0
      trap '\''exit 1'\'' HUP INT TERM

      cat > "$credentials"
      dump=$1
      shift

      "$dump" "--defaults-file=$credentials" "$@"
    ' backup-manager-dump "$dump" "${options[@]:1}" < "$credentials" > "$WORK/data/databases.sql"
  else
    Message "$JOB_NAME: Erstelle SQL-Dump mit $dump."
    "$dump" "${options[@]}" > "$WORK/data/databases.sql"
  fi

  [[ -s "$WORK/data/databases.sql" ]] || die "Der SQL-Dump ist leer."
  Message "$JOB_NAME: SQL-Dump abgeschlossen. Packe den Dump ($ARCHIVE)."
  archive_create "$WORK/data" "$PARTIAL" "$ARCHIVE"
}
