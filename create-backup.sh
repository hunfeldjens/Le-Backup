#!/usr/bin/env bash
# Le-Backup Manager

set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export BACKUP_PYTHON="${BACKUP_PYTHON:-python3}"
export PYTHONDONTWRITEBYTECODE=1
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
source "$ROOT/code/shell/core/common.sh"
source "$ROOT/code/shell/core/storage.sh"
source "$ROOT/code/shell/core/dependencies.sh"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf '%s\n' \
    'Aufruf: bash create-backup.sh [Optionen] [-JOBNAME ...]' \
    '  Ohne Auswahl       Alle aktiven Backups in tmux oder screen starten' \
    '  -JOBNAME           Beliebigen Job über seinen Config-Namen auswählen' \
    '  -NAME1 -NAME2      Mehrere Jobs samt zugehörigen Rsync-Zielen auswählen' \
    '  --type TYP         Nur files, mysql, docker oder software ausführen' \
    '  --foreground       Direkt ausführen; Exitcode entspricht dem Ergebnis' \
    '  --wait             Im Multiplexer starten und auf das Ergebnis warten' \
    '  --check            Config, Programme, Quellen und Secrets prüfen' \
    '  --list             Konfigurierte Jobs anzeigen' \
    '  --status           Aktuellen Status oder letztes Ergebnis anzeigen' \
    '  --rsync-only       Nur konfigurierte Rsync-Übertragungen ausführen' \
    '  --setup-ssh-host   SSH-Hostschlüssel für diese Installation einrichten' \
    '  --full-server      Gesamten Root-Server als festen tar.zst-Job sichern' \
    '  --config DATEI     Andere Hauptconfig verwenden' \
    'Ausführung immer als root. Multiplexer und Rsync stehen in config/config.yml.'
  exit 0
fi

WAIT_LOCK=0
if [[ "${1:-}" == --worker ]]; then
  WAIT_LOCK=30
  shift
  set -- --foreground "$@"
fi

require_root
dependencies_base
private_directory "$ROOT/state"
if (( $# == 1 )) && [[ "$1" == --status ]]; then
  exec bash "$ROOT/code/shell/manager.sh" --status
fi
[[ ! -L "$ROOT/state/manager.lock" ]] || die "Die Laufsperre darf kein Symlink sein."
if [[ -e "$ROOT/state/manager.lock" ]]; then
  [[ -f "$ROOT/state/manager.lock" && "$(file_links "$ROOT/state/manager.lock")" == 1 ]] || die 'Ungültige Laufsperre.'
fi

exec 9>"$ROOT/state/manager.lock"

if ! flock -w "$WAIT_LOCK" 9; then
  redMessage 'FEHLER: Ein Backup oder eine Installation läuft bereits.'
  exit 75
fi

if (( $# == 1 || $# == 2 )) && [[ "$1" == --setup-ssh-host ]]; then
  exec bash "$ROOT/code/shell/core/setup-ssh-host.sh" "${2:-}"
fi

exec bash "$ROOT/code/shell/manager.sh" "$@"
