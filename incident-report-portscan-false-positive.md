# Incident Investigation Report: Portscan fälschlich als Brute Force klassifiziert (False Positive)

## Metadaten
- **Datum der Untersuchung:** 2026-10-26, 17:38
- **Analyst:** Lukas
- **Szenario:** Nmap-Portscan gegen Ubuntu-Host, von Wazuh-Heuristik zunächst als Brute-Force-Versuch (T1110) eingestuft
- **Tools eingesetzt:** Nmap (SYN-Scan), Wazuh, OPNsense (pf-Filterlog)

## 1. Ziel & Scope
- Untersuchung eines von Wazuh ausgelösten Brute-Force-Alerts (MITRE T1110, Credential Access), um zu klären, ob tatsächlich ein Zugangsdaten-Angriff stattfand oder ob die Heuristik durch anderen Traffic fehlausgelöst wurde.
- Im Scope: OPNsense-Firewall-Log (pf), Wazuh-Alerting, Netzwerk-Traffic zwischen Kali und Ubuntu.

## 2. Umgebung
- **Angreifer-System:** IP 192.168.20.10 (Kali), Tool: Nmap (SYN-Scan, `-sS`)
- **Ziel-System:** IP 192.168.10.20 (Ubuntu)
- **Log-Pipeline:** OPNsense → Wazuh-Manager (Syslog, TCP/514), Decoder `pf` (automatisch von Wazuh erkannt)

## 3. Angriffs-Simulation (Zeitleiste)

| Zeit | Aktion |
|---|---|
| ~17:38 | Nmap-SYN-Scan gegen Ubuntu-Host gestartet |
| 17:38:24 | Erster Wazuh-Alert: Rule-ID 11 (Log-Volumen-Statistik, Gruppe "stats"), Level 4 |
| 17:42:25 | Raw pf-Filterlog-Eintrag identifiziert (Rule 74, Tracker-ID `0684d022-...`), block-Event |
| – | Separater Wazuh-Alert: Rule-Level 10, MITRE T1110 (Brute Force / Credential Access) — Gegenstand dieser Untersuchung |

## 4. Triage / Initial Assessment
- **Erster Alert (Rule-ID 11):** Level 4, Gruppe "stats" — `full_log` zeigte eine generische Log-Volumen-Meldung ("average number of logs ... We reached 6734"), die nicht zu den mitgelieferten `data`-Feldern (srcip/dstip/action) passte. Erster Eindruck: Diskrepanz zwischen Rohtext und strukturierten Feldern — weiter untersuchen, nicht einfach übernehmen.
- **Zweiter, eigentlich relevanter Alert:** Rule-Level 10, MITRE-Mapping T1110 (Credential Access, Technik: Brute Force). Erster Eindruck: plausibel auf den ersten Blick, aber klassischer Verdachtsfall für eine False-Positive-Heuristik, da hohe Verbindungsfrequenz sowohl bei echtem Brute Force als auch bei einem Portscan auftreten kann.

## 5. Datensammlung / Scoping
- Gezielte Suche nach `data.srcip:"192.168.20.10" and data.dstip:"192.168.10.20"`, um alle zusammengehörigen Einträge um den fraglichen Zeitraum zu finden.
- Dadurch den tatsächlichen Rohlog-Eintrag identifiziert, dessen Tracker-ID (`0684d022-6a61-4693-b36f-4fdcfcf0e753`) mit dem ersten Alert übereinstimmte:

```
Oct 26 17:42:25 OPNsense.internal filterlog[82551]: 74,,,0684d022-6a61-4693-b36f-4fdcfcf0e753,vtnet2,match,block,in,4,0x0,,42,9130,0,none,6,tcp,44,192.168.20.10,192.168.10.20,44598,993,0,S,1467618085,,1024,,mss
```

- Geparste Felder: `protocol: tcp`, `srcip: 192.168.20.10`, `srcport: 44598`, `dstip: 192.168.10.20`, `dstport: 993`, `action: block`, `data.length: 0`, TCP-Flag: **S** (nur SYN).

## 6. Analyse
- **data.length = 0:** Es wurden keinerlei Nutzdaten übertragen — ein echter Brute-Force-Versuch würde zwingend Zugangsdaten als Payload senden (z. B. einen Login-Befehl mit Username/Passwort), was einen abgeschlossenen Handshake und Daten im Paket voraussetzt.
- **TCP-Flag "S" (nur SYN):** Es kam nie zu einem vollständigen 3-Way-Handshake (SYN → SYN-ACK → ACK), geschweige denn zu einer Anwendungsschicht-Interaktion wie einem Login-Versuch. Das ist die klassische Signatur eines Nmap-SYN-Scans ("Stealth Scan"), der absichtlich nie Verbindungen abschließt.
- **Ziel-Port 993 (IMAPS):** Passt ins Bild eines Portscans, der mehrere Ports systematisch durchprobiert, nicht eines gezielten Login-Versuchs gegen einen einzelnen, bekannten Dienst.
- **Schlussfolgerung:** Ohne abgeschlossenen Handshake kann überhaupt kein Authentifizierungsversuch stattgefunden haben — die Heuristik hat allein auf Basis der hohen Verbindungsfrequenz (viele Blocks in kurzer Zeit) ausgelöst, ohne zu prüfen, ob tatsächlich Zugangsdaten übertragen wurden.

## 7. Klassifizierung / Disposition
- **False Positive**
- **Begründung:** Die als Brute Force (T1110) markierte Aktivität besteht ausschließlich aus geblockten SYN-Paketen ohne Payload und ohne abgeschlossenen Handshake gegen mehrere verschiedene Ports — das Verhaltensmuster entspricht einem Portscan (Reconnaissance, MITRE T1595), nicht einem Credential-Access-Versuch. Die zugrunde liegende Heuristik erkennt vermutlich allein "viele Verbindungsversuche in kurzer Zeit von einer Quelle" und unterscheidet dabei nicht zuverlässig zwischen Scan- und Login-Traffic.

## 8. Reaktion / Empfehlung
- **Sofortmaßnahmen:** Kein Incident-Response-Eskalationsbedarf, da kein echter Zugriffsversuch stattfand — Dokumentation als bekannter Scan-Traffic (z. B. aus eigenen Pentests/Monitoring) genügt.
- **Tuning-Empfehlung:** Die Brute-Force-Heuristik sollte um eine Prüfung ergänzt werden, ob tatsächlich ein vollständiger Handshake und Payload-Daten vorliegen (z. B. `data.length > 0`), bevor T1110 ausgelöst wird — das würde diese Art von False Positive künftig vermeiden.
- **Präventiv:** Rate-Limiting auf Firewall-Ebene gegen Portscans (bereits vorhanden, hat den Scan korrekt geblockt), ergänzend Alert-Tuning auf SIEM-Seite.

## 9. Lessons Learned
- Eine Diskrepanz zwischen `full_log` (Rohtext) und strukturierten `data`-Feldern ist ein Warnsignal, das man nicht ignorieren sollte — in diesem Fall führte es zum eigentlichen, zusammengehörigen Rohlog-Eintrag.
- `data.length` und die TCP-Flags sind zuverlässigere Indikatoren für "fand eine echte Authentifizierung statt?" als die reine Alert-Frequenz oder das MITRE-Label allein.
- Vergleichsfall (True Positive, SSH-Brute-Force via Hydra): siehe separater Bericht — dort zeigte derselbe MITRE-Taktik-Bereich (Credential Access) einen abgeschlossenen Handshake, echten Passwort-Payload und `firedtimes: 87` als klaren Gegensatz zu diesem Fall.

## Anhang
- Vollständiger Rohlog-Auszug: siehe Abschnitt 5
- Vergleichsfall (True Positive, SSH-Brute-Force via Hydra): `incident-report-ssh-bruteforce.md`
