#!/usr/bin/env python3

import json
from pathlib import PurePosixPath
import sys


def main():
    action, path = sys.argv[1:]
    with open(path, encoding="utf-8") as handle:
        container = json.load(handle)[0]

    state = container["State"]

    unavailable = (
        state.get("Paused")
        or state.get("Restarting")
        or state.get("Dead")
        or state.get("Status") == "removing"
    )

    if unavailable:
        raise ValueError("Container ist pausiert, startet neu oder ist nicht betriebsbereit.")

    for mount in container.get("Mounts", []):
        if mount["Type"] not in ("volume", "bind"):
            if mount["Type"] == "tmpfs":
                print("HINWEIS: Flüchtiger tmpfs-Mount wird nicht gesichert.", file=sys.stderr)
                continue

            raise ValueError("Unbekannter Docker-Mounttyp; Backup abgebrochen.")
        destination = mount["Destination"]

        if destination.rstrip("/") == "/var/lib/mysql" and action == "mounts":
            raise ValueError("MariaDB/MySQL-Daten nicht live als Dateien kopieren. Einen mysql-Job mit container und SQL-Dump konfigurieren.")
        invalid_destination = (
            not destination.startswith("/")
            or str(PurePosixPath(destination)) == "/"
            or any(ord(char) < 32 for char in destination)
        )

        if invalid_destination:
            raise ValueError("Ungültiger Docker-Mountpfad.")

        if action == "mounts":
            sys.stdout.buffer.write(destination.encode() + b"\0")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError) as error:
        print(f"FEHLER: {error}", file=sys.stderr)
        sys.exit(1)
