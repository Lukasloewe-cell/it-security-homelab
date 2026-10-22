# Kapitel 11: VirusTotal-Integration & Active-Response-Quarantäne

Ausgangspunkt dieses Kapitels ist kein Angriff, sondern die Gegenseite: ein File-Integrity-
Monitoring- und Automated-Response-Pipeline, die in echt funktionieren soll, wenn Wazuh eine
bösartige Datei meldet. Ziel: eine neu auf dem Ubuntu-Server abgelegte Datei wird per `syscheck`
erkannt, automatisch gegen VirusTotal geprüft, bei positivem Scan als eigener Alert sichtbar
gemacht und über eine Active Response automatisiert in Quarantäne verschoben — inklusive
forensischem Log mit Hashes und VT-Score. Dokumentiert wie ein echtes Assessment: mit zwei
tatsächlichen Bugs, die erst im Live-Test aufgefallen sind, nicht nur dem Endergebnis.

## Theorie: Warum ein VT-Alert nicht automatisch ein FIM-Alert ist

Die Wazuh-VirusTotal-Integration läuft über den `integrator`-Prozess auf dem Manager: Sobald
`syscheck` eine neue/geänderte Datei meldet, schickt die Integration deren Hash an die
VirusTotal-API und injiziert das Scan-Ergebnis als **eigenen, neuen Alert** zurück ins System
(`location: virustotal`, Decoder `json`). Das ist technisch ein separater Alert-Strom, nicht
einfach ein angereicherter `syscheck`-Alert — und genau das ist die erste Stolperstelle: Ohne
eine explizite Regel, die auf den von der Integration erzeugten Alert reagiert, taucht ein
positiver VT-Fund zwar irgendwo im Alert-Index auf, löst aber **keine** Active Response aus, weil
Active-Response-Bindungen über `<rules_id>` an eine konkrete Regel-ID gebunden sind.

Die Standard-VirusTotal-Regel (`87105`, "malicious file detected") existiert im Default-Ruleset,
aber für eine saubere, eigene Active-Response-Kette lohnt sich eine eigene, davon abgeleitete
Regel — hier `100200` — die explizit auf `87105` chained (`<if_sid>87105</if_sid>`) und sie der
`syscheck`-Gruppe zuordnet. Erst darauf kann die Active Response zuverlässig binden.

## Setup: Manager-Seite

`/var/ossec/etc/ossec.conf`:

```xml
<integration>
  <name>virustotal</name>
  <api_key>DEIN_API_KEY</api_key>
  <group>syscheck</group>
  <alert_format>json</alert_format>
</integration>

<command>
  <name>remove-threat</name>
  <executable>remove-threat.sh</executable>
  <timeout_allowed>no</timeout_allowed>
</command>

<active-response>
  <disabled>no</disabled>
  <command>remove-threat</command>
  <location>local</location>
  <rules_id>100200</rules_id>
</active-response>
```

`/var/ossec/etc/rules/local_rules.xml`:

```xml
<group name="local,">
  <rule id="100200" level="12">
    <if_sid>87105</if_sid>
    <description>VirusTotal: Malicious file detected (FIM-visible)</description>
    <group>syscheck,virustotal,</group>
  </rule>
</group>
```

## Setup: Agent-Seite (Ubuntu-Client)

FIM auf das Testverzeichnis scharfgestellt:

```xml
<syscheck>
  <disabled>no</disabled>
  <directories realtime="yes">/home/lukas/malware-test</directories>
</syscheck>
```

Active-Response-Skript und Abhängigkeiten liegen rein lokal auf dem Agent (nicht über
Zentral-Config verteilbar):

```bash
sudo chmod 750 /var/ossec/active-response/bin/remove-threat.sh
sudo chown root:wazuh /var/ossec/active-response/bin/remove-threat.sh
sudo apt install jq
```

Nach jeder Config-Änderung auf dem Manager: `sudo systemctl restart wazuh-manager`.

## Bug #1: Active Response meldet Erfolg, löscht aber nichts

Erster Test mit einer EICAR-Testdatei (`/home/lukas/malware-test/eicar`) — der Alert kam korrekt
durch, Regel 100200 feuerte, die Active Response lief an, `active-responses.log` zeigte:

```
2026/10/22 19:28:02 active-response/bin/remove-threat.sh: {...} Successfully removed threat
```

Die Datei war danach aber immer noch da. Root Cause im ursprünglichen Skript:

```bash
FILENAME=$(echo $INPUT_JSON | jq -r .parameters. alert. data. virustotal. source. file)
```

Die Leerzeichen hinter den Punkten machen den `jq`-Filter ungültig — `jq` wirft einen
Parse-Error auf stderr, `FILENAME` wird als leerer String gesetzt. Der nächste Schritt,
`rm -f -- "$FILENAME"`, läuft dann als `rm -f -- ""`: `rm -f` unterdrückt per Definition den
Fehler "Datei nicht gefunden" und gibt Exit-Code `0` zurück — das Skript protokolliert also einen
false-positive Erfolg, ohne dass je etwas gelöscht wurde. Genau die Art von stillem Fehler, der in
einer echten Umgebung dazu führt, dass ein SOC-Team sich in falscher Sicherheit wiegt, weil das
Log "erledigt" sagt.

Daneben noch zwei weitere Syntaxfehler im Originalskript (Single-Quotes statt
Command-Substitution bei `LOCAL` und `PWD`, dadurch literale Strings statt ausgeführter Befehle),
die zwar die Fehlermeldung nicht verursacht, aber den Pfadaufbau für die Logdatei zusätzlich
unzuverlässig gemacht hätten.

Fix: `jq`-Filter ohne Leerzeichen, `$(...)`-Syntax statt `` ' ' `` für Command-Substitution, und
eine explizite `-z "$FILENAME"`-Prüfung, damit ein leerer Hash/Pfad nie mehr stillschweigend als
Erfolg durchläuft.

## Bug #2: Doppelte Alert-Auslösung durch Realtime-FIM

Auch nach dem Fix feuerte derselbe VT-Alert zweimal innerhalb von zwei Sekunden
(`firedtimes: 1` und `firedtimes: 2` für dieselbe Datei, identischer Hash, identisches
`scan_date`) — ein bekanntes Verhalten von `syscheck` im Realtime-Modus, der ein
Datei-Event (z.B. `added`) unter bestimmten Bedingungen doppelt meldet. Kein Fehler in der
eigenen Konfiguration, aber relevant für die Skript-Robustheit: die zweite Ausführung trifft auf
eine bereits verschobene Datei.

## Die Lösung: Quarantäne statt hartem Löschen

Für ein echtes forensisches Vorgehen ist hartes Löschen (`rm -f`) ohnehin die falsche Antwort —
Beweismittel geht verloren. Stattdessen verschiebt die finale Version des Skripts die Datei in
ein abgeschottetes Quarantäne-Verzeichnis, entzieht ihr alle Rechte und protokolliert
Original-Pfad, Quarantäne-Pfad, Hashes und VT-Score in einem separaten Forensik-Log:

```bash
#!/bin/bash

LOCAL=$(dirname "$0")
cd "$LOCAL" || exit 1
cd .. || exit 1
WORKDIR=$(pwd)

LOG_FILE="${WORKDIR}/../logs/active-responses.log"
QUARANTINE_DIR="/var/ossec/quarantine"
FORENSICS_LOG="${WORKDIR}/../logs/quarantine-forensics.log"

read -r INPUT_JSON

FILENAME=$(echo "$INPUT_JSON" | jq -r '.parameters.alert.data.virustotal.source.file')
COMMAND=$(echo "$INPUT_JSON" | jq -r '.command')
MD5=$(echo "$INPUT_JSON" | jq -r '.parameters.alert.data.virustotal.source.md5 // "unknown"')
SHA1=$(echo "$INPUT_JSON" | jq -r '.parameters.alert.data.virustotal.source.sha1 // "unknown"')
POSITIVES=$(echo "$INPUT_JSON" | jq -r '.parameters.alert.data.virustotal.positives // "unknown"')
TOTAL=$(echo "$INPUT_JSON" | jq -r '.parameters.alert.data.virustotal.total // "unknown"')

if [ "$COMMAND" = "add" ]; then
    printf '{"version":1,"origin":{"name":"remove-threat","module":"active-response"},"command":"check_keys","parameters":{"keys":[]}}\n'

    read -r RESPONSE
    COMMAND2=$(echo "$RESPONSE" | jq -r '.command')

    if [ "$COMMAND2" != "continue" ]; then
        echo "$(date '+%Y/%m/%d %H:%M:%S') $0: $INPUT_JSON Remove threat active response aborted" >> "$LOG_FILE"
        exit 0
    fi
fi

if [ -z "$FILENAME" ] || [ "$FILENAME" = "null" ]; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') $0: $INPUT_JSON Error: empty filename from alert" >> "$LOG_FILE"
    exit 1
fi

if [ ! -f "$FILENAME" ]; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') $0: $INPUT_JSON Error: file not found, already gone?" >> "$LOG_FILE"
    exit 1
fi

TS=$(date '+%Y%m%d-%H%M%S')
BASENAME=$(basename "$FILENAME")
QUARANTINE_PATH="${QUARANTINE_DIR}/${TS}_${BASENAME}"

mkdir -p "$QUARANTINE_DIR"
mv -f -- "$FILENAME" "$QUARANTINE_PATH"

if [ $? -eq 0 ]; then
    chmod 000 "$QUARANTINE_PATH"
    chown root:root "$QUARANTINE_PATH"
    echo "$(date '+%Y/%m/%d %H:%M:%S') $0: $INPUT_JSON Successfully quarantined threat" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | original=$FILENAME | quarantine=$QUARANTINE_PATH | md5=$MD5 | sha1=$SHA1 | vt_positives=${POSITIVES}/${TOTAL}" >> "$FORENSICS_LOG"
else
    echo "$(date '+%Y/%m/%d %H:%M:%S') $0: $INPUT_JSON Error quarantining threat" >> "$LOG_FILE"
fi

exit 0
```

```bash
sudo mkdir -p /var/ossec/quarantine
sudo chown root:wazuh /var/ossec/quarantine
sudo chmod 750 /var/ossec/quarantine
```

## Verifikation

Finaler Live-Test gegen die echte EICAR-Testdatei:

```
2026-10-22 19:42:57 | original=/home/lukas/malware-test/eicar | quarantine=/var/ossec/quarantine/20261022-194257_eicar | md5=44d88612fea8a8f36de82e1278abb02f | sha1=3395856ce81f2b7382dee72602f798b642f14140 | vt_positives=66/68
```

```
$ sudo ls -la /var/ossec/quarantine/
drwxr-x--- 2 root wazuh 4096 Oct 22 19:42 .
---------- 1 root root   68 Oct 22 19:42 20261022-194257_eicar
```

Die zweite, doppelt ausgelöste Alert-Instanz traf wie erwartet auf die bereits verschobene Datei
und quittierte korrekt mit `Error: file not found, already gone?` — kein falscher Erfolg mehr,
sondern eine ehrliche, nachvollziehbare Fehlermeldung. Die Quarantäne-Datei selbst ist für
niemanden außer root lesbar oder ausführbar (`chmod 000`), bleibt aber für eine spätere manuelle
Analyse vollständig erhalten.

```
syscheck (realtime) erkennt neue Datei → VirusTotal-Integration scannt Hash
     → positiver Fund → VT-Alert (location: virustotal) → Rule 100200 (chained auf 87105,
       FIM-sichtbar) → Active Response remove-threat.sh
     → Datei nach /var/ossec/quarantine/ verschoben, Rechte entzogen, Forensik-Log geschrieben
```

**Kerntechniken:** VirusTotal-Integration · File Integrity Monitoring · Active Response ·
Rule-Chaining · Bash-Scripting-Fehleranalyse (`jq`, `rm -f`-Fehlerunterdrückung) ·
Quarantäne statt Deletion · Forensisches Logging
