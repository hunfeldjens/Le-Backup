#!/usr/bin/env bash

function greenMessage() {
  if [[ -t 1 ]]; then
    printf '\033[32;1m%s\033[0m\n' "$*"
  else
    printf '%s\n' "$*"
  fi
}

function redMessage() {
  log_message FEHLER "$@"
}

function warningMessage() {
  log_message WARN "$@"
}

function log_message() {
  local level="$1"
  shift
  local line="[Le-Backup] $(date '+%T') : [$level] $*"

  if [[ "$level" == FEHLER || "$level" == WARN ]]; then
    error_output "$line"
  else
    greenMessage "$line"
  fi
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

function error_output() {
  if [[ -t 2 ]]; then
    printf '\033[31;1m%s\033[0m\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

function Message() {
  log_message INFO "$@"
}

function die() {
  redMessage "$*"
  exit 1
}

function require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Benötigtes Programm fehlt: $1"
}

function require_root() {
  (( EUID == 0 )) || die 'Das Backup-System muss als root gestartet werden (sudo bash …).'
}

function config_get() {
  json_get "$PLAN" "$1"
}

function json_get() {
  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" get "$1" "$2"
}

function config_list() {
  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" list "$PLAN" "$1"
}

function config_length() {
  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" length "$PLAN" "$1"
}

function job_get() {
  config_get "jobs.$JOB_INDEX.$1"
}

function job_list() {
  config_list "jobs.$JOB_INDEX.$1"
}

function archive_create() {
  local source="$1" destination="$2" method="$3"
  shift 3
  local parent base
  parent="$(dirname -- "$source")"
  base="$(basename -- "$source")"
  case "$method" in
    zip)
      if (( $# > 0 )); then
        (cd -- "$parent" && zip -qry "$destination" "./$base" -x "$@")
      else
        (cd -- "$parent" && zip -qry "$destination" "./$base")
      fi
      ;;
    tar)     tar -cf "$destination" "$@" -C "$parent" -- "$base" ;;
    tar.gz)  tar -czf "$destination" "$@" -C "$parent" -- "$base" ;;
    tar.bz2) tar -cjf "$destination" "$@" -C "$parent" -- "$base" ;;
    tar.zst) tar --zstd -cf "$destination" "$@" -C "$parent" -- "$base" ;;
  esac
}

function archive_verify() {
  local file="$1" method="$2"
  [[ -s "$file" ]] || die "Archiv ist leer."
  case "$method" in
    zip) unzip -tqq "$file" ;;
    tar) tar -tf "$file" >/dev/null ;;
    tar.gz) gzip -t "$file" && tar -tzf "$file" >/dev/null ;;
    tar.bz2) bzip2 -t "$file" && tar -tjf "$file" >/dev/null ;;
    tar.zst) zstd -tq "$file" && tar --zstd -tf "$file" >/dev/null ;;
  esac
}
