#!/usr/bin/env bash

function check_secret_file() {
  local file="$1"
  local directory mode

  [[ "$file" == "$ROOT/secrets/"* ]] || die 'Zugangsdaten müssen unter secrets/ liegen.'
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || die 'Secret-Datei fehlt, ist unlesbar oder ein Symlink.'
  [[ "$(file_links "$file")" == 1 ]] || die 'Secrets dürfen keine Hardlinks sein.'
  [[ "$(file_owner "$file")" == "$(id -u)" ]] || die 'Secret-Datei gehört einem anderen Benutzer.'

  mode="$(file_mode "$file")"
  (( (8#$mode & 077) == 0 )) || die 'Secret-Dateien dürfen nur für ihren Besitzer lesbar sein (chmod 600).'

  directory="$(dirname -- "$file")"

  while [[ "$directory" == "$ROOT/secrets"* ]]; do
    [[ -d "$directory" && ! -L "$directory" ]] || die 'Secret-Unterordner darf kein Symlink sein.'
    [[ "$(file_owner "$directory")" == "$(id -u)" ]] || die 'Secret-Ordner gehört einem anderen Benutzer.'

    mode="$(file_mode "$directory")"
    (( (8#$mode & 077) == 0 )) || die 'Secret-Ordner brauchen Rechte 700.'
    directory="$(dirname -- "$directory")"
  done
}

function preflight_jobs() {
  local index kind source method container file job_name recipient_file

  require_command age
  require_command tar
  require_command gzip

  recipient_file="$(config_get encryption.recipient_file)"
  check_secret_file "$recipient_file"
  if ! age --encrypt --recipients-file "$recipient_file" /dev/null >/dev/null; then
    die 'Age-Empfängerdatei ist ungültig oder enthält keinen verwendbaren öffentlichen Schlüssel.'
  fi

  if ! command -v sha256sum >/dev/null 2>&1; then
    require_command shasum
  fi

  for (( index=0; index<COUNT; index++ )); do
    job_name="$(config_get "jobs.$index.name")"
    kind="$(config_get "jobs.$index.type")"
    method="$(config_get "jobs.$index.archiving_method")"

    case "$method" in
      zip)
        require_command zip
        require_command unzip ;;
      tar.bz2)
        require_command bzip2 ;;
      tar.zst)
        require_command zstd ;;
    esac

    case "$kind" in
      files)
        source="$(config_get "jobs.$index.source")"
        if [[ ! -e "$source" ]]; then
          die "Job '$job_name': Backup-Quelle existiert nicht: $source"
        fi
        if [[ ! -f "$source" && ! -d "$source" ]]; then
          die "Job '$job_name': Backup-Quelle ist keine Datei und kein Ordner: $source"
        fi
        if [[ ! -r "$source" ]]; then
          die "Job '$job_name': Backup-Quelle ist nicht lesbar: $source"
        fi ;;

      software)
        while IFS= read -r -d '' file; do
          if [[ ! -r "$file" || ( ! -d "$file" && ! -f "$file" ) ]]; then
            die "Job '$job_name': Software-Pfad fehlt oder ist nicht lesbar: $file"
          fi
        done < <(config_list "jobs.$index.paths") ;;

      mysql)
        check_secret_file "$(config_get "jobs.$index.credentials_file")"
        container="$(config_get "jobs.$index.container")"

        if [[ -n "$container" ]]; then
          require_command docker
        else
          require_command "$(config_get "jobs.$index.dump_command")"
        fi ;;

      docker)
        require_command docker

        while IFS= read -r -d '' file; do
          if [[ ! -f "$file" || ! -r "$file" ]]; then
            die "Job '$job_name': Compose-/Begleitdatei fehlt oder ist nicht lesbar: $file"
          fi
        done < <(config_list "jobs.$index.compose_files") ;;
    esac
  done
}

function preflight_transfers() {
  local index credentials

  (( TRANSFERS > 0 )) || return 0
  require_command rsync
  require_command ssh

  for (( index=0; index<TRANSFERS; index++ )); do
    credentials="$(config_get "transfers.$index.credentials_file")"
    bash "$ROOT/code/shell/core/ssh.sh" check "$credentials"
  done
}
