# Workshop: Perimeter-Firewall & Elster IT-Service (verwundbares Portal)

## Ziel

Das `192.168.10.0/24`-LAN so abschotten, dass vom "externen" Netz (Kali auf
OPT1, `192.168.20.0/24`) nur noch ein einzelner, bewusst verwundbarer
Webdienst erreichbar ist — Simulation einer realen Perimeter-Firewall-
Situation (nur der öffentliche Webserver ist von außen erreichbar, alles
Interne ist abgeschottet).

## Architektur-Änderung (OPNsense)

- Neue Regel auf Interface **OPT1**: `Allow` TCP, Source: OPT1 net,
  Destination: `192.168.10.20:8081` — einziger erlaubter Weg von Kali ins
  LAN.
- Darunter: `Block` für OPT1 → `192.168.10.0/24` (alle anderen Ports).
- Bestehende, offenere Regeln (die vorher DVWA/Juice-Shop-Zugriff erlaubten)
  deaktiviert/entfernt.
- **Nebeneffekt erkannt und verstanden:** Mit der Sperre verliert Kali auch
  den Zugriff auf den internen DNS-Server — realistisch, da ein externer
  Angreifer ebenfalls keine interne Namensauflösung hätte. Für allgemeines
  Internet (apt etc.) DNS auf Kali stattdessen über OPNsense selbst
  (OPT1-Gateway) oder einen öffentlichen Resolver laufen lassen, statt über
  den internen AD-DNS-Server.
- **Verifiziert mit dem eigenen Mapper-Tool:** `run.py --no-ping` von Kali
  aus bestätigt, dass nach der Regeländerung nur noch der eine Port sichtbar
  ist.

## Elster IT-Service — das Zielsystem

Selbst konzipiertes Flask-Mitarbeiterportal (fiktive Firma), mit bewusst
eingebauten Lücken, deployed auf der Ubuntu-VM (`192.168.10.20:8081`).
Vollständige Doku inkl. Exploit-Walkthrough liegt im Projekt-Repo
(`elster-portal/README.md`).

### Gefundene & ausgenutzte Lücken (Stand heute)

| # | Lücke | Status | Notizen |
|---|---|---|---|
| 1 | SQL Injection im Login | ✅ erfolgreich ausgenutzt | `' OR 1=1 --` loggt als ersten DB-Eintrag (admin) ein; `admin' --` gezielt |
| 2 | IDOR bei Tickets | ✅ gefunden, Verifikation als Nicht-Admin offen | Fremde Ticket-IDs durchzählen; sauberer Beweis braucht Test mit normalem Account (`j.hartmann` / `sommer2024`) statt Admin-Session |
| 3 | Reflected XSS in der Suche | ✅ erfolgreich ausgenutzt | `<script>`-Payload greift in der Suche (im Gegensatz zum Profil, da andere Lückenklasse) |
| 4 | SSTI im Profil-Bio-Feld | ✅ erfolgreich ausgenutzt | `{{ 7*7 }}` → `49`, `{{ config }}` → Secret-Key-Leak bestätigt |
| 5 | Geleakte Backup-Datei (`config.py.bak`) | ✅ gefunden (via nikto) | Secret Key im Klartext |
| 6 | Versteckter Admin-Bereich (`/portal-mgmt-77x`) | ✅ gefunden (via Quellcode-Kommentar) | Zugriff bisher nur über SQLi-Session, nicht über gefälschtes Cookie |

### Offen für nächstes Mal: Cookie-Forgery mit `flask-unsign`

Ziel: zeigen, dass der geleakte Secret Key (Lücke 5) **allein**, unabhängig
von der SQL Injection, bereits für vollen Admin-Zugriff reicht (gefälschtes,
aber korrekt signiertes Session-Cookie, ganz ohne Login).

Heute an Copy-Paste-Fehlern beim Übertragen des Befehls über mehrere
Terminal-Zeilen gescheitert (falscher Secret-String, Leerzeichen im
Dict-Key, Leerzeichen um `=` im Cookie-Wert) — keine grundsätzliche
Blockade, nur Tippfehler. Für den nächsten Versuch: Befehl in eine Datei
schreiben und von dort ausführen statt live abzutippen/einzufügen, das
eliminiert die Terminal-Umbruch-Probleme.

Exakter Befehl (Secret aus `config.py.bak`, **ohne** die umschließenden
Anführungszeichen aus der Datei übernehmen):
```bash
flask-unsign --sign --cookie "{'logged_in': True, 'user_id': 1, 'username': 'admin', 'role': 'admin', 'full_name': 'Admin'}" --secret 'ElsterPortal_2024_SuperSecret!'
```

## Lessons Learned

- Eine Perimeter-Firewall, die wirklich nur einen Port durchlässt, hat
  Nebeneffekte, an die man zuerst nicht denkt (DNS!) — genau der Grund,
  warum man sowas im Lab testet statt zum ersten Mal in Produktion.
- SQLi-Bypass ohne Usernamen-Kenntnis (`' OR 1=1 --`) landet nicht
  "zufällig" beim Admin, sondern bei der ersten Zeile, die die Query
  zurückgibt (hier: erste angelegte DB-Zeile) — Implementierungsdetail, das
  man in echten Systemen nicht verlassen sollte.
- SSTI (Jinja2) ist eine andere Lückenklasse als XSS — serverseitige
  Codeausführung statt clientseitigem Skript, deshalb greifen JS-Payloads
  dort nicht.

## Nächste Schritte

1. `flask-unsign`-Cookie-Forgery sauber zu Ende bringen (siehe oben)
2. IDOR explizit mit Nicht-Admin-Account (`j.hartmann`) verifizieren
3. Optional: SSTI bis zur vollen RCE-Gadget-Chain vertiefen
4. Ins GitHub-Repo übernehmen (Architektur-Diagramm-Update mit der neuen
   Firewall-Regel, Vorher/Nachher-Mapper-Screenshot)
