# Verschlüsselung und Zugangsdaten

Dieser Ordner gehört root. Unterordner erhalten `700`, Dateien `600`; normale Benutzer haben damit keinen Zugriff. Root, sudo-Berechtigte und vergleichbar privilegierte Prozesse können durch diese Rechte nicht ausgesperrt werden. Auch fertige Archive können Passwörter enthalten und müssen privat bleiben. Sämtliche Namen, Hosts, Ports und Pfade in dieser Anleitung sind neutrale Beispiele und dürfen nicht als produktive Zugangsdaten übernommen werden.

`age-recipients.txt` enthält ausschließlich öffentliche Empfängerschlüssel für die Backup-Verschlüsselung. `mysql.cnf` enthält die SQL-Anmeldung. `rsync.yml` enthält den Storage-Host und die SSH-Anmeldung. Private SSH-Schlüssel, Passwortdateien und `known_hosts` liegen ebenfalls hier. Echte Secrets sind über Git-Ignore ausgeschlossen; bereits früher erfasste Dateien werden dadurch nicht nachträglich aus Git entfernt.

## Backup-Schlüssel für age

Der `age`-Schlüssel ist unabhängig von einem SSH-Schlüssel. Er verschlüsselt die Backup-Archive und wird nicht zur Anmeldung am Storage-Server verwendet.

### 1. Schlüsselpaar auf einem sicheren Rechner erzeugen

`age` auf einem vertrauenswürdigen Rechner installieren und dort ausführen:

```bash
umask 077
age-keygen -o le-backup-identity.txt
age-keygen -y le-backup-identity.txt > age-recipients.txt
chmod 600 le-backup-identity.txt age-recipients.txt
```

`le-backup-identity.txt` ist der private Schlüssel. Er darf weder auf den Backup-Server noch auf den Storage-Server kopiert werden. Mindestens zwei getrennte Offline-Kopien anlegen und anschließend eine Probeentschlüsselung durchführen. Geht dieser Schlüssel verloren, können die Backups nicht wiederhergestellt werden.

`age-recipients.txt` enthält nur den öffentlichen Schlüssel und darf zum Backup-System kopiert werden. Mehrere öffentliche Schlüssel können jeweils in einer eigenen Zeile stehen; jeder zugehörige private Schlüssel kann das Archiv unabhängig entschlüsseln. Das eignet sich beispielsweise für zwei getrennt verwahrte Wiederherstellungsschlüssel.

### 2. Öffentlichen Schlüssel hinterlegen

Bei einer bestehenden Installation den öffentlichen Schlüssel direkt in deren Secret-Ordner installieren:

```bash
sudo install -o root -g root -m 600 age-recipients.txt \
  /opt/backup-manager/secrets/age-recipients.txt
sudo chmod 700 /opt/backup-manager/secrets
```

Für spätere Neuinstallationen dieselbe öffentliche Datei zusätzlich im Quellordner unter `secrets/age-recipients.txt` ablegen. Der private Schlüssel bleibt außerhalb beider Ordner.

In `config/config.yml` muss dieser relative Dateiname stehen:

```yaml
encryption:
  recipient_file: age-recipients.txt
```

Die Empfängerdatei ist trotz ihres öffentlichen Inhalts mit `600` geschützt. Dadurch können normale Benutzer keinen eigenen Empfänger ergänzen, mit dem sie zukünftige Backups entschlüsseln könnten.

### 3. Einrichtung und Wiederherstellung prüfen

Auf dem Backup-Server:

```bash
cd /opt/backup-manager
bash create-backup.sh --check
bash create-backup.sh --foreground -JOBNAME
```

Danach ein erzeugtes `.age`-Archiv auf den sicheren Rechner kopieren und dort entschlüsseln:

```bash
age --decrypt --identity le-backup-identity.txt \
  --output test-backup.tar.zst 2026-09-05-1-Root-Server.tar.zst.age
tar --zstd -tf test-backup.tar.zst
```

Für ein ZIP-Backup entsprechend `--output test-backup.zip` verwenden und mit `unzip -t test-backup.zip` prüfen. Erst wenn diese Probe erfolgreich war, den privaten Schlüssel endgültig offline verwahren oder einen alten Server kündigen.

Der offizielle `age`-Aufruf verwendet `age-keygen -y`, um den öffentlichen Empfänger aus dem privaten Schlüssel abzuleiten, `age -R` für Empfängerdateien und `age --decrypt -i` zur Entschlüsselung. [Offizielle age-Dokumentation](https://github.com/FiloSottile/age)

## MariaDB über einen lokalen Socket

Für eine nativ installierte MariaDB kann `secrets/mysql.cnf` ohne Host, Port und Passwort so aussehen:

```ini
[client]
user="backup"
protocol="socket"
```

Diese Socket-Konfiguration ist optional. Eine bereits vorhandene Konfiguration mit Passwort funktioniert weiterhin und wird weder bei Installation, Aktualisierung noch bei einem Backup verändert. Das Backup-System entfernt keine Zugangsdaten aus Live-Dateien oder aus den gesicherten Quelldaten; solche Inhalte werden vollständig mitgesichert und durch `age` verschlüsselt.

Wenn MariaDB nicht den automatisch gefundenen Standard-Socket verwendet, den tatsächlichen Pfad ergänzen:

```ini
socket="/run/mysqld/mysqld.sock"
```

Im zugehörigen MySQL-Job bleibt `container` leer. Das Backup-System übergibt diese Datei als erste Option mit `--defaults-file`, sodass `mariadb-dump` die `[client]`-Werte direkt verwendet. `protocol="socket"` bestimmt nur den lokalen Verbindungsweg und ersetzt keine Datenbankberechtigung oder Authentifizierung.

Das Backup läuft als Betriebssystembenutzer root. Nutzt der MariaDB-Benutzer das Authentifizierungs-Plugin `unix_socket`, muss seine serverseitige Zuordnung daher root akzeptieren. Eine Standardzuordnung zum gleichnamigen Betriebssystembenutzer `backup` funktioniert für diesen root-Prozess nicht. Die Verbindung vor dem ersten Backup mit der tatsächlichen Datei testen:

```bash
mariadb-dump --defaults-file=/opt/backup-manager/secrets/mysql.cnf \
  --single-transaction --skip-lock-tables --no-data --all-databases >/dev/null
```

Der Datenbankbenutzer benötigt nur die für den Dump erforderlichen Lese- und Metadatenrechte. Wegen `--routines`, `--triggers` und `--events` kann reines `SELECT` allein je nach gesicherten Objekten nicht ausreichen. Das Backup-System vergibt oder erweitert keine Datenbankrechte. [MariaDB-Dokumentation zu mariadb-dump](https://mariadb.com/docs/server/clients-and-utilities/backup-restore-and-import-clients/mariadb-dump)

## SSH-Anmeldung mit Passwort oder Schlüssel

Es gibt zwei getrennte Dinge: Deine Anmeldung erfolgt wahlweise mit Benutzername und Passwort oder mit Benutzername und privatem SSH-Schlüssel. Die Server-Identität wird in beiden Fällen über `known_hosts` geprüft. Bei Passwortanmeldung ist kein eigener SSH-Schlüssel nötig; Schritt 1 kann übersprungen werden.

Alle folgenden Befehle auf dem Backup-Server als root ausführen:

```bash
sudo -i
cd /PFAD/ZUM/backup-manager
umask 077
```

Dabei immer den Ordner der tatsächlich gestarteten Installation verwenden. Pfade verschiedener Installationskopien nicht miteinander vermischen.

### 1. Eigenen SSH-Backup-Schlüssel hinterlegen

Einen vorhandenen privaten Backup-Schlüssel als `secrets/backup_ed25519` hinterlegen. Alternativ einen neuen, ausschließlich dafür verwendeten Schlüssel erzeugen; eine vorhandene Datei dabei nicht überschreiben:

```bash
ssh-keygen -t ed25519 -f secrets/backup_ed25519 -C backup-manager
chmod 600 secrets/backup_ed25519
```

Es entstehen zwei Dateien: `backup_ed25519` ist privat und bleibt hier. `backup_ed25519.pub` ist öffentlich und darf beim Storage-Anbieter bzw. im Konto des Remote-Backup-Benutzers unter `~/.ssh/authorized_keys` hinterlegt werden.

Bei einem selbst verwalteten SSH-Server kann dafür nach der Hostschlüsselprüfung aus Schritt 3 `ssh-copy-id` verwendet werden. Bei Storage-Anbietern den vorgesehenen Schlüssel-Import benutzen. Den privaten Schlüssel niemals beim Anbieter hochladen.

Ein Schlüssel mit Passphrase benötigt einen bereits erreichbaren SSH-Agenten; Cron stellt diesen nicht automatisch bereit. Für einen unbeaufsichtigten Lauf ohne Agent ist ein separater Schlüssel ohne Passphrase möglich. Dann sind die lokalen Dateirechte und eine auf Backup-Aufgaben beschränkte Remote-Berechtigung besonders wichtig. Rsync und die Remote-Aufbewahrung müssen dort weiterhin erlaubt sein.

### 2. Verbindung eintragen

`secrets/rsync.yml` bearbeiten; die folgenden Werte sind Beispiele und müssen ersetzt werden:

```yaml
host: storage.example.org
port: 22
username: backup_user

auth: key
private_key: backup_ed25519
known_hosts_file: known_hosts
connect_timeout: 30
```

Dateipfade hier sind relativ zu `secrets/`. Die Datei `rsync.yml` wird über `rsync.credentials_file` in der Hauptconfig ausgewählt. Für eine andere Schlüsseldatei nur `private_key` ändern.

Für Passwortanmeldung sieht derselbe Abschnitt beispielsweise so aus:

```yaml
host: storage.example.org
port: 22
username: backup_user

auth: password
password_file: rsync-password
known_hosts_file: known_hosts
connect_timeout: 30
```

Die Passwortdatei enthält nur die Passwortzeile und hat Rechte `600`; zusätzlich wird `sshpass` benötigt. `private_key` wird bei `auth: password` nicht verwendet und kann entfallen. Um auf Schlüsselanmeldung zu wechseln, `auth: key` und `private_key` wie im ersten Beispiel setzen. `password_file` wird dann nicht verwendet. Host, Port und Benutzername bleiben gleich. Keine Passwörter in Shell-Befehle, Cronzeilen oder die normale Config schreiben.

### 3. Was ist known_hosts?

`known_hosts` identifiziert den **SSH-Server**, nicht deinen Benutzer. Der private Schlüssel meldet dich beim Server an; der öffentliche Hostschlüssel in `known_hosts` schützt davor, dich mit einem fremden Server zu verbinden.

Bei Passwortanmeldung übernimmt das Passwort deine Anmeldung. Der Server besitzt dennoch einen eigenen Hostschlüssel für die SSH-Verbindung. Diesen muss man weder selbst erstellen noch beim Storage-Anbieter hochladen.

Eine Zeile enthält Hostname/IP, Schlüsseltyp und öffentlichen Serverschlüssel. Bei abweichendem Port lautet der Hostteil beispielsweise `[storage.example.org]:2222`. Ein Eintrag beginnend mit `|1|` enthält einen gehashten Hostnamen. Mehrere Einträge können zu verschiedenen Servern, Ports oder Schlüsseltypen gehören. Diese Adressen sind keine zusätzlichen Rsync-Ziele. Das einzige Verbindungsziel ergibt sich aus `host` und `port` in `rsync.yml`.

Für das Backup werden nur die verifizierten Hostschlüssel des tatsächlich verwendeten Storage-Servers benötigt. Nicht zugehörige Einträge können nach Prüfung entfernt werden; die Software übernimmt keine globale Hostdatei automatisch.

Die sichere Einrichtung übernimmt das Backup-System selbst. Host, Port und die richtige `known_hosts`-Datei werden automatisch aus der aktuellen Installation gelesen:

```bash
bash create-backup.sh --setup-ssh-host
```

Der Befehl legt die Datei bei Bedarf mit geschützten Rechten an, zeigt den empfangenen Fingerabdruck und wartet auf die Eingabe `JA`. Den Fingerabdruck vorher über das Anbieterpanel oder die offizielle Dokumentation vergleichen. Ein bereits gespeicherter, abweichender Hostschlüssel wird niemals automatisch ersetzt.

Die folgenden manuellen Schritte sind nur notwendig, wenn der Einrichtungsbefehl nicht verwendet werden soll.

Hostschlüssel zunächst in eine separate Datei einlesen, die aktuelle Vertrauensdatei dabei nicht überschreiben:

```bash
ssh-keyscan -p 22 -t ed25519 storage.example.org > secrets/known_hosts.pending
ssh-keygen -lf secrets/known_hosts.pending
```

Den angezeigten Fingerabdruck über einen unabhängigen, vertrauenswürdigen Kanal vergleichen, etwa das Anbieterpanel oder die Serverkonsole. `ssh-keyscan` allein bestätigt keine Identität. Nur wenn der Fingerabdruck stimmt und die Datei nicht leer ist, den geprüften Eintrag in `secrets/known_hosts` übernehmen. Existiert die Datei bereits, nur den passenden Servereintrag ergänzen oder gezielt ersetzen; nicht andere benötigte Einträge blind überschreiben. [OpenSSH zu ssh-keyscan](https://man.openbsd.org/ssh-keyscan)

Danach die Rechte setzen:

```bash
bash install.sh permissions --target "$(pwd -P)"
```

Optional auf einem selbst verwalteten SSH-Server den öffentlichen Benutzerschlüssel installieren:

```bash
ssh-copy-id -i secrets/backup_ed25519.pub -p 22 \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$(pwd -P)/secrets/known_hosts" \
  backup_user@storage.example.org
```

Bei einer Warnung vor einem geänderten Hostschlüssel nicht einfach die Prüfung deaktivieren: Den neuen Fingerabdruck zuerst unabhängig bestätigen.

#### Fehler: Host key verification failed

`No ED25519 host key is known for [HOST]:PORT` bedeutet, dass für genau diesen Host und Port kein passender bestätigter Serverschlüssel vorliegt. Die Verbindung bricht vor der Passwort- oder Schlüsselanmeldung ab. Ein Eintrag für Port 22 oder für einen anderen Host deckt einen abweichenden Host oder Port nicht automatisch ab.

Das System verwendet ausschließlich die unter `known_hosts_file` angegebene Datei unter `secrets/`, nicht automatisch `/root/.ssh/known_hosts`. Ein älteres Script mit `StrictHostKeyChecking=accept-new` kann zuvor unbekannte Hosts automatisch übernommen haben. Hier gilt `StrictHostKeyChecking=yes`: Neue Einträge müssen zuerst geprüft werden. Das ist unabhängig von `auth: password` oder `auth: key`. [OpenSSH zu StrictHostKeyChecking](https://man.openbsd.org/ssh_config#StrictHostKeyChecking)

Zur Korrektur den Einrichtungsbefehl innerhalb der verwendeten Installation ausführen:

```bash
bash create-backup.sh --setup-ssh-host
```

Bei einem Storage-Anbieter mit abweichendem SSH-Port die oben gezeigte Hostschlüsselabfrage mit dem tatsächlich konfigurierten Port und Hostnamen ausführen. Den Fingerabdruck mit den Angaben des Anbieters oder über einen anderen vertrauenswürdigen Kanal vergleichen. Erst danach den bestätigten Eintrag übernehmen. Keine Prüfung auf `no` setzen und keine fremden oder geänderten Einträge ungeprüft akzeptieren.

### 4. Job und Übertragung testen

In `config/config.yml` beim gewünschten Job:

```yaml
rsync:
  enabled: true
  destination: Examples/ApplicationData
  keep_backups: 60
  delete_local_after_transfer: false
```

Dann als root:

```bash
bash create-backup.sh --check -ApplicationData
bash create-backup.sh --wait -ApplicationData
```

Der zweite Befehl erstellt ein echtes Backup und überträgt es. `--check` prüft nur lokal. Für eine reine Übertragung bereits fertiger Archive:

```bash
bash create-backup.sh --wait --rsync-only -ApplicationData
```

Für einen Übertragungstest ohne Upload oben in der Hauptconfig `rsync.dry_run: true` setzen. Der Remote-Zielordner muss dafür bereits existieren. Der lokale Backup-Schritt läuft trotzdem, lokale Archive werden im Testlauf nicht entfernt.

`delete_local_after_transfer: true` entfernt die erfolgreich übertragenen lokalen Archive nach zusätzlichem Inhaltsvergleich; bei Fehlern bleiben sie erhalten. Diese Einstellung nur aktivieren, wenn ausdrücklich keine lokale Kopie gewünscht ist.

## Geschützte Altdateien

`migration-*` enthält Original-Configs einer früheren Umstellung und möglicherweise alte Zugangsdaten. Diese Benutzerdaten nicht veröffentlichen und nur nach eigener Prüfung entfernen.
