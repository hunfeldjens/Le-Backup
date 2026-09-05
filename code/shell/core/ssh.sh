#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source "$ROOT/code/shell/core/common.sh"
source "$ROOT/code/shell/core/storage.sh"
source "$ROOT/code/shell/core/selection.sh"
require_root

ACTION="$1"
CREDENTIALS="$2"
shift 2

WORK="$(mktemp -d "$ROOT/state/.incomplete-ssh.XXXXXX")"
trap 'storage_cleanup "$WORK"' EXIT

"$BACKUP_PYTHON" "$ROOT/code/python/integrations/ssh.py" "$ROOT" "$CREDENTIALS" > "$WORK/config.json"

HOST="$(json_get "$WORK/config.json" host)"
USERNAME="$(json_get "$WORK/config.json" username)"
PORT="$(json_get "$WORK/config.json" port)"
AUTH="$(json_get "$WORK/config.json" auth)"
KNOWN_HOSTS="$(json_get "$WORK/config.json" known_hosts_file)"
CONNECT_TIMEOUT="$(json_get "$WORK/config.json" connect_timeout)"
ADDRESS="$USERNAME@$HOST"

SSH_OPTIONS=(
  -F /dev/null
  -p "$PORT"
  -o StrictHostKeyChecking=yes
  -o GlobalKnownHostsFile=/dev/null
  -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -o "ConnectTimeout=$CONNECT_TIMEOUT"
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
)

SSH_COMMAND=(ssh)

if [[ "$AUTH" == key ]]; then
  SSH_OPTIONS+=(
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -i "$(json_get "$WORK/config.json" private_key)"
  )
else
  require_command sshpass
  SSH_COMMAND=(sshpass -f "$(json_get "$WORK/config.json" password_file)" ssh)
  SSH_OPTIONS+=(
    -o BatchMode=no
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
  )
fi

function shell_quote() {
  local value="$1"
  local quote="'"
  local escaped_quote="'\"'\"'"

  printf "'%s'" "${value//$quote/$escaped_quote}"
}

case "$ACTION" in
  check)
    exit 0 ;;

  address)
    printf '%s\n' "$ADDRESS"
    exit 0 ;;

  transport)
    printf 'bash %s connect %s\n' \
      "$(shell_quote "$ROOT/code/shell/core/ssh.sh")" \
      "$(shell_quote "$CREDENTIALS")"
    exit 0 ;;

  connect)
    "${SSH_COMMAND[@]}" "${SSH_OPTIONS[@]}" "$@"
    exit $? ;;
esac

DESTINATION="$1"

case "/$DESTINATION/" in
  */../*) die 'Remote-Ziel darf kein .. enthalten.' ;;
esac

case "$DESTINATION" in
  ''|/|.|./|-*|~*) die 'Remote-Ziel muss ein eigener Backup-Unterordner sein.' ;;
esac

QUOTED_DESTINATION="$(shell_quote "$DESTINATION")"

case "$ACTION" in
  mkdir)
    # Storage-Boxen unterstützen einzelne Befehle, aber keine vollständige Shell.
    "${SSH_COMMAND[@]}" "${SSH_OPTIONS[@]}" "$ADDRESS" \
      "mkdir -p -m 700 -- $QUOTED_DESTINATION"

    REMOTE_COMMAND="chmod 700 -- $QUOTED_DESTINATION" ;;

  listing)
    REMOTE_COMMAND="ls -1t -- $QUOTED_DESTINATION" ;;

  remove-file)
    FILENAME="$2"
    managed_name "$FILENAME" || die 'Unsicherer Remote-Dateiname; keine Löschung.'
    QUOTED_FILE="$(shell_quote "${DESTINATION%/}/$FILENAME")"
    QUOTED_METADATA="$(shell_quote "${DESTINATION%/}/$FILENAME.meta.json")"
    REMOTE_COMMAND="rm -f -- $QUOTED_FILE $QUOTED_METADATA" ;;

  *)
    die 'Unbekannte SSH-Aktion.' ;;
esac

"${SSH_COMMAND[@]}" "${SSH_OPTIONS[@]}" "$ADDRESS" "$REMOTE_COMMAND"
