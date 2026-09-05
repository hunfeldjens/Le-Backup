#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export BACKUP_PYTHON="${BACKUP_PYTHON:-python3}"
export PYTHONDONTWRITEBYTECODE=1

source "$ROOT/code/shell/core/common.sh"
source "$ROOT/code/shell/core/storage.sh"
source "$ROOT/code/shell/core/dependencies.sh"

MARKER=.backup-manager-installation
INSTALLER_STATE="${BACKUP_INSTALLER_STATE:-/var/lib/le-backup-manager}"
TARGET_MEMORY="$INSTALLER_STATE/installation-target"
CODE_DIRECTORIES=(shell python)
PROGRAM_FILES=(create-backup.sh)
LEGACY_PROGRAM_FILES=(install.sh)
DOCUMENTATION_FILES=(Readme.md installation.md)
TARGET=/opt/backup-manager
OWNER=root
CONFIRMED=false
ACTION="${1:-}"
STAGE=""
PLAN=""

function installer_help() {
  printf '%s\n' \
    'bash install.sh install|update|remove|permissions|check|cron [Optionen]' \
    '  --target PFAD   Eigener Installationsordner (sonst letzter Pfad oder /opt/backup-manager)' \
    '  --yes           Entfernung inklusive Config und Secrets bestätigen' \
    '  check          Config und benötigte Pakete prüfen' \
    '  cron           Beispiele für die Root-Crontab anzeigen' \
    'Immer als root ausführen. Keine Dienste, Cronjobs, Benutzer oder Pakete werden angelegt.'
}

function installer_menu() {
  local selection entered_target

  printf '%s\n' \
    'Le-Backup Manager' \
    '1) Installieren' \
    '2) Aktualisieren' \
    '3) Entfernen' \
    '4) Rechte korrigieren' \
    '5) Config und Pakete prüfen' \
    '6) Cron-Beispiele anzeigen'

  read -r -p 'Auswahl: ' selection

  case "$selection" in
    1) ACTION=install ;;
    2) ACTION=update ;;
    3) ACTION=remove ;;
    4) ACTION=permissions ;;
    5) ACTION=check ;;
    6) ACTION=cron ;;
    *) die 'Ungültige Auswahl.' ;;
  esac

  read -r -p "Installationspfad [$TARGET]: " entered_target
  TARGET="${entered_target:-$TARGET}"
}

function load_remembered_target() {
  local remembered

  if [[ -f "$ROOT/$MARKER" && ! -L "$ROOT/$MARKER" ]]; then
    TARGET="$ROOT"
    return
  fi

  [[ -e "$TARGET_MEMORY" || -L "$TARGET_MEMORY" ]] || return 0
  [[ -f "$TARGET_MEMORY" && ! -L "$TARGET_MEMORY" ]] || die 'Ungültiger gespeicherter Installationspfad.'
  [[ "$(file_owner "$TARGET_MEMORY")" == "$(id -u)" ]] || die 'Gespeicherter Installationspfad gehört einem anderen Benutzer.'
  [[ "$(file_links "$TARGET_MEMORY")" == 1 ]] || die 'Gespeicherter Installationspfad darf kein Hardlink sein.'

  IFS= read -r remembered < "$TARGET_MEMORY" || die 'Gespeicherter Installationspfad ist nicht lesbar.'
  [[ "$remembered" == /*/* && "$remembered" != *$'\n'* && "$remembered" != *$'\r'* ]] || die 'Gespeicherter Installationspfad ist ungültig.'
  TARGET="${remembered%/}"
}

function remember_target() {
  local temporary

  private_directory "$INSTALLER_STATE"
  temporary="$(mktemp "$INSTALLER_STATE/.installation-target.XXXXXX")"
  printf '%s\n' "$TARGET" > "$temporary"
  chmod 600 "$temporary"
  mv -- "$temporary" "$TARGET_MEMORY"
}

function forget_target() {
  local remembered=""

  if [[ -f "$TARGET_MEMORY" && ! -L "$TARGET_MEMORY" ]]; then
    IFS= read -r remembered < "$TARGET_MEMORY" || true
  fi

  if [[ "$remembered" == "$TARGET" ]]; then
    rm -f -- "$TARGET_MEMORY"
    rmdir "$INSTALLER_STATE" 2>/dev/null || true
  fi
}

function validate_target() {
  local parent

  [[ "$TARGET" == /*/* ]] || die 'Einen absoluten Installationsunterordner angeben.'
  [[ "$TARGET" != *'/../'* && "$TARGET" != */.. && "$TARGET" != *'/./'* && "$TARGET" != */. ]] || die "Installationspfad darf keine '.'- oder '..'-Segmente enthalten."
  [[ "$TARGET" != *$'\n'* && "$TARGET" != *$'\r'* ]] || die 'Ungültiger Installationspfad.'

  TARGET="${TARGET%/}"
  parent="$TARGET"

  while [[ "$parent" != / ]]; do
    [[ ! -L "$parent" ]] || die 'Installationspfad darf keine Symlinks enthalten.'
    parent="$(dirname -- "$parent")"
  done

  parent="$(cd -- "$(dirname -- "$TARGET")" && pwd -P)"
  TARGET="$parent/$(basename -- "$TARGET")"

  case "$TARGET" in
    /|/root|/home|/Users|/opt|/usr|/usr/local|/var|/var/lib|/tmp|/private/tmp|"$HOME")
      die 'Dieser Installationspfad ist zu weit gefasst.' ;;
  esac

  if [[ "$TARGET" == "$ROOT" && "$ACTION" != permissions ]]; then
    die 'Quellprojekt und Installationsziel müssen verschieden sein.'
  fi

  [[ "$ROOT/" != "$TARGET/"* || "$ROOT" == "$TARGET" ]] || die 'Ziel darf kein Elternordner des Quellprojekts sein.'
  [[ "$TARGET/" != "$ROOT/"* || "$ROOT" == "$TARGET" ]] || die 'Ziel darf nicht innerhalb des Quellprojekts liegen.'
}

function validate_tree() {
  local directory="$1"
  local invalid

  [[ -d "$directory" && ! -L "$directory" ]] || die "Ordner fehlt oder ist ein Symlink: $directory"
  invalid="$(find "$directory" ! -type f ! -type d -print -quit)"
  [[ -z "$invalid" ]] || die 'Symlinks und Spezialdateien sind in Installationsdateien nicht erlaubt.'
  invalid="$(find "$directory" -type f -links +1 -print -quit)"
  [[ -z "$invalid" ]] || die 'Hardlinks sind in Installationsdateien nicht erlaubt.'
}

function set_tree_permissions() {
  local directory="$1"
  local executable_scripts="$2"

  validate_tree "$directory"
  find "$directory" -type d -exec chmod 700 {} +
  find "$directory" -type f -exec chmod 600 {} +

  if [[ "$executable_scripts" == true ]]; then
    find "$directory" -type f -name '*.sh' -exec chmod 700 {} +
  fi

  if [[ "$(id -u)" == 0 ]]; then
    chown -R "$OWNER:$(id -gn "$OWNER")" "$directory"
  fi
}

function set_program_permissions() {
  local directory="$1"
  local filename mode
  local files=("${PROGRAM_FILES[@]}")

  set_tree_permissions "$directory/code" true

  for filename in "${DOCUMENTATION_FILES[@]}"; do
    if [[ -e "$directory/$filename" || -L "$directory/$filename" ]]; then
      files+=("$filename")
    fi
  done

  for filename in "${files[@]}"; do
    [[ -f "$directory/$filename" && ! -L "$directory/$filename" ]] || die "Ungültige Programmdatei: $filename"
    [[ "$(file_links "$directory/$filename")" == 1 ]] || die 'Programmdateien dürfen keine Hardlinks sein.'
    mode=600
    if [[ "$filename" == *.sh ]]; then
      mode=700
    fi

    chmod "$mode" "$directory/$filename"

    if [[ "$(id -u)" == 0 ]]; then
      chown "$OWNER:$(id -gn "$OWNER")" "$directory/$filename"
    fi
  done
}

function copy_program() {
  local destination="$1"
  local directory filename

  mkdir -- "$destination/code"

  for directory in "${CODE_DIRECTORIES[@]}"; do
    validate_tree "$ROOT/code/$directory"
    cp -R -- "$ROOT/code/$directory" "$destination/code/$directory"
  done

  for filename in "${PROGRAM_FILES[@]}"; do
    [[ -f "$ROOT/$filename" && ! -L "$ROOT/$filename" ]] || die "Programmdatei fehlt: $filename"
    cp -- "$ROOT/$filename" "$destination/$filename"
  done

  for filename in "${DOCUMENTATION_FILES[@]}"; do
    [[ -e "$ROOT/$filename" || -L "$ROOT/$filename" ]] || continue
    [[ -f "$ROOT/$filename" && ! -L "$ROOT/$filename" ]] || die "Ungültige Dokumentationsdatei: $filename"
    cp -- "$ROOT/$filename" "$destination/$filename"
  done

  set_program_permissions "$destination"
}

function read_installation() {
  local signature stored_target stored_owner

  [[ -f "$TARGET/$MARKER" && ! -L "$TARGET/$MARKER" ]] || die 'Keine vom Installer verwaltete Installation.'

  {
    IFS= read -r signature
    IFS= read -r stored_target
    IFS= read -r stored_owner
  } < "$TARGET/$MARKER"

  [[ "$signature" == le-backup-manager && "$stored_target" == "$TARGET" ]] || die 'Ungültige Installationsmarkierung.'

  if [[ "$stored_owner" != root && "$ACTION" != permissions ]]; then
    die 'Diese Installation gehört noch einem anderen Benutzer. Zuerst als root mit permissions umstellen.'
  fi
}

function lock_installation() {
  local socket="$TARGET/state/tmux.sock"
  local screen_directory="$TARGET/state/screen"

  [[ ! -L "$TARGET/state" ]] || die 'state/ darf kein Symlink sein.'
  mkdir -p -- "$TARGET/state"
  [[ -d "$TARGET/state" ]] || die 'state/ ist kein Ordner.'
  chmod 700 "$TARGET/state"
  if [[ "$(id -u)" == 0 ]]; then
    chown "$OWNER:$(id -gn "$OWNER")" "$TARGET/state"
  fi

  [[ ! -L "$TARGET/state/manager.lock" ]] || die 'Die Laufsperre darf kein Symlink sein.'
  if [[ -e "$TARGET/state/manager.lock" ]]; then
    [[ -f "$TARGET/state/manager.lock" && "$(file_links "$TARGET/state/manager.lock")" == 1 ]] || die 'Ungültige Laufsperre.'
  fi
  exec 9>"$TARGET/state/manager.lock"
  chmod 600 "$TARGET/state/manager.lock"
  if [[ "$(id -u)" == 0 ]]; then
    chown "$OWNER:$(id -gn "$OWNER")" "$TARGET/state/manager.lock"
  fi
  flock -n 9 || die 'Backup oder Installer läuft bereits.'

  PLAN="$(mktemp "$TARGET/state/.installer-plan.XXXXXX")"
  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" plan "$TARGET" '' '' > "$PLAN"
  if [[ -S "$socket" ]]; then
    require_command tmux

    if tmux -S "$socket" list-sessions >/dev/null 2>&1; then
      die 'tmux-Session ist aktiv. Erst das Backup beenden lassen.'
    fi
  fi

  [[ ! -L "$screen_directory" ]] || die 'Screen-Ordner darf kein Symlink sein.'
  if [[ -d "$screen_directory" && -n "$(find "$screen_directory" -type s -print -quit)" ]]; then
    die 'Screen-Socket vorhanden. Erst das Backup beenden lassen; verwaiste Sessions mit screen -wipe prüfen.'
  fi
}

function installer_dependencies() {
  local config_root="$1"
  PLAN="$(mktemp "${TMPDIR:-/tmp}/.backup-installer.XXXXXX")"
  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" plan "$config_root" '' '' > "$PLAN"
  COUNT="$(config_length jobs)"
  TRANSFERS="$(config_length transfers)"
  INCLUDE_FULL_SERVER_DEPENDENCIES=true dependencies_plan
  rm -- "$PLAN"
  PLAN=""
  Message 'Config und benötigte Pakete erfolgreich geprüft. Quellen und Zugangsdaten anschließend mit --check prüfen.'
}

function installer_cron() {
  local command="$TARGET/create-backup.sh"
  command="${command//\'/\'\\\'\'}"
  command="${command//%/\\%}"

  printf '\n%s\n' \
    'Root-Crontab öffnen: sudo crontab -e' \
    'Eine der folgenden Varianten auswählen (nicht alle gleichzeitig eintragen):' \
    'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    '# Täglich um 03:00 Uhr alle aktiven Jobs:'
  printf "0 3 * * * /bin/bash '%s' --wait\n" "$command"
  printf '%s\n' '# Alternativ alle 6 Stunden nur einen Job (JOBNAME durch den Config-Namen ersetzen):'
  printf "0 */6 * * * /bin/bash '%s' --wait -JOBNAME\n" "$command"
  printf '%s\n' \
    '--wait startet weiterhin in tmux oder screen und meldet Cron das Ergebnis.' \
    'Die Benutzer-Crontab hat fünf Zeitfelder; hier KEIN zusätzliches root-Feld eintragen.' \
    'Es wurde kein Cronjob automatisch eingerichtet.'
}

function protect_installation() {
  chmod 700 "$TARGET"
  chmod 700 "$TARGET/state"
  chmod 600 "$TARGET/state/manager.lock"
  if [[ "$(id -u)" == 0 ]]; then
    chown "root:$(id -gn root)" "$TARGET" "$TARGET/state" "$TARGET/state/manager.lock"
  fi
  set_tree_permissions "$TARGET/config" false
  set_tree_permissions "$TARGET/secrets" false
  if [[ -f "$TARGET/$MARKER" ]]; then
    [[ ! -L "$TARGET/$MARKER" && "$(file_links "$TARGET/$MARKER")" == 1 ]] || die 'Ungültige Installationsmarkierung.'
    printf '%s\n' le-backup-manager "$TARGET" root > "$TARGET/$MARKER"
    chmod 600 "$TARGET/$MARKER"
    if [[ "$(id -u)" == 0 ]]; then
      chown "root:$(id -gn root)" "$TARGET/$MARKER"
    fi
  fi
}

function install_system() {
  local folder

  [[ ! -e "$TARGET" ]] || die 'Ziel existiert bereits. Für bestehende Installationen update verwenden.'
  STAGE="$(mktemp -d "$(dirname -- "$TARGET")/.incomplete-install.XXXXXX")"
  copy_program "$STAGE"

  for folder in config secrets; do
    validate_tree "$ROOT/$folder"
    cp -R -- "$ROOT/$folder" "$STAGE/$folder"
    set_tree_permissions "$STAGE/$folder" false
  done

  "$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" plan "$STAGE" '' '' >/dev/null
  mkdir -- "$STAGE/state"
  printf '%s\n' le-backup-manager "$TARGET" "$OWNER" > "$STAGE/$MARKER"

  if [[ "$(id -u)" == 0 ]]; then
    chown "$OWNER:$(id -gn "$OWNER")" "$STAGE" "$STAGE/state" "$STAGE/$MARKER"
  fi

  mv -- "$STAGE" "$TARGET"
  STAGE=""
  remember_target
  Message "Installiert: $TARGET (Backup-Benutzer: $OWNER)"
  Message 'Keine Dienste, Cronjobs, Benutzer oder Pakete angelegt.'
  installer_cron
}

function update_system() {
  local previous filename
  local moved=()

  validate_tree "$TARGET/config"
  validate_tree "$TARGET/secrets"

  for filename in "${LEGACY_PROGRAM_FILES[@]}"; do
    [[ -e "$TARGET/$filename" || -L "$TARGET/$filename" ]] || continue
    [[ -f "$TARGET/$filename" && ! -L "$TARGET/$filename" ]] || die "Ungültige alte Installerdatei: $filename"
    [[ "$(file_links "$TARGET/$filename")" == 1 ]] || die 'Alte Installerdateien dürfen keine Hardlinks sein.'
  done

  STAGE="$(mktemp -d "$TARGET/.incomplete-update.XXXXXX")"
  previous="$(mktemp -d "$TARGET/.previous-code.XXXXXX")"
  copy_program "$STAGE"

  for filename in code "${PROGRAM_FILES[@]}" "${DOCUMENTATION_FILES[@]}"; do
    [[ -e "$STAGE/$filename" ]] || continue

    if [[ -e "$TARGET/$filename" || -L "$TARGET/$filename" ]] && \
        ! mv -- "$TARGET/$filename" "$previous/$filename"; then
      for filename in "${moved[@]+${moved[@]}}"; do
        mv -- "$TARGET/$filename" "$STAGE/$filename.failed"
        if [[ -e "$previous/$filename" || -L "$previous/$filename" ]]; then
          mv -- "$previous/$filename" "$TARGET/$filename"
        fi
      done
      die 'Update fehlgeschlagen. Vorheriger Programmstand wiederhergestellt.'
    fi
    moved+=("$filename")

    if ! mv -- "$STAGE/$filename" "$TARGET/$filename"; then
      for filename in "${moved[@]}"; do
        if [[ -e "$TARGET/$filename" ]]; then
          mv -- "$TARGET/$filename" "$STAGE/$filename.failed"
        fi
        if [[ -e "$previous/$filename" || -L "$previous/$filename" ]]; then
          mv -- "$previous/$filename" "$TARGET/$filename"
        fi
      done
      die 'Update fehlgeschlagen. Vorheriger Programmstand wiederhergestellt.'
    fi
  done

  for filename in "${LEGACY_PROGRAM_FILES[@]}"; do
    rm -f -- "$TARGET/$filename"
  done

  if [[ -e "$previous/code/installer" || -L "$previous/code/installer" ]]; then
    rm -rf -- "$previous/code/installer"
  fi

  Message 'Aktualisiert. Config, Secrets, Backups und Logs blieben unverändert.'
  Message "Vorheriger Programmstand: $previous"
  protect_installation
  remember_target
  installer_cron
}

function remove_system() {
  local answer path relative destination parent
  local preserved="$TARGET.data-$(date -u '+%Y%m%dT%H%M%SZ')-$$"

  if [[ "$CONFIRMED" == false ]]; then
    printf 'Installation, Config und Secrets in %s entfernen?\n' "$TARGET"
    read -r -p 'Zur Bestätigung ENTFERNEN eingeben: ' answer
    [[ "$answer" == ENTFERNEN ]] || die 'Entfernung abgebrochen.'
  fi

  for path in "$(config_get general_settings.backup_directory)" "$(config_get general_settings.log_directory)"; do
    if [[ "$path" == "$TARGET/"* && -d "$path" ]]; then
      relative="${path#"$TARGET/"}"
      destination="$preserved/$relative"
      mkdir -p -- "$(dirname -- "$destination")"

      if [[ "$(id -u)" == 0 ]]; then
        parent="$(dirname -- "$destination")"

        while [[ "$parent" == "$preserved" || "$parent" == "$preserved/"* ]]; do
          chown "$OWNER:$(id -gn "$OWNER")" "$parent"
          parent="$(dirname -- "$parent")"
        done
      fi

      mv -- "$path" "$destination"
    fi
  done

  rm -f -- "$PLAN"
  PLAN=""
  rm -rf -- "$TARGET"
  forget_target

  Message 'Installation inklusive Config und Secrets entfernt. Externe Backups/Logs blieben unverändert.'

  if [[ -d "$preserved" ]]; then
    Message "Interne Backups/Logs erhalten unter: $preserved"
  fi

  Message 'Bestehende eigene Cronjobs bitte aus der Crontab entfernen.'
}

function installer_cleanup() {
  local result=$?

  if [[ -n "$PLAN" ]]; then
    rm -f -- "$PLAN"
  fi

  if [[ -n "$STAGE" && -d "$STAGE" ]]; then
    storage_cleanup "$STAGE" || redMessage 'Installations-Arbeitsordner konnte nicht entfernt werden.'
  fi

  exit "$result"
}

trap installer_cleanup EXIT

if [[ "$ACTION" == --help || "$ACTION" == -h ]]; then
  installer_help
  exit 0
fi

require_root
load_remembered_target

if [[ -z "$ACTION" ]]; then
  installer_menu
else
  shift

  while (( $# > 0 )); do
    case "$1" in
      --target)
        (( $# >= 2 )) || die "Wert für $1 fehlt."
        TARGET="$2"
        shift ;;
      --yes) CONFIRMED=true ;;
      *) die "Unbekannte Option: $1" ;;
    esac
    shift
  done
fi

case "$ACTION" in
  install|update|remove|permissions|check|cron) ;;
  *) die 'Aktion muss install, update, remove, permissions, check oder cron sein.' ;;
esac

if [[ "$ACTION" == cron ]]; then
  installer_cron
  exit 0
fi

dependencies_base

if [[ "$ACTION" == check ]]; then
  CHECK_ROOT="$ROOT"
  [[ ! -f "$TARGET/$MARKER" ]] || CHECK_ROOT="$TARGET"
  installer_dependencies "$CHECK_ROOT"
  installer_cron
  exit 0
fi

validate_target

if [[ "$ACTION" == install ]]; then
  installer_dependencies "$ROOT"
elif [[ "$ACTION" == update ]]; then
  installer_dependencies "$TARGET"
fi

if [[ "$ACTION" != install ]]; then
  if [[ "$TARGET" != "$ROOT" ]]; then
    read_installation
  fi
  lock_installation
fi

case "$ACTION" in
  install) install_system ;;
  update) update_system ;;
  remove) remove_system ;;
  permissions)
    set_program_permissions "$TARGET"
    protect_installation
    remember_target
    Message 'Programm- und Secret-Rechte korrigiert.' ;;
esac
