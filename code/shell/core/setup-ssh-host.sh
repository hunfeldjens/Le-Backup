#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source "$ROOT/code/shell/core/common.sh"
source "$ROOT/code/shell/core/storage.sh"
require_root

require_command ssh-keyscan
require_command ssh-keygen

EXPECTED_FINGERPRINT="${1:-}"

if [[ -n "$EXPECTED_FINGERPRINT" && ! "$EXPECTED_FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
  die 'Der angegebene SHA-256-Fingerabdruck ist ungültig.'
fi

private_directory "$ROOT/state"
WORK="$(mktemp -d "$ROOT/state/.incomplete-ssh-setup.XXXXXX")"
PLAN="$WORK/plan.json"
SSH_CONFIG="$WORK/ssh.json"
PENDING="$WORK/known_hosts.pending"
EXISTING="$WORK/known_hosts.existing"

trap 'storage_cleanup "$WORK"' EXIT

"$BACKUP_PYTHON" "$ROOT/code/python/core/config.py" inventory "$ROOT" '' '' > "$PLAN"
TRANSFERS="$(config_length transfers)"

if (( TRANSFERS == 0 )); then
  die 'Kein aktives Rsync-Ziel gefunden. Zuerst rsync.enabled bei mindestens einem Job einschalten.'
fi

CREDENTIALS="$(json_get "$PLAN" transfers.0.credentials_file)"
"$BACKUP_PYTHON" "$ROOT/code/python/integrations/ssh.py" \
  "$ROOT" "$CREDENTIALS" prepare-known-hosts > "$SSH_CONFIG"

HOST="$(json_get "$SSH_CONFIG" host)"
PORT="$(json_get "$SSH_CONFIG" port)"
KNOWN_HOSTS="$(json_get "$SSH_CONFIG" known_hosts_file)"
CONNECT_TIMEOUT="$(json_get "$SSH_CONFIG" connect_timeout)"
LOOKUP="$HOST"

if [[ "$PORT" != 22 ]]; then
  LOOKUP="[$HOST]:$PORT"
fi

private_directory "$(dirname -- "$KNOWN_HOSTS")"

if [[ -e "$KNOWN_HOSTS" || -L "$KNOWN_HOSTS" ]]; then
  [[ -f "$KNOWN_HOSTS" && ! -L "$KNOWN_HOSTS" ]] || die 'known_hosts ist keine normale Datei.'
  [[ "$(file_owner "$KNOWN_HOSTS")" == "$(id -u)" ]] || die 'known_hosts gehört einem anderen Benutzer.'
  [[ "$(file_links "$KNOWN_HOSTS")" == 1 ]] || die 'known_hosts darf kein Hardlink sein.'
else
  : > "$KNOWN_HOSTS"
fi

chmod 600 "$KNOWN_HOSTS"

Message "Lese den ED25519-Hostschlüssel für $LOOKUP ein."
ssh-keyscan -T "$CONNECT_TIMEOUT" -p "$PORT" -t ed25519 "$HOST" > "$PENDING"
[[ -s "$PENDING" ]] || die 'Der SSH-Server hat keinen ED25519-Hostschlüssel geliefert.'

FINGERPRINTS="$(ssh-keygen -lf "$PENDING" -E sha256 | awk '{print $2}' | sort -u)"
FINGERPRINT_COUNT="$(printf '%s\n' "$FINGERPRINTS" | awk 'NF { count++ } END { print count + 0 }')"
(( FINGERPRINT_COUNT == 1 )) || die 'Der SSH-Server hat mehrere unterschiedliche ED25519-Hostschlüssel geliefert.'

FINGERPRINT="$FINGERPRINTS"

if ssh-keygen -F "$LOOKUP" -f "$KNOWN_HOSTS" > "$EXISTING"; then
  if ssh-keygen -lf "$EXISTING" -E sha256 | awk '{print $2}' | grep -Fxq "$FINGERPRINT"; then
    Message "Hostschlüssel ist bereits bestätigt: $FINGERPRINT"
    exit 0
  fi

  redMessage "Für $LOOKUP ist bereits ein anderer Hostschlüssel gespeichert."
  printf 'Gespeichert:\n'
  ssh-keygen -lf "$EXISTING" -E sha256
  printf 'Neu empfangen:\n%s\n' "$FINGERPRINT"
  die 'Hostschlüssel nicht automatisch ersetzt. Erst die Änderung beim Anbieter prüfen.'
fi

printf '\nSSH-Ziel:       %s\n' "$LOOKUP"
printf 'Fingerabdruck:  %s\n\n' "$FINGERPRINT"
printf '%s\n' 'Den Fingerabdruck jetzt über das Anbieterpanel oder die offizielle Dokumentation vergleichen.'

if [[ -n "$EXPECTED_FINGERPRINT" ]]; then
  [[ "$EXPECTED_FINGERPRINT" == "$FINGERPRINT" ]] || die 'Der empfangene Hostschlüssel stimmt nicht mit dem angegebenen Fingerabdruck überein.'
  Message 'Der empfangene Hostschlüssel stimmt mit dem angegebenen Fingerabdruck überein.'
else
  if [[ ! -t 0 ]]; then
    die 'Bestätigung benötigt ein interaktives Terminal oder den erwarteten Fingerabdruck als zweiten Parameter.'
  fi

  read -r -p 'Nach unabhängiger Prüfung zum Übernehmen JA eingeben: ' CONFIRMATION
  [[ "$CONFIRMATION" == JA ]] || die 'Hostschlüssel wurde nicht übernommen.'
fi

cat "$PENDING" >> "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"
Message "Hostschlüssel sicher gespeichert: $KNOWN_HOSTS"
