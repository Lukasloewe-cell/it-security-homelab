# Chapter 15: Threat Hunting — Hypothesis-Driven Investigation

## 1. Was ist Threat Hunting?

Threat Hunting ist der **proaktive** Gegenpart zur **reaktiven** Alert-basierten Erkennung:

| | Alert-basierte Erkennung | Threat Hunting |
|---|---|---|
| Auslöser | Eine Rule hat bereits gematcht | Eine selbst aufgestellte Hypothese |
| Zeitpunkt | Nachdem etwas passiert ist | Unabhängig davon, ob schon ein Alert existiert |
| Haltung | Reaktiv | Proaktiv |

Ein Alert allein ist **kein Beweis** — er ist nur der Startpunkt. Erst zusätzlicher Kontext (Timing, Häufigkeit, ungewöhnliche Kombinationen) macht aus einem Alert einen tatsächlichen Nachweis (Proof).

### Der Threat Hunting Loop

```
Hypothese  →  Investigate  →  Uncover Patterns/TTPs  →  Inform & Enrich Analytics
   ↑                                                              │
   └──────────────────────────────────────────────────────────────┘
```

1. **Hypothese**: Eine begründete Vermutung aus der Struktur der eigenen Umgebung (z.B. "Könnte Windows Defender über die Registry deaktiviert worden sein?")
2. **Investigate**: Gezielte, eng gescopte Suche in den passenden Datenquellen
3. **Uncover Patterns/TTPs**: Gefundene Verhaltensmuster den entsprechenden MITRE-ATT&CK-Techniken zuordnen
4. **Inform & Enrich Analytics**: Ergebnisse zurück ins SOC spielen — neue Rules, Dashboards oder Detection-Quellen daraus ableiten

### Scoping & Timeboxing

Ohne engen Scope (eine konkrete Hypothese + definierte Quelle) und ein festes Zeitbudget wird selbst eine überschaubare Anzahl an Aktionen auf einem einzigen Host schnell unübersichtlich — in einer echten Umgebung mit tausenden Hosts potenziert sich das. Praxis-Regel: **erst prüfen, ob die erwartete Quelle überhaupt gesammelt wird**, bevor man den Scope aufweitet oder die Hypothese verwirft.

## 2. Das Threat Hunting Worksheet

Wiederverwendbare Dokumentationsvorlage für jeden Hunt:

| Hypothese | MITRE-Technik | Erwartete Quelle/Filter | Gefunden? | Beweis (Event-ID/Rule) | Anmerkung |
|---|---|---|---|---|---|
| | | | | | |

Plus Metadaten-Kopf: Datum, Analyst, betroffenes System/Scope, Zeitraum (Start–Ende, fürs Timeboxing).

## 3. Praxis: Detection Test 1 (30.10.2026)

Ein PowerShell-Skript führte 7 benigne, aber TTP-repräsentative Aktionen auf dem Windows-11-Client aus:

| Aktion | MITRE-Technik |
|---|---|
| EICAR-Testdatei in `%TEMP%` abgelegt | — (AV-Testartefakt) |
| Neuer lokaler Benutzer `svc_update` angelegt | T1136.001 – Create Account: Local Account |
| Registry Run-Key (`HKCU\...\CurrentVersion\Run`) gesetzt | T1547.001 – Boot or Logon Autostart Execution: Registry Run Keys |
| Scheduled Task `SystemCheckTask` registriert | T1053.005 – Scheduled Task |
| Windows Defender per Registry deaktiviert (`DisableAntiSpyware`) | T1562.001 – Impair Defenses |
| Firewall-Regel für Port 4444 freigegeben | T1562.004 – Impair Defenses: Disable or Modify System Firewall |
| Application-Eventlog geleert | T1070.001 – Indicator Removal: Clear Windows Event Logs |

**Ergebnis beim ersten Durchlauf:** nur 3 von 7 klar bestätigt (EICAR-Datei, neuer Benutzer, Application-Log-Löschung). Drei Aktionen (Registry Run-Key, Scheduled Task, Firewall-Regel) wurden **nicht gefunden** — nicht weil die Hypothesen falsch waren, sondern weil die entsprechenden Log-Quellen in Wazuh schlicht noch nicht konfiguriert waren.

### Sichtbarkeitslücken geschlossen (31.10.2026)

| Lücke | Fix | Lektion |
|---|---|---|
| Scheduled-Task-Erkennung | `<localfile>` mit `Microsoft-Windows-TaskScheduler/Operational` (Event-ID 106 / Security-Log 4698) | Channel-Namen exakt, "TaskScheduler" ist ein Wort |
| Firewall-Regel-Erkennung | `<localfile>` mit `Microsoft-Windows-Windows Firewall With Advanced Security/Firewall` | Enthielt zunächst einen Tippfehler ("Microsfot"), der in der Agent-`ossec.log` als `EvtSubscribe()`-Fehler (15007) sichtbar wurde, nicht im Wazuh-Dashboard |
| Registry-Run-Key-Erkennung | `<windows_registry>HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run</windows_registry>` | Wazuh erwartet den vollen Hive-Namen (`HKEY_CURRENT_USER`), nicht die PowerShell-Kurzform (`HKCU:`) |

**Wichtige Debugging-Erkenntnis:** Ein einziges falsch geschriebenes Zeichen in einem Event-Channel-Namen legt die komplette Quelle lahm, ohne dass Wazuh selbst eine auffällige Fehlermeldung im Dashboard zeigt — sichtbar wird es nur in der Agent-eigenen `ossec.log` (`C:\Program Files (x86)\ossec-agent\ossec.log`), nicht in den Manager-Logs.

Außerdem bestätigt: Windows-Event-IDs können sich über Windows-Versionen hinweg ändern — "neue Firewall-Regel" hieß historisch Event-ID 2004, auf aktuellen Windows-10/11-Builds jedoch 2097.

## 4. Praxis: Detection Test 2 (31.10.2026, erweiterter Schwierigkeitsgrad)

Zweiter Durchlauf mit 7 neuen, teils bewusst schwerer zu findenden Aktionen:

| Aktion | MITRE-Technik | Gefunden? |
|---|---|---|
| Base64-kodierter PowerShell-Befehl ausgeführt | T1059.001 (PowerShell) + T1027 (Obfuscated Files/Information) | Nur indirekt über FIM-Dateispur, nicht über die Befehlsausführung selbst (PowerShell ScriptBlock Logging/Event-ID 4104 fehlt noch) |
| Lokaler Account erstellt | T1136.001 – Create Account: Local Account | ✅ |
| Account zur Administrators-Gruppe hinzugefügt | T1098.001 – Account Manipulation: Additional Local or Domain Group Membership | ✅ (zunächst fälschlich als T1484 – Domain Policy Modification eingeordnet) |
| UAC über Registry deaktiviert (`EnableLUA=0`) | T1548.002 – Bypass User Account Control | ❌ zunächst, da Registry-Pfad noch nicht überwacht |
| Scheduled Task `WindowsUpdateHelper` (unauffälliger Name) | T1053.005 – Scheduled Task | ✅ |
| PowerShell-Operational-Log geleert | T1070.001 – Indicator Removal: Clear Windows Event Logs | ✅ |
| Datei als PDF getarnt (`Rechnung_Oktober.pdf.exe`, Downloads-Ordner) | T1036.003 – Masquerading | ❌ zunächst, da Downloads-Ordner noch nicht FIM-überwacht war |

### Weitere geschlossene Lücken

| Lücke | Fix |
|---|---|
| UAC-Deaktivierung | `<windows_registry>HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System</windows_registry>` |
| Getarnte Datei in Downloads | `<directories realtime="yes">C:\Users\*\Downloads</directories>` |

**Wichtige Korrektur:** `T1098` (Account Manipulation) und `T1136.001` (Create Account) sind unterschiedliche Techniken — Account-**Erstellung** ist T1136.001, eine **nachträgliche Rechteänderung** (z.B. Gruppenmitgliedschaft) ist T1098.001. `T1484` (Domain Policy Modification) betrifft GPO-Änderungen, nicht Gruppenmitgliedschaften — leicht zu verwechseln, aber eine andere Kategorie.

**Offen geblieben:** Die tatsächliche Ausführung des obfuskierten PowerShell-Befehls selbst bleibt unsichtbar, solange PowerShell ScriptBlock Logging nicht aktiviert ist — nur sein Nebeneffekt (eine abgelegte Datei im Temp-Ordner) wurde über FIM gefunden. Follow-up für eine künftige Session.

## 5. Kernlektionen

- **`archives.log` vs. `alerts.log`**: Ein Event kann korrekt bei Wazuh ankommen und archiviert werden, ohne dass eine Rule darauf matcht — bei "wird nichts angezeigt" lohnt sich immer der Blick in die rohen Events, nicht nur in die Alerts.
- **Hypothese vor Suche**: Ohne vorab formulierte Hypothese + erwartete Quelle wird man auch bei wenigen Aktionen auf einem Host schnell überfordert.
- **Erst Quelle verifizieren, dann Scope weiten**: Wenn eine Hypothese nichts liefert, zuerst prüfen, ob die erwartete Quelle überhaupt aktiv gesammelt wird, bevor man den Suchbereich vergrößert oder die Hypothese verwirft.
- **Event-Channel-Namen sind fehleranfällig**: Exakte Schreibweise entscheidet zwischen Funktionieren und stillem Totalausfall einer Quelle; Fehler zeigen sich nur in der Agent-`ossec.log`, nie im Wazuh-Dashboard selbst.
- **Nicht jede Aktion hinterlässt automatisch Spuren**: Manche Techniken (z.B. obfuskierte Befehlsausführung) brauchen dedizierte Logging-Mechanismen (PowerShell ScriptBlock Logging), die über Standard-FIM/Eventchannel-Setups hinausgehen.

## 6. Praxis: NetFlow-basierte Portscan-Verifikation (01.11.2026)

Ziel: die zuvor nur konzeptionell durchgespielte Theorie — ein Portscan zeigt sich in Flow-Daten als viele kurze Flows, wenig Bytes/Paket, eine konstante Ziel-IP mit vielen unterschiedlichen Zielports — praktisch am eigenen NetFlow-Setup (OPNsense-Exporter → `nfcapd`/`nfdump`-Collector auf dem Ubuntu-Server) bestätigen.

### Unerwarteter Fund: leere `nfcapd`-Dateien

Ein Nmap-Scan von Kali (192.168.20.10) gegen Ubuntu (192.168.10.20) lief, aber alle aktuellen `.nfcapd`-Dateien waren nur 209 Bytes groß — reine Datei-Header ohne einen einzigen Flow-Record, obwohl `nfcapd` selbst nachweislich lief und brav alle 5 Minuten rotierte.

**Systematisches Debugging statt Raten:**

1. Verifiziert, dass `nfdump -r <datei>` (nicht nur ein Blick mit einem Texteditor auf die Binärdatei) tatsächlich 0 Flows zeigt.
2. Über `ps aux | grep nfcapd` den tatsächlich konfigurierten Listen-Port geprüft: **`-p 2055`**.
3. In OPNsense (Reporting → NetFlow) das konfigurierte Export-Ziel geprüft: Port **9995**.

**Root Cause:** Port-Mismatch — `nfcapd` lauschte auf 2055, OPNsense exportierte nach 9995. Beide Seiten liefen fehlerfrei, ohne dass irgendwo eine Fehlermeldung auftauchte — genau wie beim Event-Channel-Tippfehler aus Kapitel 3 eine stille Fehlkonfiguration, die nur durch gezielte Paket-Verifikation auffällt.

**Fix:** Export-Port in OPNsense auf 2055 angeglichen. Verifiziert über `tcpdump`/Wireshark-Filter `udp.port == 2055` auf dem Ubuntu-Server — danach sichtbar ankommende CFLOW-Pakete, und die aktuelle `nfcapd`-Datei wuchs sofort von 209 Bytes auf mehrere MB.

### Verifikation der Portscan-Signatur

Mit laufendem Datenfluss zwei Aggregations-Abfragen gegen das enge Zeitfenster des eigentlichen Scans (`-t 2026/11/01.14:50:00-2026/11/01.15:00:00`, Tag/Monat zweistellig — ein erster Versuch ohne führende Null auf dem Enddatum scheiterte mit `Time format error: '1' unexpected`):

```
nfdump "dst ip 192.168.10.20" -R /var/cache/nfdump -t 2026/11/01.14:50:00-2026/11/01.15:00:00 -s srcip
nfdump "dst ip 192.168.10.20" -R /var/cache/nfdump -t 2026/11/01.14:50:00-2026/11/01.15:00:00 -s dstport
```

**Ergebnis:**

| Merkmal | Beobachtung |
|---|---|
| Quell-IP-Konzentration | 25.929 von 25.954 Flows (99,9%) von einer einzigen Quelle (Kali) |
| Flow-Größe | durchgehend 44 Bytes / 1 Paket pro Flow, Dauer 0 |
| Ziel-Port-Streuung | keine Portnummer dominant, alle Top-Einträge bei nur 3–11 Flows |
| Zeitfenster | 6 Min 43 Sek — enge, zusammenhängende Burst-Aktivität |

Damit die Theorie aus Kapitel 1 praktisch bestätigt: eine Quelle, extrem viele kurze, inhaltsleere Flows, breit gestreute Zielports — klar unterscheidbar von normalem Traffic (wenige, aber inhaltsreiche Flows zu wenigen, wiederkehrenden Zielports).

**Wichtige Debugging-Erkenntnis:** Ein Port-Mismatch zwischen NetFlow-Exporter und -Collector erzeugt keinerlei Fehlermeldung auf beiden Seiten — beide Dienste laufen augenscheinlich normal weiter, nur eben aneinander vorbei. Sichtbar wird das ausschließlich über eine unabhängige Paketaufzeichnung (`tcpdump`/Wireshark) direkt auf dem erwarteten Port, nicht über die Logs der beteiligten Anwendungen selbst — derselbe Debugging-Grundsatz wie schon beim Event-Channel-Tippfehler: bei "kommt nichts an", erst auf Netzwerkebene verifizieren, bevor man der Anwendungskonfiguration misstraut.
