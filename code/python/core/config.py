#!/usr/bin/env python3

import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("FEHLER: Python-Paket PyYAML fehlt. Debian/Ubuntu: apt install python3-yaml")

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
CONTAINER_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
ARCHIVES = ("zip", "tar", "tar.gz", "tar.bz2", "tar.zst")
MAX_CONFIG_BYTES = 1024 * 1024
RESERVED_NAMES = {
    "all", "help", "check", "list", "foreground", "wait",
    "status", "rsync-only", "setup-ssh-host", "worker", "type", "config",
}


class ConfigError(ValueError):
    pass


class ConfigLoader(yaml.SafeLoader):
    def compose_node(self, parent, index):
        if self.check_event(yaml.AliasEvent):
            raise ConfigError("YAML-Verweise (&/*) sind nicht erlaubt.")

        self.depth = getattr(self, "depth", 0) + 1

        if self.depth > 20:
            raise ConfigError("Die Config ist zu tief verschachtelt.")

        try:
            return super().compose_node(parent, index)
        finally:
            self.depth -= 1

    def construct_mapping(self, node, deep=False):
        result = {}

        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)

            if not isinstance(key, (str, int)) or key in result:
                raise ConfigError("Ungültiger oder doppelter YAML-Schlüssel.")
            result[key] = self.construct_object(value_node, deep=deep)

        return result


def load_yaml(path):
    try:
        with open(path, encoding="utf-8") as handle:
            content = handle.read(MAX_CONFIG_BYTES + 1)

        if len(content) > MAX_CONFIG_BYTES:
            raise ConfigError("Die Config ist zu groß.")

        return yaml.load(content, Loader=ConfigLoader)
    except yaml.YAMLError as error:
        mark = getattr(error, "problem_mark", None)
        line = f" in Zeile {mark.line + 1}" if mark else ""
        raise ConfigError(f"Ungültiges YAML in {Path(path).name}{line}.") from None


def mapping(value, label, allowed):
    if not isinstance(value, dict):
        raise ConfigError(f"{label} muss ein YAML-Objekt sein.")

    if set(value) - set(allowed):
        raise ConfigError(f"{label}: unbekannte Einstellungen; Schreibweise prüfen.")

    return value


def text(value, label, empty=False):
    if not isinstance(value, str) or (not empty and not value) or len(value) > 4096:
        raise ConfigError(f"{label} muss ein gültiger Text sein.")

    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ConfigError(f"{label} darf keine Steuerzeichen enthalten.")

    return value


def boolean(value, label):
    if type(value) is not bool:
        raise ConfigError(f"{label} muss true oder false sein.")
    return value


def number(value, label, minimum=1, maximum=100000):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ConfigError(f"{label} muss zwischen {minimum} und {maximum} liegen.")
    return value


def name(value, label):
    if not NAME.fullmatch(text(value, label)):
        raise ConfigError(f"{label}: nur Buchstaben, Zahlen, _ und - (maximal 64 Zeichen).")
    return value


def string_list(value, label):
    if not isinstance(value, list) or len(value) > 1000:
        raise ConfigError(f"{label} muss eine Liste mit maximal 1000 Einträgen sein.")
    return [text(item, label) for item in value]


def local_path(value, root, label):
    path = Path(text(value, label))

    if ".." in path.parts:
        raise ConfigError(f"{label} darf kein '..' enthalten.")

    return str((root / path).resolve())


def private_file(path, directory=False):
    path = Path(path)
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG

    if not expected(info.st_mode) or info.st_uid != os.geteuid():
        raise ConfigError(f"{path.name}: falscher Besitzer, Symlink oder falscher Dateityp.")

    if not directory and info.st_nlink != 1:
        raise ConfigError(f"{path.name}: Secrets dürfen keine Hardlinks sein.")

    if info.st_mode & 0o077:
        raise ConfigError(f"{path.name}: Rechte müssen {'700' if directory else '600'} sein.")


def secret_path(value, root, check=True):
    relative = Path(text(value, "secret_file"))

    if relative.is_absolute() or ".." in relative.parts:
        raise ConfigError("Secret-Pfade müssen relativ zu secrets/ sein.")

    base = root / "secrets"
    path = base / relative

    if not path.resolve().is_relative_to(base.resolve()) or path.is_symlink():
        raise ConfigError("Secrets dürfen nicht auf Dateien außerhalb von secrets/ verweisen.")

    if check:
        private_file(base, directory=True)

        for parent in relative.parents:
            if str(parent) != ".":
                private_file(base / parent, directory=True)

        private_file(path)

    return str(path)


def remote_path(value):
    value = text(value, "destination")
    path = PurePosixPath(value)
    if ".." in path.parts or str(path) in ("/", ".") or value.startswith(("-", "~")):
        raise ConfigError("destination muss ein eigener Backup-Unterordner sein (ohne '..' oder '~').")
    return str(path)


def load_config(root, config_file=None, check_secrets=False):
    root = Path(root).resolve()
    raw = load_yaml(config_file or root / "config/config.yml")

    if isinstance(raw, dict) and "Backups" in raw:
        raise ConfigError("Altes Config-Format erkannt. Die Einstellungen in das aktuelle Job-Format übertragen.")

    mapping(raw, "Config", (
        "general_settings",
        "encryption",
        "rsync",
        "full_server_backup",
        "jobs",
    ))

    defaults = {
        "backup_directory": "backups",
        "log_directory": "logs",
        "write_logs": True,
        "progress_interval_seconds": 30,
        "max_backups": 10,
        "archiving_method": "tar.gz",
        "multiplexer": "tmux",
        "session_name": "backup-manager",
        "continue_on_error": True,
        "minimum_free_mb": 1024,
    }

    settings = mapping(raw.get("general_settings", {}), "general_settings", (*defaults, "tmux_session"))
    if "tmux_session" in settings:
        settings = dict(settings)
        settings.setdefault("session_name", settings.pop("tmux_session"))
    general = {**defaults, **settings}

    for key in ("backup_directory", "log_directory"):
        general[key] = local_path(general[key], root, key)

        if Path(general[key]) in (Path("/"), root, Path.home()):
            raise ConfigError(f"{key} muss ein eigener Unterordner sein.")

    for key in ("write_logs", "continue_on_error"):
        boolean(general[key], key)

    number(general["max_backups"], "max_backups")
    number(general["progress_interval_seconds"], "progress_interval_seconds", 0, 3600)
    number(general["minimum_free_mb"], "minimum_free_mb", 0, 100000000)
    name(general["session_name"], "session_name")

    if general["multiplexer"] not in ("tmux", "screen"):
        raise ConfigError("multiplexer muss tmux oder screen sein.")

    if general["archiving_method"] not in ARCHIVES:
        raise ConfigError(f"archiving_method: erlaubt sind {', '.join(ARCHIVES)}.")

    encryption = mapping(
        raw.get("encryption", {}),
        "encryption",
        ("recipient_file",),
    )
    encryption = {
        "recipient_file": "age-recipients.txt",
        **encryption,
    }
    encryption["recipient_file"] = secret_path(
        encryption["recipient_file"],
        root,
        check=check_secrets,
    )

    jobs = raw.get("jobs", [])

    if not isinstance(jobs, list) or len(jobs) > 1000:
        raise ConfigError("jobs muss eine Liste mit maximal 1000 Einträgen sein.")

    jobs = list(jobs)

    for job in jobs:
        if isinstance(job, dict) and job.get("type") == "full-server":
            raise ConfigError("full-server ist ein interner Job und wird nur über --full-server eingestellt.")

    full_server = mapping(
        raw.get("full_server_backup", {}),
        "full_server_backup",
        ("max_backups", "rsync"),
    )
    jobs.append({
        "name": "Root-Server",
        "type": "full-server",
        "enabled": True,
        "max_backups": full_server.get("max_backups", 2),
        "archiving_method": "tar.zst",
        "rsync": full_server.get("rsync", {
            "enabled": True,
            "destination": "Server/Root-Server",
            "keep_backups": 3,
            "delete_local_after_transfer": False,
        }),
    })

    software_file = root / "config/software.yml"

    if software_file.is_file():
        software = load_yaml(software_file)
        mapping(software, "software.yml", ("software",))
        entries = software.get("software")

        if not isinstance(entries, list) or len(entries) > 100:
            raise ConfigError("software muss eine Liste mit maximal 100 Einträgen sein.")

        for entry in entries:
            mapping(entry, "software", (
                "name", "enabled", "paths", "optional_paths",
                "max_backups", "archiving_method", "rsync",
            ))
            jobs.append({"enabled": False, **entry, "type": "software"})

    normalized = []
    seen = set()

    for job in jobs:
        allowed_settings = (
            "name",
            "type",
            "enabled",
            "source",
            "exclude",
            "max_backups",
            "archiving_method",
            "credentials_file",
            "databases",
            "dump_command",
            "consistency",
            "container",
            "containers",
            "compose_files",
            "include_mounts",
            "export_filesystem",
            "save_images",
            "paths",
            "optional_paths",
            "rsync",
        )

        mapping(job, "job", allowed_settings)

        common_settings = {
            "name", "type", "enabled", "max_backups", "archiving_method", "rsync",
        }
        settings_by_type = {
            "files": {"source", "exclude"},
            "mysql": {
                "credentials_file", "databases", "dump_command",
                "consistency", "container",
            },
            "docker": {
                "containers", "compose_files", "include_mounts",
                "export_filesystem", "save_images",
            },
            "software": {"paths", "optional_paths"},
            "full-server": set(),
        }

        kind = text(job.get("type"), "type")
        mapping(job, "job", common_settings | settings_by_type.get(kind, set()))

        job = {
            "enabled": True,
            "max_backups": general["max_backups"],
            "archiving_method": general["archiving_method"],
            **job,
        }

        job_name = name(job.get("name"), "job.name")

        if job_name.casefold() in seen or job_name.casefold() in RESERVED_NAMES:
            raise ConfigError("Doppelter oder reservierter Jobname.")

        seen.add(job_name.casefold())
        boolean(job["enabled"], "enabled")
        number(job["max_backups"], "max_backups")

        if job["archiving_method"] not in ARCHIVES:
            raise ConfigError("Ungültige Archivmethode.")

        kind = job.get("type")

        if kind == "files":
            job["source"] = local_path(job.get("source"), root, "source")

            destinations = (
                general["backup_directory"],
                general["log_directory"],
                str(root / "state"),
            )

            for destination in destinations:
                if Path(destination).is_relative_to(Path(job["source"])):
                    raise ConfigError(f"{job_name}: Backup-/Log-/Statusordner liegt in der Quelle.")

            job["exclude"] = string_list(job.get("exclude", []), "exclude")

        elif kind == "software":
            for key in ("paths", "optional_paths"):
                values = string_list(job.get(key, []), key)
                job[key] = [local_path(value, root, key) for value in values]

                for path in job[key]:
                    destinations = (
                        general["backup_directory"],
                        general["log_directory"],
                        str(root / "state"),
                    )

                    if any(Path(destination).is_relative_to(path) for destination in destinations):
                        raise ConfigError(f"{job_name}: Software-Pfad enthält einen Ausgabeordner.")

            if not job["paths"] and not job["optional_paths"]:
                raise ConfigError(f"{job_name}: mindestens einen Software-Pfad angeben.")

        elif kind == "mysql":
            job["credentials_file"] = secret_path(
                job.get("credentials_file"),
                root,
                check_secrets and job["enabled"],
            )

            job["databases"] = string_list(job.get("databases", []), "databases")

            for database in job["databases"]:
                if database.startswith("-"):
                    raise ConfigError("Datenbanknamen dürfen nicht mit '-' anfangen.")

            job["dump_command"] = job.get("dump_command", "mysqldump")

            if job["dump_command"] not in ("mysqldump", "mariadb-dump"):
                raise ConfigError("dump_command: mysqldump oder mariadb-dump verwenden.")

            job["consistency"] = job.get("consistency", "single-transaction")

            if job["consistency"] not in ("single-transaction", "lock-all-tables"):
                raise ConfigError("consistency: single-transaction oder lock-all-tables verwenden.")

            job["container"] = text(job.get("container", ""), "container", empty=True)

            if job["container"] and not CONTAINER_NAME.fullmatch(job["container"]):
                raise ConfigError("Ungültiger Datenbank-Containername.")

        elif kind == "docker":
            compose_files = string_list(job.get("compose_files", []), "compose_files")

            job["compose_files"] = [
                local_path(path, root, "compose_files")
                for path in compose_files
            ]

            job["containers"] = string_list(job.get("containers", []), "containers")

            if not job["containers"] or len(set(job["containers"])) != len(job["containers"]):
                raise ConfigError("containers muss eindeutige Container-Namen enthalten.")

            for container in job["containers"]:
                if not CONTAINER_NAME.fullmatch(container):
                    raise ConfigError("Ungültiger Container-Name.")

            docker_defaults = {
                "include_mounts": True,
                "export_filesystem": False,
                "save_images": False,
            }

            for key, default in docker_defaults.items():
                job[key] = boolean(job.get(key, default), key)

        elif kind == "full-server":
            if job_name != "Root-Server" or job["archiving_method"] != "tar.zst":
                raise ConfigError("Ungültiger interner Root-Server-Job.")

        else:
            raise ConfigError(f"{job_name}: type muss files, mysql, docker oder software sein.")

        normalized.append(job)

    transfers = load_transfers(root, raw.get("rsync", {}), general, normalized, check_secrets)

    return {
        "general_settings": general,
        "encryption": encryption,
        "jobs": normalized,
        "transfers": transfers,
    }


def load_transfers(root, raw, general, jobs, check_secrets=False):
    defaults = {
        "credentials_file": "rsync.yml",
        "dry_run": False,
        "timeout_seconds": 300,
    }
    mapping(raw, "rsync", defaults)
    settings = {**defaults, **raw}
    boolean(settings["dry_run"], "dry_run")
    number(settings["timeout_seconds"], "timeout_seconds", 1, 86400)
    credentials = secret_path(settings["credentials_file"], root, check=False)
    result = []
    destinations = []

    for job in jobs:
        job_defaults = {
            "enabled": False,
            "destination": f"Backups/{job['name']}",
            "keep_backups": 30,
            "delete_local_after_transfer": False,
        }
        options = job.get("rsync", {})
        mapping(options, f"{job['name']}.rsync", job_defaults)
        options = {**job_defaults, **options}
        boolean(options["enabled"], "rsync.enabled")
        boolean(options["delete_local_after_transfer"], "delete_local_after_transfer")
        number(options["keep_backups"], "keep_backups")
        options["destination"] = remote_path(options["destination"])
        job["rsync"] = options

        if not options["enabled"] or not job["enabled"]:
            continue

        if check_secrets:
            secret_path(settings["credentials_file"], root)
        folder = {
            "job": job["name"],
            "source": str(Path(general["backup_directory"]) / job["name"]),
            "destination": options["destination"],
            "keep_backups": options["keep_backups"],
            "delete_local_after_transfer": options["delete_local_after_transfer"],
            "dry_run": settings["dry_run"],
            "timeout_seconds": settings["timeout_seconds"],
            "credentials_file": credentials,
        }
        dest = PurePosixPath(folder["destination"])

        if any(dest.is_relative_to(old) or old.is_relative_to(dest) for old in destinations):
            raise ConfigError("Rsync-Zielordner dürfen sich nicht überlappen.")

        destinations.append(dest)
        result.append(folder)

    return result


def select(config, selectors, kind=None):
    known_jobs = {job["name"].casefold() for job in config["jobs"]}
    known = set(known_jobs)
    known.update(folder["job"].casefold() for folder in config["transfers"])
    wanted = {item.casefold() for item in selectors}

    if wanted - known:
        raise ConfigError("Unbekannte Backup-Auswahl. Verfügbare Namen: --list.")

    config["jobs"] = [
        job
        for job in config["jobs"]
        if job["enabled"]
        and (wanted or job["type"] != "full-server")
        and (not wanted or job["name"].casefold() in wanted)
        and (not kind or job["type"] == kind)
    ]

    job_names = {job["name"].casefold() for job in config["jobs"]}

    config["transfers"] = [
        folder
        for folder in config["transfers"]
        if (not wanted or folder["job"].casefold() in wanted)
        and (not kind or folder["job"].casefold() in job_names)
        and (folder["job"].casefold() not in known_jobs or folder["job"].casefold() in job_names)
    ]

    return config


def get_value(path, key):
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)

    for part in key.split("."):
        value = value[int(part)] if isinstance(value, list) else value[part]

    return value


def main():
    action = sys.argv[1]

    if action == "json":
        arguments = sys.argv[2:]
        if len(arguments) % 2:
            raise ConfigError("JSON-Felder müssen Schlüssel/Wert-Paare sein.")
        values = dict(zip(arguments[::2], arguments[1::2]))
        print(json.dumps(values, ensure_ascii=False, indent=2))
        return

    if action in ("get", "list", "length"):
        value = get_value(sys.argv[2], sys.argv[3])

        if action == "list":
            for item in value:
                sys.stdout.buffer.write(str(item).encode() + b"\0")

        elif action == "length":
            print(len(value))

        else:
            print(str(value).lower() if isinstance(value, bool) else value)

        return

    root, config_file, kind, *selectors = sys.argv[2:]
    config = load_config(root, config_file or None)

    if action == "inventory":
        print(json.dumps(config, ensure_ascii=False))
    elif action == "plan":
        selected = select(config, selectors, kind or None)
        print(json.dumps(selected, ensure_ascii=False))
    else:
        raise ConfigError("Unbekannte Config-Aktion.")


if __name__ == "__main__":
    try:
        main()

    except (ConfigError, OSError, KeyError, IndexError) as error:
        print(f"FEHLER: {error}", file=sys.stderr)
        sys.exit(2)
