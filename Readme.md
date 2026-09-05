# Le-Backup Manager

> Ein modularer Backup-Manager für Linux-Server mit verschlüsselten Datei-, Datenbank-, Docker- und System-Backups.

Le-Backup Manager erstellt reproduzierbare Backups über konfigurierbare Jobs. Archive werden geprüft, mit [`age`](https://github.com/FiloSottile/age) verschlüsselt und optional per Rsync auf einen entfernten Storage übertragen. Anwendungen und Container bleiben während des gesamten Ablaufs aktiv: Das Programm beendet, pausiert oder startet keine Dienste.

## Funktionen auf einen Blick

| Bereich | Unterstützung |
| --- | --- |
| Dateien und Verzeichnisse | Frei definierbare Quellen, Ausschlussmuster und Aufbewahrung |
| MySQL und MariaDB | Konsistente SQL-Dumps, lokal oder aus einem Docker-Container |
| Docker | Compose-Dateien, Container-Metadaten, Volumes und Bind-Mounts |
| Linux-Konfiguration | Einzelne Jobs für Webserver, SSH, Firewall, VPN, Monitoring und weitere Dienste |
| Gesamtsicherung | Manuelles Root-Dateisystem-Backup als stark komprimiertes `tar.zst`-Archiv |
| Verschlüsselung | Verpflichtende Public-Key-Verschlüsselung mit einem oder mehreren `age`-Empfängern |
| Remote-Storage | Rsync über SSH, strikte Hostschlüsselprüfung und Prüfsummenvergleich |
| Automatisierung | Ausführung im Vordergrund, in tmux/screen oder über die Root-Crontab |
| Sicherheit | Private Arbeitsordner, restriktive Rechte, Laufsperre und keine Secrets in Prozessargumenten |

## So funktioniert ein Backup-Lauf

1. Config, Programme, Quellen und Secret-Dateien werden vorab geprüft.
2. Der ausgewählte Job liest die konfigurierten Daten, ohne den Dienstlebenszyklus zu verändern.
3. Die Daten werden in einem privaten Arbeitsordner archiviert und auf Lesbarkeit geprüft.
4. Das fertige Archiv wird mit den öffentlichen `age`-Empfängern verschlüsselt.
5. Eine `.meta.json` speichert Größe, Format, Abschlusszeit und SHA-256-Prüfsumme.
6. Bei aktiviertem Rsync folgen Upload und ein zweiter Vergleich mit `--checksum`.
7. Erst nach erfolgreicher Prüfung greifen Remote-Aufbewahrung und optionales lokales Löschen.

> [!IMPORTANT]
> Alle mitgelieferten Namen, Pfade, Hosts, Ports und Zielordner sind neutrale Beispiele. Sämtliche Jobs sind standardmäßig deaktiviert und müssen vor dem ersten Lauf bewusst an die eigene Umgebung angepasst werden.

> [!CAUTION]
> Der private `age`-Schlüssel gehört nicht auf den Backup- oder Storage-Server. Ohne eine getrennt verwahrte Kopie dieses Schlüssels können verschlüsselte Archive nicht wiederhergestellt werden.

## Dokumentation

| Dokument | Inhalt |
| --- | --- |
| [Installation](installation.md) | Voraussetzungen, Installation, Rechte, Cron, Update und Entfernung |
| [Secrets und Verschlüsselung](secrets/Readme.md) | `age`, MariaDB-Zugang, SSH, `known_hosts` und Rsync-Anmeldung |
| [`config/config.yml`](config/config.yml) | Neutrale Vorlage für Datei-, SQL-, Docker- und Full-Server-Jobs |
| [`config/software.yml`](config/software.yml) | Optionale Vorlagen für native Linux-Dienste |

## Schnellstart

### 1. Voraussetzungen prüfen

```bash
sudo bash install.sh check
```

### 2. Vorlagen anpassen

- Jobs in `config/config.yml` konfigurieren und gezielt aktivieren.
- Optional benötigte Dienste in `config/software.yml` aktivieren.
- Öffentliche `age`-Empfänger und benötigte Zugangsdaten unter `secrets/` einrichten.

### 3. Installieren

```bash
sudo bash install.sh install --target /opt/backup-manager
```

### 4. Installation prüfen und starten

Als root im Ordner mit `create-backup.sh`:

```bash
cd /opt/backup-manager
bash create-backup.sh --list
bash create-backup.sh --check
bash create-backup.sh --wait
```

Bei aktivierter Rsync-Übertragung muss vor dem ersten Lauf zusätzlich der SSH-Hostschlüssel geprüft und gespeichert werden:

```bash
bash create-backup.sh --setup-ssh-host
```

### Wichtige Befehle

| Aufgabe | Befehl |
| --- | --- |
| Jobs anzeigen | `bash create-backup.sh --list` |
| Konfiguration prüfen | `bash create-backup.sh --check` |
| Alle aktiven Jobs starten | `bash create-backup.sh --wait` |
| Bestimmten Job starten | `bash create-backup.sh --wait -ApplicationData` |
| Mehrere Jobs starten | `bash create-backup.sh --wait -MySQL -Docker` |
| Nur einen Jobtyp starten | `bash create-backup.sh --wait --type mysql` |
| Nur vorhandene Archive übertragen | `bash create-backup.sh --wait --rsync-only -ApplicationData` |
| Laufstatus anzeigen | `bash create-backup.sh --status` |
| Gesamten Root-Server sichern | `bash create-backup.sh --wait --full-server` |

Jeder Job ist über seinen frei konfigurierten `name` auswählbar. Groß-/Kleinschreibung wird bei der Auswahl ignoriert. Namen bestehen aus Buchstaben, Zahlen, `_` und `-`, ohne Leerzeichen.

```bash
bash create-backup.sh -ApplicationData
bash create-backup.sh -MySQL -Docker
bash create-backup.sh --type mysql
bash create-backup.sh --rsync-only -ApplicationData
```

`ApplicationData`, `MySQL` und `Docker` sind neutrale Beispiele aus der Config, keine fest verdrahteten Auswahlmöglichkeiten. Mit jedem weiteren Jobnamen entsteht automatisch ein weiterer Auswahlparameter.

`--foreground` führt das Backup direkt aus. `--wait` startet im gewählten Multiplexer und wartet auf das Ergebnis. Ohne diese Optionen bestätigt der Aufruf nur den Start der Hintergrundsession. Das Ergebnis steht anschließend unter `state/latest.json` und ist über `--status` abrufbar. Ein erfolgreicher direkter/wartender Lauf liefert Exitcode `0`, ein Fehler einen anderen Code; `75` bedeutet, dass die Laufsperre bereits belegt ist.

Die beim Start ausgegebene Anweisung öffnet die laufende Session. Mit `Strg+B`, danach `D` lässt sich tmux verlassen, ohne das Backup abzubrechen; bei Screen mit `Strg+A`, danach `D`. Die Session endet nach dem Backup. Pro Installation läuft höchstens ein Backup gleichzeitig.

### Ohne tmux oder screen starten

```bash
bash create-backup.sh --foreground
bash create-backup.sh --foreground -MySQL
bash create-backup.sh --foreground --rsync-only
```

`--foreground` startet direkt im aktuellen Terminal und benötigt weder tmux noch screen. Jobauswahl, Protokolle und Fehlerprüfung bleiben gleich. Das Terminal bzw. die SSH-Verbindung während des Laufs geöffnet lassen; dieser Modus bietet keinen Schutz gegen einen Verbindungsabbruch. Ohne `--foreground` wird weiterhin der konfigurierte Multiplexer verwendet.

### tmux-Session anzeigen und öffnen

Das Backup verwendet einen eigenen tmux-Socket unter `state/tmux.sock`. Deshalb zeigen `tmux ls` und `tmux a -t backup-manager` ohne `-S` diese Backup-Session nicht an: Sie greifen auf den Standard-Socket zu.

Als root die Backup-Sessions anzeigen:

```bash
tmux -S /opt/backup-manager/state/tmux.sock ls
```

Die laufende Backup-Session öffnen:

```bash
tmux -S /opt/backup-manager/state/tmux.sock attach -t backup-manager
```

Bei einem anderen Installationsordner den Pfad entsprechend anpassen. Der Sessionname `backup-manager` entspricht `general_settings.session_name` in `config/config.yml`. Beim Backup-Start wird der passende Öffnen-Befehl mit dem tatsächlich verwendeten Pfad und Namen ausgegeben.

Zum Verlassen ohne Abbruch `Strg+B` drücken, loslassen und danach `D` drücken. Keine Session mehr vorhanden? Der Backup-Prozess kann bereits erfolgreich oder mit einem Fehler beendet worden sein. Das letzte Ergebnis anzeigen:

```bash
bash /opt/backup-manager/create-backup.sh --status
```

### Status und Protokolle

Meldungen tragen den Prefix `[Le-Backup]` und ein Level: `INFO`, `WARN`, `FEHLER` oder `AUSGABE` für sonstige Programmmeldungen. Angezeigt werden der aktuelle Job, Archivierung, SQL-Dump, Archivprüfung, Rsync-Upload, Remote-Vergleich und Aufbewahrung. Die normalen Dateilisten der Archivprogramme werden nicht ausgegeben. Warnungen und Fehlermeldungen bleiben sichtbar.

Konsole und Log verwenden dasselbe Format, ohne Datum vor jeder Meldung. Das Datum steht im Logdateinamen:

```text
[Le-Backup] 19:50:07 : [INFO] Backup-Lauf gestartet.
```

Während längerer Schritte erscheint standardmäßig alle 30 Sekunden eine Meldung mit der bisherigen Laufzeit. `general_settings.progress_interval_seconds` ändert dieses Intervall; `0` schaltet die regelmäßigen Meldungen aus. Die Zähler zeigen abgeschlossene Jobs bzw. Übertragungen, keinen geschätzten Byte-Fortschritt.

Mit `general_settings.write_logs: true` stehen die Laufmeldungen und Programmdiagnosen sowohl in der Konsole als auch in der Logdatei. Der Logpfad wird beim Start angezeigt. Fehler enthalten den betroffenen Job und Exitcode; bei Rsync zusätzlich den fehlgeschlagenen Schritt. Die Vorprüfung findet vor dem Anlegen des Laufprotokolls statt und meldet ihre Fehler direkt in der Startkonsole. Bei ausgeschaltetem Dateiprotokoll wird ausdrücklich darauf hingewiesen.

`--status` funktioniert auch während eines laufenden Backups und zeigt Phase, aktuellen Job, Zähler und Logpfad als JSON. Für die laufenden Textausgaben die tmux-/screen-Session öffnen oder die angegebene Logdatei mit `tail -f` verfolgen.

## Verschlüsselung

Die Verschlüsselung ist für neue Backups verpflichtend und kann nicht pro Job ausgeschaltet werden. `config/config.yml` verweist lediglich auf eine Empfängerdatei unter `secrets/`:

```yaml
encryption:
  recipient_file: age-recipients.txt
```

Diese Datei enthält einen oder mehrere öffentliche `age`-Schlüssel. Der private Schlüssel gehört nicht auf den Backup-Server oder Storage-Server, sondern in mindestens zwei getrennte, sichere Offline-Kopien. Ohne privaten Schlüssel können die Archive nicht wiederhergestellt werden. Die vollständige [Schlüsselanleitung](secrets/Readme.md) beschreibt Erzeugung, Einrichtung, Prüfung und Entschlüsselung.

Das normale Archiv wird zuerst in einem privaten Arbeitsordner erstellt und geprüft. Danach verschlüsselt `age` es; nur die fertige `.age`-Datei wird in den Backup-Ordner verschoben und für Rsync ausgewählt. Während der Verschlüsselung existieren das komprimierte Arbeitsarchiv und die verschlüsselte Ausgabe gleichzeitig. Deshalb wird vorübergehend ungefähr zusätzlicher Speicher in Größe des komprimierten Archivs benötigt. Bei einem regulären Fehler oder Abbruch wird der Arbeitsordner entfernt. Nach einem Stromausfall oder `SIGKILL` kann ein geschützter `.incomplete-*`-Arbeitsordner zurückbleiben und muss vor einer Weitergabe des Datenträgers geprüft werden.

## Archivnamen und Begleitdateien

Neue Archive heißen beispielsweise `2026-09-05-1-ApplicationData.zip.age`: Datum, fortlaufende ID, Jobname, Archivendung und die Verschlüsselungsendung `.age`. Das Datum entspricht dem lokalen Kalendertag beim Start des Laufs. Die ID beginnt pro Job und Tag bei `1`; weitere Backups erhalten `2`, `3` usw. Logdateien verwenden einen eigenen Tageszähler, beispielsweise `2026-09-05-1-backup.log`.

Die Zähler liegen unter `state/names/` und bleiben bei Updates erhalten. Diesen Ordner nicht zurücksetzen: Bereits reservierte IDs werden auch nach einem Abbruch oder einer lokalen Löschung nicht erneut vergeben.

Zu jedem fertigen Archiv gehört eine `.meta.json`, beispielsweise `2026-09-05-1-ApplicationData.zip.age.meta.json`. Sie enthält Jobname, Archivname, ursprüngliches Archivformat, Verschlüsselungsverfahren, Größe, Abschlusszeit und SHA-256-Prüfsumme der verschlüsselten Datei, aber keine gesicherten Nutzdaten oder privaten Schlüssel. Das System verwendet sie zur Erkennung abgeschlossener Archive und zur Prüfung vor einer automatischen lokalen Löschung. Archiv und Begleitdatei zusammen aufbewahren. Vor dem Entpacken muss das Archiv mit dem privaten `age`-Schlüssel entschlüsselt werden.

Bestehende unverschlüsselte Archive im vorherigen Format `ApplicationData_20260904T170223Z-22766.zip` werden nicht verändert. Die lokale Aufbewahrung erkennt sie weiterhin, Rsync wählt sie jedoch nicht mehr für einen neuen Upload aus. Damit überträgt das aktualisierte System keine unverschlüsselten Altarchive. Diese müssen bei Bedarf separat verschlüsselt oder nach geprüfter Ablösung entfernt werden.

## Einstellungen

`config/config.yml` enthält Grundeinstellungen, Jobs und deren Rsync-Ziele. `config/software.yml` enthält separat aktivierbare native Software; auch dort kann jeder Eintrag einen eigenen `rsync`-Abschnitt erhalten. Relative lokale Pfade beziehen sich immer auf den Ordner von `create-backup.sh`, nicht auf das aktuelle Terminalverzeichnis.

Jeder Job hat `name`, `type` und `enabled`. Die Archivmethode und `max_backups` werden aus `general_settings` übernommen, lassen sich aber pro Job überschreiben. Unterstützt werden `zip`, `tar`, `tar.gz`, `tar.bz2` und `tar.zst`.

### Dateien

`type: files` sichert eine Datei oder einen Ordner aus `source`. `exclude` enthält Archivmuster, beispielsweise `['application-data/logs/*']`; der äußerste Quellordner ist Teil des Archivpfads. Symlinks werden nicht als Aufforderung zum rekursiven Kopieren ihres Ziels behandelt.

Dateien, die während der Sicherung geändert werden, können unterschiedliche Zeitstände haben. Anwendungen bleiben dennoch immer unangetastet. Meldet das Archivprogramm einen Fehler oder geänderte Dateien, wird der Job nicht als erfolgreich veröffentlicht.

### MySQL und MariaDB

`type: mysql` erstellt einen SQL-Dump mit Tabellen, Daten, Routinen, Triggern und Events. `databases: []` sichert alle Datenbanken; eine Liste beschränkt den Dump auf die angegebenen Datenbanken. Das Archiv enthält `data/databases.sql`, keine Kopie der Datenbankinstallation.

`dump_command` ist `mysqldump` oder `mariadb-dump`. Für eine lokale bzw. über das Netzwerk erreichbare Datenbank bleibt `container` leer. Für eine Datenbank in Docker wird dort der Containername eingetragen; das Dump-Programm muss dann im Container verfügbar sein. Der laufende Container erhält vorübergehend eine private Zugangsdaten-Datei, die beim normalen Ende und bei behandelbaren Abbrüchen entfernt wird.

Eine nativ installierte MariaDB kann ohne TCP über ihren lokalen Unix-Socket angesprochen werden. `secrets/mysql.cnf` darf dafür ohne Passwort so aussehen, sofern der MariaDB-Benutzer diese Anmeldung tatsächlich erlaubt:

```ini
[client]
user="backup"
protocol="socket"
```

Das ist nur eine alternative Konfiguration. Eine vorhandene Passwort-Konfiguration bleibt weiterhin unterstützt und wird vom Backup-System niemals verändert, bereinigt oder überschrieben. Auch andere Quelldateien werden während eines Backups ausschließlich gelesen. Enthalten sie Zugangsdaten, bleiben diese im Backup vollständig erhalten und werden durch die Archivverschlüsselung geschützt.

Ist nicht der Standard-Socket konfiguriert, kann zusätzlich `socket="/run/mysqld/mysqld.sock"` eingetragen werden. `protocol="socket"` wählt nur den Verbindungsweg; ob eine Anmeldung ohne Passwort zulässig ist, entscheidet die serverseitige Authentifizierung. Da das Backup-System als Betriebssystembenutzer root läuft, muss ein über das MariaDB-Plugin `unix_socket` angemeldetes Konto root ausdrücklich akzeptieren. Ein nur für den gleichnamigen Betriebssystembenutzer `backup` freigegebenes Konto würde den root-Prozess abweisen. [MariaDB-Dokumentation zu Unix-Socket-Authentifizierung](https://mariadb.com/docs/server/reference/plugins/authentication-plugins/authentication-plugin-unix-socket)

`consistency: single-transaction` ist der Standard: ein gemeinsamer Transaktionsstand für InnoDB ohne das Stoppen des Servers. Währenddessen keine Schemaänderungen wie `ALTER TABLE` durchführen. Nichttransaktionale Tabellen wie MyISAM haben diese Garantie nicht. Die optionale Einstellung `lock-all-tables` kann Schreibzugriffe blockieren und sollte nur bewusst eingesetzt werden. [MySQL-Dump-Dokumentation](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html)

### Docker-Nutzdaten und Compose

`type: docker` liest die in `containers` angegebenen Container. `include_mounts: true` kopiert ihre persistenten Volumes und Bind-Mounts. `compose_files` enthält die zugehörigen Compose-Dateien, Overrides und gegebenenfalls `.env`-Dateien. Diese Pfade werden ausdrücklich konfiguriert, nicht geraten.

```yaml
- name: Webdaten
  type: docker
  enabled: true
  containers:
    - mein-webserver
  compose_files:
    - /docker/web/compose.yml
    - /docker/web/.env
  include_mounts: true
  export_filesystem: false
  save_images: false
```

Das Archiv enthält `data/compose/` und pro Container `data/container-N/inspect.json` sowie `mount-N`. Die Zuordnung der Compose-Dateien steht in `compose/paths.tsv`, die Mountreihenfolge entspricht den persistenten Mounts in `inspect.json`.

Images und das Container-Dateisystem sind standardmäßig nicht enthalten. Sie können bei Bedarf ausdrücklich zugeschaltet werden. Ein Container-Export allein enthält keine Volume-Daten. [Docker-Export-Dokumentation](https://docs.docker.com/reference/cli/docker/container/export/)

Laufende Datenbankverzeichnisse nicht über diesen Dateikopierweg sichern: Für MySQL/MariaDB einen `mysql`-Job mit `container` verwenden. Der verbreitete Datenpfad `/var/lib/mysql` wird im Docker-Dateimodul ausdrücklich abgewiesen; beliebige abweichende Datenbankpfade können nicht automatisch erkannt werden. Andere laufend geänderte Anwendungsdateien bleiben Live-Kopien ohne garantierten gemeinsamen Zeitpunkt. `tmpfs` wird nicht gesichert.

Compose-Dateien, `.env`, SQL-Dumps und Docker-Metadaten können Passwörter enthalten. Deshalb gelten auch Backups als vertraulich.

### Native Server-Software

In `config/software.yml` stehen einzeln aktivierbare Pakete für native Server-Software, unter anderem Nginx, Apache, Fail2Ban und WireGuard. `paths` enthält notwendige Dateien/Ordner, `optional_paths` distributionsabhängige Ergänzungen. Fehlt ein notwendiger Pfad, schlägt die Vorprüfung fehl. Fehlen alle optionalen Pfade eines sonst leeren Jobs, wird kein leeres Backup als Erfolg ausgegeben.

Die Paketliste ist keine Installationsvoraussetzung: Nur tatsächlich verwendete Pakete aktivieren und Pfade auf dem eigenen Server prüfen. Datenbanken und andere Daten außerhalb der Config-Pfade sind nicht automatisch enthalten. Nicht benötigte Einträge können entfernt werden.

```bash
bash create-backup.sh -Nginx -Fail2Ban -WireGuard
bash create-backup.sh --type software
```

Nginx-VHosts liegen normalerweise innerhalb der gesicherten Nginx-Konfiguration. Extern eingebundene Dateien, Zertifikate und Webinhalte müssen bei Bedarf ergänzt werden. Symlink-Ziele außerhalb der gesicherten Pfade werden nicht automatisch kopiert. Das Archiv enthält die gewählten Pfade unter `data/files/`, beispielsweise `data/files/etc/nginx/`.

### Vollständiges Root-Server-Backup

Der Sonderjob wird ausschließlich über `--full-server` gestartet. Bei normalen Komplettläufen ist er nicht enthalten:

```bash
# Im konfigurierten tmux oder screen starten
bash create-backup.sh --full-server

# Direkt im aktuellen Terminal starten
bash create-backup.sh --foreground --full-server

# Nur vorhandene Root-Server-Archive übertragen
bash create-backup.sh --foreground --rsync-only --full-server
```

Das Archiv heißt beispielsweise `2026-09-05-1-Root-Server.tar.zst.age`. Die Archivart vor der Verschlüsselung ist fest auf `tar.zst` gesetzt. Zstandard läuft unveränderbar mit Ultra-Kompressionsstufe 22. Dies bietet die stärkste Zstd-Kompression, benötigt aber viel CPU, Arbeitsspeicher und Zeit. In der Config kann keine andere Archivart oder Kompressionsstufe eingetragen werden.

Fest ausgeschlossen sind `/opt`, `/root` und `/mnt`. Zusätzlich werden `/proc`, `/sys`, `/dev` und `/run` ausgelassen, da diese virtuellen Linux-Dateisysteme keine normalen Sicherungsdaten enthalten. Die Ausschlüsse sind nicht konfigurierbar. Andere Bereiche des Root-Dateisystems, darunter `/etc`, `/home`, `/srv`, `/usr` und `/var`, werden aufgenommen.

Das Backup liest den laufenden Server und beendet, pausiert oder startet keine Anwendung neu. Dateien können sich während der langen Sicherung verändern. Datenbanken sollten deshalb weiterhin über die vorgesehenen Dump-Jobs gesichert werden; ein enthaltenes laufendes Datenbankverzeichnis ersetzt keinen SQL-Dump.

Nur Aufbewahrung und Rsync-Ziel sind einstellbar:

```yaml
full_server_backup:
  max_backups: 2
  rsync:
    enabled: true
    destination: Server/Root-Server
    keep_backups: 3
    delete_local_after_transfer: false
```

## Rsync und Aufbewahrung

Die Rsync-Einstellungen stehen direkt unter dem jeweiligen Job. Es gibt keinen `mode` und keinen zweiten lokalen Quellpfad. Der Quellordner wird aus `general_settings.backup_directory` und dem Jobnamen ermittelt. Nur abgeschlossene, mit `age` verschlüsselte Archive und die zugehörige `.meta.json` werden übertragen; keine Rohdaten, unverschlüsselten Altarchive oder Zeitstempelordner.

```yaml
- name: ApplicationData
  type: files
  enabled: true
  source: /srv/example/application-data
  exclude: []
  max_backups: 10
  rsync:
    enabled: true
    destination: Examples/ApplicationData
    keep_backups: 60
    delete_local_after_transfer: false
```

`rsync.enabled: false` schaltet nur die Übertragung ab, nicht das lokale Backup. Fehlt der ganze Abschnitt, ist Rsync für diesen Job aus. `destination` ist ein eigener Ordner auf dem Storage-Server; relative Pfade beziehen sich auf das dortige SSH-Startverzeichnis. `keep_backups` zählt Remote-Archive, `max_backups` lokale Archive. `bash create-backup.sh -ApplicationData` erstellt und überträgt nur diesen Beispieljob. `--rsync-only -ApplicationData` überträgt vorhandene fertige Archive, ohne ein neues Backup zu erstellen.

Gemeinsame Verbindungseinstellungen stehen einmal oben in `config/config.yml`:

```yaml
rsync:
  credentials_file: rsync.yml
  dry_run: false
  timeout_seconds: 300
```

`credentials_file` ist relativ zu `secrets/`. Die [Anleitung für Passwort, SSH-Schlüssel und Hostprüfung](secrets/Readme.md) beschreibt die Einrichtung. `dry_run: true` simuliert nur Rsync: keine Remote-Ordner werden angelegt und keine Archive gelöscht. Der normale lokale Backup-Schritt ist davon unabhängig. Für einen aussagekräftigen Rsync-Testlauf muss der Remote-Zielordner bereits existieren.

Nach jedem echten Upload vergleicht ein zweiter Rsync-Testlauf die lokalen und entfernten Dateien mit `--checksum`. Erst ohne Unterschiede beginnt die Remote-Aufbewahrungsbereinigung. Bereits vorhandene Remote-Dateien werden beim Upload mit `--ignore-existing` nicht überschrieben. Enthält das Ziel unter demselben Namen andere Daten, schlägt der anschließende Vergleich fehl; lokale Archive bleiben erhalten und es erfolgt keine Remote-Bereinigung. Der Vergleich liest die Dateiinhalte und kann bei großen Archiven entsprechend dauern. [Rsync-Dokumentation](https://download.samba.org/pub/rsync/rsync.1)

### Backup nur auf dem Storage-Server behalten

Beim gewünschten Job `delete_local_after_transfer: true` setzen und ihn wie gewohnt mit `bash create-backup.sh -JOBNAME` starten. Das Archiv wird zunächst lokal erstellt; entsprechender Arbeits- und Archivspeicher wird weiterhin benötigt.

Zusätzlich zum Remote-Vergleich müssen die lokalen Archive vor der Übertragung und unmittelbar vor der Löschung zu ihren SHA-256-Metadaten passen. Erst nach erfolgreichem Upload, Inhaltsvergleich und Remote-Aufbewahrungsbereinigung werden exakt die übertragenen lokalen Archive samt Metadaten gelöscht. Bei Upload-, Prüf- oder Remote-Bereinigungsfehlern bleiben sie erhalten. `dry_run` löscht niemals lokale Archive.

Diese Einstellung ist standardmäßig aus. Sie löscht keine Quelldaten, fremden Dateien oder älteren, in diesem Lauf nicht übertragenen lokalen Archive. Zurückgebliebene Archive können mit `--rsync-only -JOBNAME` erneut übertragen und geprüft werden. Pro Lauf werden höchstens die neuesten `keep_backups` Archive ausgewählt. Eine einzige Remote-Kopie ersetzt keine zusätzliche unabhängige Sicherung.

Aufbewahrung löscht nur passende Backup-Dateinamen desselben Jobs im aktuellen oder vorherigen UTC-Laufkennungsformat. Lokal wird zusätzlich eine passende `.meta.json` verlangt; ältere Archive ohne diesen Nachweis bleiben bestehen. Bei Backup-/Übertragungsfehlern unterbleibt die lokale Aufbewahrungsbereinigung. Unvollständige Arbeitsdateien werden bei behandelbaren Abbrüchen entfernt; nach Stromausfall oder `SIGKILL` können private `.incomplete-*`-Ordner zurückbleiben. Im aktuellen Lauf übertragene Remote-Archive sind von der Bereinigung ausgenommen; bei ungewöhnlichen Zeitstempeln können daher vorübergehend mehr als `keep_backups` Archive vorhanden sein.

Backup-Ziele sollten leer bzw. ausschließlich für diese Sicherungen vorgesehen sein. Für Rsync-Transport sind SSH-Schlüssel und Passwortdateien möglich; Hostschlüssel werden strikt geprüft. Details stehen in `secrets/Readme.md`.

Den SSH-Hostschlüssel einmalig direkt aus der verwendeten Installation einrichten:

```bash
bash create-backup.sh --setup-ssh-host
```

Der Befehl verwendet automatisch deren `config/config.yml` und `secrets/rsync.yml`. Dadurch muss kein Installationspfad in einen langen SSH-Befehl kopiert werden.

### Storage-Ziele mit eingeschränkter SSH-Shell

Die Remote-Verwaltung sendet `mkdir`, `chmod`, `ls` und `rm` als einzelne SSH-Befehle. Eine vollständige Shell, `umask` oder Befehlsverkettungen auf dem Zielserver sind dafür nicht erforderlich. Damit eignet sich die Übertragung auch für viele Storage-Angebote mit eingeschränktem SSH-Zugang.

Neue Zielordner werden mit `mkdir -p -m 700` angelegt. Anschließend setzt ein separater `chmod 700` die Rechte des Zielordners auch dann, wenn er bereits existiert. Erst nach beiden erfolgreichen Schritten beginnt der Upload. Bei Fehlern bleiben die lokalen Archive erhalten. Übergeordnete, bereits vorhandene Remote-Ordner werden nicht umberechtigt. Die Anmeldung kann weiterhin mit Passwort oder SSH-Schlüssel erfolgen.

## Aufbau und Prüfung

```text
create-backup.sh          Einstieg, Hilfe und Laufsperre
install.sh               Nur im Quellordner: Installation und Aktualisierung
code/shell/manager.sh    Backup-Reihenfolge, Multiplexer, Ergebnis und Protokolle
code/shell/core/         Config-Zugriff, Vorprüfung, SSH und Aufbewahrung
code/shell/modules/      Dateien, SQL-Dumps, Docker und Rsync
code/installer/          Nur im Quellordner: Installation, Update und Entfernung
code/python/core/       Sicheres Lesen/Prüfen von YAML und JSON
code/python/integrations/ Docker-JSON und SSH-Zugangsdaten prüfen
config/                 Einstellbare Jobs und Transferziele
secrets/                Login-Dateien und SSH-Schlüssel
tests/                  Isolierte Funktions- und Sicherheitstests
```

```bash
bash tests/verify.sh
```

Die Tests erstellen echte lokale Archive und prüfen Shell-Syntax, Konfigurationsfehler, Jobauswahl, Sperren, Aufbewahrung und Installer. Docker, Datenbank-Clients und SSH/Rsync werden dabei durch Testprogramme ersetzt; produktive Systeme werden nicht kontaktiert. Dieses Shell-Projekt besitzt keinen Maven-Build.

Python ist auf drei Laufzeitdateien begrenzt: YAML-/JSON-Zugriff, SSH-Config-Prüfung und Docker-JSON-Prüfung. Ablaufsteuerung, Sicherungen, Installation und Übertragungen sind Shell. Leere `__init__.py` sind für diese Python-Namensraumpakete nicht erforderlich. Geschützte Original-Configs unter `secrets/migration-*` sind Benutzerdaten, kein Laufzeitcode, und werden nicht automatisch entfernt.

Die installierte Kopie enthält keinen Installer. Installation und Aktualisierung werden immer aus dem Quellordner gestartet. Der zuletzt erfolgreich verwendete Installationspfad wird geschützt unter `/var/lib/le-backup-manager/installation-target` gespeichert.
