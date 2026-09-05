#!/usr/bin/env bash

function dependency_check() {
  local command="$1"
  local package="$2"
  local existing

  command -v "$command" >/dev/null 2>&1 && return 0
  for existing in "${MISSING_PACKAGES[@]+${MISSING_PACKAGES[@]}}"; do
    [[ "$existing" != "$package" ]] || return 0
  done
  MISSING_PACKAGES+=("$package")
  redMessage "Fehlt: $command (Paket: $package)"
}

function dependencies_report() {
  (( ${#MISSING_PACKAGES[@]} > 0 )) || return 0
  printf 'Debian/Ubuntu – fehlende Pakete installieren: apt install' >&2
  printf ' %s' "${MISSING_PACKAGES[@]}" >&2
  printf '\nBei anderen Distributionen die entsprechenden Paketnamen verwenden.\n' >&2
  die 'Fehlende Pakete installieren und die Prüfung wiederholen. Es wurde nichts automatisch installiert.'
}

function dependencies_base() {
  MISSING_PACKAGES=()
  dependency_check "$BACKUP_PYTHON" python3
  dependency_check flock util-linux

  if command -v "$BACKUP_PYTHON" >/dev/null 2>&1; then
    if ! "$BACKUP_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
      redMessage 'Fehlt: Python ab Version 3.9.'
      MISSING_PACKAGES+=(python3)
    fi
    if ! "$BACKUP_PYTHON" -c 'import yaml' 2>/dev/null; then
      redMessage 'Fehlt: PyYAML (Paket: python3-yaml).'
      MISSING_PACKAGES+=(python3-yaml)
    fi
  fi
  dependencies_report
}

function dependencies_plan() {
  local index kind method container credentials auth version multiplexer
  local major minor
  MISSING_PACKAGES=()

  if [[ "${INCLUDE_FULL_SERVER_DEPENDENCIES:-false}" == true ]]; then
    dependency_check zstd zstd
  fi

  if [[ "${FOREGROUND:-false}" == false ]]; then
    multiplexer="$(config_get general_settings.multiplexer)"
    dependency_check "$multiplexer" "$multiplexer"
    if [[ "$multiplexer" == screen ]] && command -v screen >/dev/null 2>&1; then
      version="$(screen -v)"
      major=0
      minor=0
      if [[ "$version" =~ Screen\ version\ ([0-9]+)\.([0-9]+) ]]; then
        major=$((10#${BASH_REMATCH[1]}))
        minor=$((10#${BASH_REMATCH[2]}))
      fi
      if (( major < 4 || (major == 4 && minor < 2) )); then
        redMessage 'Fehlt: Screen ab Version 4.2 für die Abfrage laufender Sessions.'
        MISSING_PACKAGES+=(screen)
      fi
    fi
  fi

  if (( COUNT > 0 )) && [[ "${RSYNC_ONLY:-false}" == false ]]; then
    dependency_check age age
    dependency_check tar tar
    dependency_check gzip gzip
    if ! command -v sha256sum >/dev/null 2>&1; then
      dependency_check shasum coreutils
    fi

    for (( index=0; index<COUNT; index++ )); do
      kind="$(config_get "jobs.$index.type")"
      method="$(config_get "jobs.$index.archiving_method")"
      case "$method" in
        zip)
          dependency_check zip zip
          dependency_check unzip unzip ;;
        tar.bz2) dependency_check bzip2 bzip2 ;;
        tar.zst) dependency_check zstd zstd ;;
      esac
      case "$kind" in
        docker) dependency_check docker docker.io ;;
        mysql)
          container="$(config_get "jobs.$index.container")"
          if [[ -n "$container" ]]; then
            dependency_check docker docker.io
          else
            dependency_check "$(config_get "jobs.$index.dump_command")" mariadb-client
          fi ;;
      esac
    done
  fi

  if (( TRANSFERS > 0 )); then
    dependency_check rsync rsync
    dependency_check ssh openssh-client
    dependency_check ssh-keyscan openssh-client
    dependency_check ssh-keygen openssh-client
    if command -v rsync >/dev/null 2>&1; then
      version="$(rsync --version)"
      major=0
      if [[ "$version" =~ version[[:space:]]+([0-9]+)\. ]]; then
        major=$((10#${BASH_REMATCH[1]}))
      fi
      if (( major < 3 )); then
        redMessage 'Fehlt: Rsync ab Version 3.0 mit sicherer Argumentübertragung (--protect-args).'
        MISSING_PACKAGES+=(rsync)
      fi
    fi
    for (( index=0; index<TRANSFERS; index++ )); do
      credentials="$(config_get "transfers.$index.credentials_file")"
      if [[ -f "$credentials" ]]; then
        auth="$("$BACKUP_PYTHON" "$ROOT/code/python/integrations/ssh.py" "$ROOT" "$credentials" auth)"
        if [[ "$auth" == password ]]; then
          dependency_check sshpass sshpass
        fi
      fi
    done
  fi
  dependencies_report
}
