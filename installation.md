# Installation und Betrieb

[← Zurück zur Hauptdokumentation](Readme.md)

> Schritt-für-Schritt-Anleitung für Installation, Prüfung, Zeitplanung, Aktualisierung und Entfernung von Le-Backup Manager.

Le-Backup Manager läuft ausschließlich als root auf Linux. Der Installer legt keine Benutzer, Dienste oder Cronjobs an und installiert keine Pakete ungefragt.

> [!IMPORTANT]
> Sämtliche Pfade, Jobnamen und Zeitpläne in dieser Anleitung sind neutrale Beispiele. Vor dem ersten produktiven Lauf müssen Config, Quellen, Empfänger und Remote-Ziele vollständig geprüft werden.

## Inhalt

- [Voraussetzungen](#voraussetzungen)
- [Installation einrichten](#installation-einrichten)
- [tmux oder screen](#tmux-oder-screen)
- [Root-Crontab](#root-crontab)
- [Aktualisieren](#aktualisieren)
- [Entfernen](#entfernen)
- [Wiederherstellen](#wiederherstellen)

## Voraussetzungen

### Automatisch prüfen

```bash
sudo bash install.sh check
```

Die Prüfung verändert das System nicht. Sie nennt fehlende Programme samt Paketnamen und einem Installationsbeispiel für Debian/Ubuntu.

### Benötigte Komponenten

| Komponente | Wann benötigt |
| --- | --- |
| Bash | Immer |
| Python ab 3.9 und PyYAML | Immer, zum sicheren Lesen der Konfiguration |
| `flock` aus util-linux | Immer, für die Laufsperre |
| `age` | Immer, für die verpflichtende Archivverschlüsselung |
| tmux oder screen | Für Hintergrundläufe und `--wait` |
| Archivprogramme | Abhängig von `zip`, `tar`, `gzip`, `bzip2` oder `zstd` |
| MariaDB-/MySQL-Client | Für native Datenbank-Dumps |
| Docker-CLI | Für Docker-Jobs und Container-Dumps |
| Rsync und OpenSSH | Für Remote-Übertragungen |
| `sshpass` | Nur bei SSH-Passwortanmeldung |

Im Detail gelten folgende Abhängigkeiten:

- `tmux` oder `screen` ab Version 4.2.
- `tar`, `gzip` und `sha256sum` bzw. `shasum`.
- `age` für die verpflichtende Public-Key-Verschlüsselung aller neuen Archive.
- Bei ZIP zusätzlich `zip` und `unzip`; bei anderer Kompression `bzip2` oder `zstd`.
- `zstd` wird immer geprüft, weil das manuelle Root-Server-Backup fest `tar.zst` mit Ultra Stufe 22 verwendet.
- `mysqldump` oder `mariadb-dump` für native SQL-Dumps.
- Docker-CLI für Docker-Jobs; bei Container-Dumps muss das Dump-Programm im Container installiert sein.
- Rsync ab 3.0 und OpenSSH-Client für Übertragungen; bei Passwortanmeldung zusätzlich `sshpass`.

Auf dem Storage-Server werden Rsync und SSH sowie `mkdir`, `chmod`, `ls` und `rm` benötigt. Die lokale Paketprüfung prüft keine Remote-Programme. Bei fehlendem Python/PyYAML zuerst diese Grundlage installieren und die Prüfung wiederholen; erst danach kann die YAML-Config ausgewertet werden.

## Installation einrichten

### 1. Vorlagen konfigurieren

Vor der Installation die Job-Pfade in `config/config.yml` und die benötigten Einträge in `config/software.yml` einstellen. Der öffentliche `age`-Empfängerschlüssel, SQL- und SSH-Dateien liegen unter `secrets/`; die Schritt-für-Schritt-Anleitung für Verschlüsselungs- und SSH-Schlüssel steht in [secrets/Readme.md](secrets/Readme.md).

`Readme.md` und `installation.md` sind optionale Dokumentationsdateien. Installation, Update und Rechtekorrektur funktionieren ohne beide Dateien. Vorhandene Dokumentation wird mitkopiert; fehlt sie im Update, bleibt bereits installierte Dokumentation erhalten.

Der Quellordner und die Installation haben unterschiedliche Aufgaben. Im Quellordner bleiben `install.sh`, `code/installer/` und der jeweils neue Programmstand. In die Installation werden nur `create-backup.sh`, der benötigte Shell-/Python-Laufzeitcode, Config, Secrets und optionale Dokumentation übernommen. Reine Installerdateien werden dort nicht abgelegt; ein Update entfernt sie auch aus älteren Installationen.

### 2. Installieren

```bash
sudo bash install.sh install --target /opt/backup-manager
```

### 3. Erste Prüfung durchführen

```bash
sudo -i
cd /opt/backup-manager
bash create-backup.sh --check
```

Wenn mindestens ein Rsync-Ziel aktiviert wurde, anschließend den SSH-Hostschlüssel unabhängig verifizieren und speichern:

```bash
bash create-backup.sh --setup-ssh-host
```

### 4. Erstes Backup starten

```bash
bash create-backup.sh --wait
```

`install.sh check` prüft Config und Pakete, ohne ein Backup zu erstellen. `create-backup.sh --check` prüft zusätzlich lokale Quellen und Zugangsdaten-Dateien, baut aber keine SSH-Verbindung auf. `--setup-ssh-host` liest Host und Port aus der aktuellen Installation, zeigt den SSH-Fingerabdruck zur unabhängigen Prüfung und speichert ihn erst nach ausdrücklicher Bestätigung. Docker-Daemon und SQL-Anmeldung werden erst bei der tatsächlichen Sicherung verwendet.

Der Installer setzt root als Besitzer: Installationsordner, Unterordner und Shell-Scripts erhalten `700`, übrige Dateien einschließlich Secrets `600`. Auch bei Updates werden diese Rechte gesetzt. Symlinks, Hardlinks und Spezialdateien in Installationsdateien werden abgewiesen.

Normale Benutzer können diese Dateien damit nicht lesen, ändern oder kopieren. Root, sudo-Berechtigte und Prozesse mit vergleichbaren Rechten können nicht ausgesperrt werden. Dateirechte entfernen außerdem keine früher angefertigten Kopien. Das System und seine Archive nicht in öffentlich ausgelieferten Webordnern ablegen.

Externe Quelldaten werden nicht verändert. Backup-, Status- und Logordner werden privat angelegt. Bereits vorhandene Ausgabeordner müssen root gehören.

### Installation ohne Kopieren verwenden

Direkter Betrieb aus einem eigenen Ordner ist ebenfalls möglich. Die Rechte dieses Ordners ausdrücklich korrigieren:

```bash
sudo bash install.sh permissions --target /absoluter/backup-manager
```

## tmux oder screen

In `config/config.yml`:

```yaml
general_settings:
  multiplexer: tmux
  session_name: backup-manager
```

Für Screen nur `multiplexer: screen` setzen. Die Änderung gilt beim nächsten Start, laufende Sessions werden nicht angefasst. Beim Start wird der passende Befehl zum Öffnen ausgegeben.

tmux verwendet `state/tmux.sock`; Screen verwendet das private Socket-Verzeichnis `state/screen`. Lösen ohne Abbruch: tmux mit Strg+B, dann D; Screen mit Strg+A, dann D. Die Session endet nach Abschluss der Sicherung.

## Root-Crontab

Beispiele werden auch direkt angezeigt:

```bash
sudo bash install.sh cron --target /opt/backup-manager
sudo crontab -e
```

Täglich um 03:00 Uhr alle aktiven Jobs:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * /bin/bash /opt/backup-manager/create-backup.sh --wait
```

Alternativ alle sechs Stunden nur den Beispieljob `ApplicationData`:

```cron
0 */6 * * * /bin/bash /opt/backup-manager/create-backup.sh --wait -ApplicationData
```

Oder täglich um 04:30 Uhr zwei ausgewählte Jobs:

```cron
30 4 * * * /bin/bash /opt/backup-manager/create-backup.sh --wait -MySQL -Nginx
```

Das besonders rechenintensive Root-Server-Backup beispielsweise sonntags um 01:00 Uhr:

```cron
0 1 * * 0 /bin/bash /opt/backup-manager/create-backup.sh --wait --full-server
```

Die Beispiele sind Alternativen; nur gewünschte Zeitpläne eintragen. In der Benutzer-Crontab steht nach den fünf Zeitfeldern direkt der Befehl, kein zusätzliches `root`. `--wait` startet weiterhin im gewählten Multiplexer und liefert Cron das Ergebnis. Überlappende Läufe werden mit Exitcode 75 abgewiesen, nicht in eine Warteschlange gestellt. Status und Protokolle regelmäßig kontrollieren; Cron-Mail benötigt eine eigene Mail-Konfiguration.

## Aktualisieren

Aus dem Quellordner mit dem neuen Programmstand:

```bash
sudo bash install.sh update --target /opt/backup-manager
```

Nach einer erfolgreichen Installation oder Aktualisierung merkt sich der Installer den Zielpfad in `/var/lib/le-backup-manager/installation-target`. Danach genügt `sudo bash install.sh update`; im Menü kann die Pfadangabe mit Enter übernommen werden. Ein ausdrücklich angegebenes `--target` hat immer Vorrang. Beim Entfernen der gemerkten Installation wird auch dieser Eintrag gelöscht.

Config-Inhalte, Secrets, Backups und Logs werden nicht überschrieben. Deshalb muss bei einer bestehenden Installation der öffentliche Schlüssel separat als `secrets/age-recipients.txt` im Installationsordner abgelegt werden; ein Update kopiert ihn nicht über vorhandene Secrets. Fehlt der Schlüssel, verhindert die Vorprüfung jedes neue Backup. Abweichende Rechte von `state/` und `state/manager.lock` werden beim Update automatisch auf `700` und `600` korrigiert. Der vorige Programmcode bleibt geschützt unter `.previous-code.*` erhalten. Die neue Config-Struktur muss bei bestehenden Installationen vor dem Update manuell übernommen werden: Rsync steht jetzt bei den Jobs in `config.yml`, nicht mehr in `rsync-config.yml`. Der Installer prüft die vorhandene Config vor dem Austausch.

Bei einem laufenden Backup oder einer vorhandenen Screen- bzw. aktiven tmux-Session wird die Änderung abgewiesen. Verwaiste Screen-Sockets ausschließlich nach Prüfung mit `SCREENDIR=/opt/backup-manager/state/screen screen -wipe` entfernen.

## Entfernen

```bash
sudo bash install.sh remove --target /opt/backup-manager
```

Die Bestätigung bzw. `--yes` erlaubt das Entfernen der Installation einschließlich Configs und Secrets. Laufende Backups werden nicht beendet; der Installer verweigert dann die Entfernung.

Externe Backups und Logs bleiben unberührt. Innerhalb der Installation konfigurierte Backup-/Logordner werden in den benachbarten Ordner `backup-manager.data-*` verschoben und erhalten. Eigene Cron-Einträge anschließend selbst entfernen.

## Wiederherstellen

Archive zuerst mit dem offline verwahrten privaten `age`-Schlüssel entschlüsseln und anschließend in einen separaten Testordner entpacken:

```bash
age --decrypt --identity /SICHERER/PFAD/le-backup-identity.txt \
  --output backup.tar.zst backup.tar.zst.age
tar --zstd -tf backup.tar.zst
```

SQL-Dumps liegen nach dem Entpacken unter `data/databases.sql` und können beim Import vorhandene Daten ersetzen; deshalb zunächst eine isolierte Testdatenbank verwenden.

Docker über die gesicherten Compose-Dateien neu aufsetzen und Nutzdaten anhand von `inspect.json` den Volumes/Bind-Mounts zuordnen. Die Backup-Software stellt absichtlich nichts automatisch in laufenden Anwendungen wieder her.
