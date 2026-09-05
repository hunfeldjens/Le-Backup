#!/usr/bin/env python3

import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core.config import (
    ConfigError,
    load_yaml,
    mapping,
    number,
    secret_path,
    text,
)

HOST_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*\Z")
USERNAME_PATTERN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")


def load_credentials(root, credentials_file, prepare_known_hosts=False):
    root = Path(root)
    path = Path(credentials_file)

    try:
        relative = path.relative_to(root / "secrets")
    except ValueError:
        raise ConfigError("SSH-Zugangsdaten müssen unter secrets/ liegen.") from None

    secret_path(str(relative), root)

    allowed_settings = (
        "host",
        "port",
        "username",
        "auth",
        "private_key",
        "password_file",
        "known_hosts_file",
        "connect_timeout",
    )

    settings = mapping(load_yaml(path), "SSH-Zugangsdaten", allowed_settings)

    settings = {
        "port": 22,
        "connect_timeout": 30,
        "auth": "key",
        **settings,
    }

    host = text(settings.get("host"), "host")
    username = text(settings.get("username"), "username")

    if not HOST_PATTERN.fullmatch(host):
        raise ConfigError("SSH-host muss ein DNS-Name oder eine IPv4-Adresse sein.")

    if not USERNAME_PATTERN.fullmatch(username):
        raise ConfigError("Ungültiger SSH-Benutzername.")

    number(settings["port"], "port", 1, 65535)
    number(settings["connect_timeout"], "connect_timeout", 1, 300)

    settings["known_hosts_file"] = secret_path(
        settings.get("known_hosts_file"),
        root,
        check=not prepare_known_hosts,
    )

    if settings["auth"] == "key":
        settings["private_key"] = secret_path(settings.get("private_key"), root)

    elif settings["auth"] == "password":
        settings["password_file"] = secret_path(settings.get("password_file"), root)

        if not Path(settings["password_file"]).stat().st_size:
            raise ConfigError("SSH-Passwortdatei ist leer.")

    else:
        raise ConfigError("SSH-auth muss key oder password sein.")

    return settings


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[3] == "auth":
            settings = load_yaml(sys.argv[2])
            if not isinstance(settings, dict):
                raise ConfigError("SSH-Zugangsdaten müssen ein YAML-Objekt sein.")
            auth = settings.get("auth", "key")
            if auth not in ("key", "password"):
                raise ConfigError("SSH-auth muss key oder password sein.")
            print(auth)
        elif len(sys.argv) == 4 and sys.argv[3] == "prepare-known-hosts":
            settings = load_credentials(
                sys.argv[1],
                sys.argv[2],
                prepare_known_hosts=True,
            )
            print(json.dumps(settings, ensure_ascii=False, indent=2))
        else:
            settings = load_credentials(sys.argv[1], sys.argv[2])
            print(json.dumps(settings, ensure_ascii=False, indent=2))

    except (OSError, ValueError) as error:
        print(f"FEHLER: {error}", file=sys.stderr)
        sys.exit(1)
