# Kapitel 19: 802.1X mit RADIUS — Negativ-Ergebnis (Cisco Packet Tracer)

## 1. Ziel & Setup

Aufbauend auf dem Static-Routing/OSPF/NAT-Lab (Kapitel 18): dasselbe `192.168.10.0/24`-Netz
genutzt, um 802.1X-Port-Authentifizierung mit einem externen RADIUS-Server zu testen — Client A
(PC0) soll sich am Switch-Port über EAP-MD5 authentifizieren müssen, bevor der Port in den
Forwarding-Zustand wechselt.

**Topologie:** 1 Switch (Authenticator), 1 PC (Supplicant, `192.168.10.3`), 1 RADIUS-Server
(`192.168.10.50`), Switch-SVI auf `192.168.10.10/24`.

**Ziel:** Nachvollziehen, wie die drei 802.1X-Rollen (Supplicant, Authenticator, Authentication
Server) über ein reales RADIUS-Protokoll zusammenspielen — nicht nur konzeptionell, sondern mit
echter Konfiguration auf allen drei Beteiligten.

## 2. AAA — Begriffsklärung

**AAA** steht für drei getrennte, oft verwechselte Funktionen:

- **Authentication** — *Wer bist du?* Die Identitätsprüfung selbst (Username/Passwort,
  Zertifikat, o. ä.).
- **Authorization** — *Was darfst du?* Welche Rechte/welcher Zugriff wird nach erfolgreicher
  Authentifizierung gewährt.
- **Accounting** — *Was hast du getan?* Protokollierung zu Audit-Zwecken (Sitzungsdauer,
  übertragene Daten, ausgeführte Befehle).

In diesem Lab geht es ausschließlich um den **Authentication**-Teil — der Switch (Authenticator)
lässt den RADIUS-Server (Authentication Server) prüfen, ob der Supplicant (PC) echte,
gültige Credentials vorweisen kann, bevor der Port überhaupt Daten durchlässt.

## 3. Konfiguration — jede Zeile einzeln erklärt

### Switch

```
aaa new-model
```
Aktiviert das AAA-Subsystem des Geräts grundsätzlich. Ohne diese Zeile kennt der Switch nur
lokale, geräteinterne Authentifizierung — jede Form von externer Authentifizierung (RADIUS,
TACACS+) ist ohne `aaa new-model` gar nicht ansprechbar.

```
aaa authentication dot1x default group radius
```
Legt fest: Für 802.1X-Authentifizierungsanfragen (`dot1x`) soll die **default**-Methodenliste
verwendet werden, und diese Liste besteht aus der RADIUS-Servergruppe (`group radius`) — also:
"frag den/die konfigurierten RADIUS-Server".

```
radius-server host 192.168.10.50 auth-port 1645 key 1234
```
Registriert den konkreten RADIUS-Server: seine IP, den UDP-Port, auf dem er lauscht, und das
**Shared Secret**, mit dem die RADIUS-Pakete zwischen Switch und Server authentifiziert/verschlüsselt
werden. Dieses Secret muss exakt mit dem auf dem Server hinterlegten Wert übereinstimmen.

```
dot1x system-auth-control
```
Schaltet 802.1X **global** auf dem gesamten Gerät ein. Ohne diese Zeile haben alle
Port-spezifischen dot1x-Befehle keine Wirkung.

```
interface FastEthernet0/1
 switchport mode access
 authentication port-control auto
 dot1x pae authenticator
```
- `switchport mode access`: Standard-Access-Port-Konfiguration, Voraussetzung für 802.1X auf
  diesem Port.
- `authentication port-control auto`: Der Port wechselt **dynamisch** zwischen
  unauthorized/authorized, abhängig vom Ergebnis der Authentifizierung — statt fest offen
  (`force-authorized`) oder fest zu (`force-unauthorized`) zu sein.
- `dot1x pae authenticator`: Legt die **PAE-Rolle** (Port Access Entity) dieses Ports fest — der
  Switch tritt hier als *Authenticator* auf (derjenige, der die Authentifizierung einfordert und
  weiterleitet), nicht als *Supplicant* (derjenige, der sich selbst authentifizieren müsste).

### Server (AAA-Service)

- **Service: On**, **Radius Port: 1645** (muss mit `auth-port` auf dem Switch übereinstimmen)
- **Network Configuration**: Client Name `Switch2`, Client IP `192.168.10.10` (= Switch-SVI,
  der RADIUS-Server akzeptiert Anfragen nur von registrierten Client-IPs), Secret `1234`
- **User Setup**: Username `Hallo`, Password `Hallo`

### PC (Supplicant)

Config-Tab → 802.1X-Bereich: "Use 802.1X Security" aktiviert, Authentication-Typ `MD5`,
Username/Password `Hallo`/`Hallo` — identisch zu den Server-seitigen Credentials.

## 4. Systematisches Debugging

Nach vollständiger Konfiguration blieb der Switch-Port dauerhaft **orange (unauthorized)**, kein
Ping, kein DHCP-Bezug möglich — erwartbares Symptom, da ein unauthorized 802.1X-Port praktisch
allen Traffic außer EAPOL blockiert.

Eingegrenzt, von unten nach oben, statt wahllos neu zu konfigurieren:

1. **IP-Erreichbarkeit Switch → RADIUS-Server:** `ping 192.168.10.50` vom Switch aus — **100%
   erfolgreich.** Reine Layer-3-Konnektivität war also nicht die Ursache.
2. **Port-Abgleich:** Switch (`auth-port 1645`) vs. Server (`Radius Port: 1645`) — **identisch.**
3. **Client-IP-Abgleich:** Server erwartet Anfragen von `192.168.10.10` — exakt die tatsächliche
   Switch-SVI-IP (`show ip interface brief` bestätigt) — **identisch.**
4. **Secret-Abgleich:** `1234` auf beiden Seiten — **identisch.**
5. **Credentials-Abgleich:** `Hallo`/`Hallo` auf PC und Server — **identisch.**
6. **Handshake-Neustart erzwungen:** PC-NIC (Port Status) aus- und wieder eingeschaltet, um einen
   frischen EAPOL-Start auszulösen — **keine Änderung.**
7. **Vollständige Running-Config geprüft** (`show running-config`): alle AAA-/dot1x-/
   Interface-Zeilen korrekt vorhanden, keine Tippfehler, keine widersprüchliche
   Doppelkonfiguration aus alter (`dot1x port-control auto`) und neuer
   (`authentication port-control auto`) Syntax.

**Hinweis am Rande:** `show dot1x` und `show authentication sessions` sind in dieser
Packet-Tracer-IOS-Version **nicht vorhanden** (`% Unrecognized command` bzw.
`% Invalid input`) — Status-Verifikation musste rein funktional (Ping, Portfarbe) statt über
offizielle Status-Befehle erfolgen, was die Diagnose zusätzlich erschwert.

## 5. Fazit — Negativ-Ergebnis

Jede realistisch mögliche Fehlerquelle auf Konfigurationsebene wurde einzeln geprüft und
ausgeschlossen: IP-Erreichbarkeit, Port, Client-IP, Secret, Credentials, Handshake-Neustart,
vollständige Running-Config. Die Authentifizierung läuft trotzdem nicht durch.

Eine unabhängige Recherche (Cisco-Community-Forenthread mit nahezu identischem Setup und
identischem Symptom — Port bleibt dauerhaft unauthorized trotz nachweislich korrekter
Konfiguration) bestätigt: Dieses Verhalten ist ein bekanntes, in der Community ungelöstes Problem
mit Packet Tracers 802.1X/EAP-MD5-Simulation, keine fehlerhafte eigene Konfiguration.

**Bewusst als Negativ-Ergebnis dokumentiert statt ein funktionierendes Setup vorzutäuschen** —
dasselbe Prinzip wie beim EDR/SIEM-Test in Kapitel 04 des Haupt-Homelabs. Der eigentliche Lernwert
liegt hier nicht im funktionierenden Endzustand, sondern im vollständigen, korrekten Aufbau der
AAA-/802.1X-Kette und der sauberen, schrittweisen Eingrenzung bis zur Werkzeuggrenze — zu
erkennen, wann eine Ursache nicht mehr in der eigenen Konfiguration liegt, ist dieselbe Fähigkeit,
die auch im echten Betrieb zählt.

## 6. Kernlektionen

- **AAA ist kein einzelner Mechanismus, sondern drei getrennte Funktionen** (Authentication,
  Authorization, Accounting) — in diesem Lab wurde ausschließlich der Authentication-Teil
  genutzt.
- **`aaa new-model` ist die Voraussetzung für jede externe Authentifizierung** — ohne diese Zeile
  bleibt ein Cisco-Gerät auf rein lokale Methoden beschränkt.
- **Die RADIUS-Client-IP-Allowlist auf dem Server ist eine eigenständige Fehlerquelle**, getrennt
  vom reinen Secret-Abgleich — eine falsche oder veraltete Client-IP blockt stillschweigend,
  ohne dass Secret oder Port betroffen wären.
- **Nicht jeder erwartete `show`-Befehl existiert in jeder Simulator-/IOS-Version** — `show dot1x`
  und `show authentication sessions` fehlten hier komplett, was auf funktionale Tests (Ping,
  Portstatus) statt offizielle Status-Ausgaben zurückwarf.
- **Ein vollständig korrekt konfiguriertes Setup, das trotzdem nicht funktioniert, ist kein
  automatisches Zeichen für einen eigenen Fehler** — nach erschöpfender Eingrenzung ist die
  Werkzeuggrenze eine ebenso gültige, dokumentierenswerte Schlussfolgerung wie ein gefundener
  Konfigurationsfehler.
