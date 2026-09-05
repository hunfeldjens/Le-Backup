#!/usr/bin/env bash

function backup_full_server() {
  local exclusions=(
    --exclude=./opt
    --exclude=./root
    --exclude=./mnt
    --exclude=./proc
    --exclude=./sys
    --exclude=./dev
    --exclude=./run
  )

  Message "$JOB_NAME: Packe das Root-Dateisystem mit tar.zst, Zstandard Ultra Stufe 22. Anwendungen laufen weiter."
  Message "$JOB_NAME: /opt, /root, /mnt sowie virtuelle Linux-Dateisysteme werden ausgeschlossen."
  warningMessage "$JOB_NAME: Ultra Stufe 22 kann viel CPU, Arbeitsspeicher und Zeit benötigen."

  (
    cd /
    tar -I 'zstd --ultra -22' \
      --ignore-failed-read -cf "$PARTIAL" "${exclusions[@]}" -- .
  )
}
