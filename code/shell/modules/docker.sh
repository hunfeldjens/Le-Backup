#!/usr/bin/env bash

function backup_docker() {
  local container index=0 mount_index destination id image_id compose_file
  local containers=() ids=()

  while IFS= read -r -d '' container; do
    containers+=("$container")
  done < <(job_list containers)

  mkdir -- "$WORK/data"
  mkdir -- "$WORK/data/compose"
  Message "$JOB_NAME: Sichere die konfigurierten Compose- und Begleitdateien."

  while IFS= read -r -d '' compose_file; do
    index=$((index + 1))
    mkdir -- "$WORK/data/compose/file-$index"

    cp -p -- "$compose_file" "$WORK/data/compose/file-$index/$(basename -- "$compose_file")"
    printf '%s\t%s\n' "file-$index/$(basename -- "$compose_file")" "$compose_file" >> "$WORK/data/compose/paths.tsv"
  done < <(job_list compose_files)

  index=0

  for container in "${containers[@]}"; do
    index=$((index + 1))
    mkdir -- "$WORK/data/container-$index"
    Message "$JOB_NAME: Prüfe Container $container und lese seine Metadaten."
    docker inspect --type container "$container" > "$WORK/data/container-$index/inspect.json"

    "$BACKUP_PYTHON" "$ROOT/code/python/integrations/docker_data.py" validate "$WORK/data/container-$index/inspect.json"
    id="$(docker inspect --type container --format '{{.Id}}' "$container")"
    ids+=("$id")
  done

  warningMessage "$JOB_NAME: Live-Kopie – Container bleiben unverändert; Dateien können sich währenddessen ändern."
  index=0

  for id in "${ids[@]}"; do
    index=$((index + 1))
    container="${containers[index - 1]}"
    if [[ "$(job_get export_filesystem)" == true ]]; then
      Message "$JOB_NAME: Exportiere das Dateisystem von $container."
      docker export "$id" | gzip > "$WORK/data/container-$index/filesystem.tar.gz"
      gzip -t "$WORK/data/container-$index/filesystem.tar.gz"
    fi

    if [[ "$(job_get include_mounts)" == true ]]; then
      Message "$JOB_NAME: Kopiere die persistenten Nutzdaten von $container."
      mount_index=0
      "$BACKUP_PYTHON" "$ROOT/code/python/integrations/docker_data.py" mounts \
        "$WORK/data/container-$index/inspect.json" > "$WORK/mounts.list"

      while IFS= read -r -d '' destination; do
        mount_index=$((mount_index + 1))
        docker cp -a "$id:$destination" "$WORK/data/container-$index/mount-$mount_index"
      done < "$WORK/mounts.list"
    fi

    if [[ "$(job_get save_images)" == true ]]; then
      Message "$JOB_NAME: Sichere das Image von $container."
      image_id="$(docker inspect --type container --format '{{.Image}}' "$id")"
      docker image save "$image_id" | gzip > "$WORK/data/container-$index/image.tar.gz"
      gzip -t "$WORK/data/container-$index/image.tar.gz"
    fi
  done

  Message "$JOB_NAME: Datenübernahme abgeschlossen. Packe das Docker-Backup ($ARCHIVE)."
  archive_create "$WORK/data" "$PARTIAL" "$ARCHIVE"
}
