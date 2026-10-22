# NEXORA Cloud Intelligence — Von registriertem User zu Full Admin ohne SQLi

**Ziel:** NEXORA Cloud Intelligence (fiktive "KI-Analytics-Plattform", eigenes Homelab-Übungsziel)
**Ergebnis:** Vollzugriff auf `/admin` über einen ganz normal registrierten, nicht privilegierten Account
**Eingesetzte Schwachstellenklassen:** Secret Exposure (geleakter interner API-Key), Path Traversal, Server-Side Request Forgery (SSRF), Broken Access Control (interner Service)
**Explizit nicht genutzt:** SQL Injection, Command Injection, Session-/Cookie-Signing-Angriffe

---

## Kontext

NEXORA besteht aus zwei getrennten Flask-Services auf derselben VM:

| Service | Bind-Adresse | Zweck |
|---|---|---|
| `app.py` | `0.0.0.0:8082` | Öffentliche Hauptanwendung (Login, Dashboard, Reports, Datenquellen, Account) |
| `internal_api.py` | `127.0.0.1:9090` | Interner Admin-Microservice — bewusst nur lokal gebunden, "niemand von außen kommt ran" als einzige gedachte Schutzmaßnahme |

Die Annahme des Platform-Teams: Netzwerk-Isolation (`127.0.0.1`-Binding) reicht als Schutz aus, zusätzliche Authentifizierung auf Anwendungsebene wurde dünn gehalten (ein einziger statischer Key). Genau diese Annahme bricht die gesamte Kette.

---

## Schritt 1 — Geleakter interner API-Key

Beim Durchsehen der im Browser geladenen JS-Dateien (DevTools → Sources/Network) fällt eine unauffällige Vendor-Datei auf:

```
static/js/vendor/analytics.bundle.js
```

Darin, als Kommentar stehen gelassen:

```js
window.__DEV_INTERNAL_KEY = "nxr_internal_8f2c91a07e4b4d5fa9c0";
```

**Warum das passiert:** Build-Pipelines (Webpack, Vite & Co.) reichen Umgebungsvariablen und Debug-Flags zu leicht ins Client-Bundle durch. Secrets in Frontend-Bundles sind einer der häufigsten Findings in echten Web-Pentests — der Browser-Client ist für den Server grundsätzlich nicht vertrauenswürdig, alles, was dort landet, ist öffentlich.

---

## Schritt 2 — Path Traversal im Report-Download

Der Account-Bereich bietet einen Report-Download:

```
GET /reports/download?file=q3-summary.txt
```

Serverseitig (`app.py`):

```python
filename = request.args.get("file", "")
full_path = os.path.join(REPORTS_DIR, filename)
```

Der Parameter wird ungefiltert mit `os.path.join()` an das Report-Verzeichnis angehängt — `..`-Sequenzen werden nicht herausgefiltert. Damit lässt sich aus `REPORTS_DIR` ausbrechen:

```
GET /reports/download?file=../.internal_notes.txt
```

Die ausgebrochene Datei (eine Ebene über `reports/`) bestätigt die Existenz des internen Admin-Microservices auf Port 9090 — ein Hinweis, der eigentlich vor dem Release hätte entfernt werden sollen.

**Fix:** `werkzeug.utils.secure_filename()` oder `os.path.realpath()` gegen das erlaubte Basisverzeichnis validieren, statt dem rohen User-Input zu vertrauen.

---

## Schritt 3 — SSRF in der Datenquellen-Vorschau

NEXORA bietet unter `/datasource` ein Feature, um externe Datenquellen per URL einzubinden und eine Vorschau abzurufen — ein in BI-/Analytics-Tools übliches Pattern (externe APIs, Webhooks, Feeds). Serverseitig:

```python
url = request.form.get("url", "").strip()
resp = requests.get(url, timeout=4)
preview = resp.text[:3000]
```

Keine Allowlist für erlaubte Ziel-Hosts, kein Blocken von `127.0.0.1` / `10.0.0.0/8` / `169.254.0.0/16`. Der entscheidende Punkt: **der Request kommt vom Server, nicht vom Client.** Weil `app.py` selbst auf derselben Maschine läuft wie `internal_api.py`, kann der Server Ziele erreichen, die von außen (auch aus einem anderen Netzsegment) unerreichbar sind:

```
POST /datasource   url=http://127.0.0.1:9090/internal/health
```

→ Antwort bestätigt den internen Service. Die Anwendung selbst wird so zum Proxy in ein für den Angreifer sonst unsichtbares Netz.

**Fix:** Allowlist für erlaubte Ziel-Hosts; private/Loopback-Ranges grundsätzlich blocken; idealerweise über einen dedizierten Egress-Proxy statt direktem `requests.get()` mit Nutzer-Input.

---

## Schritt 4 — Schwache interne Authentifizierung → Privilege Escalation

Der interne Service (`internal_api.py`) kennt genau einen Schutzmechanismus: Vergleich gegen einen statischen Key, kein Rate-Limiting, keine Rotation, kein Kontext, wer die Anfrage eigentlich stellt:

```python
@app.route("/internal/admin/promote")
def promote():
    key = request.args.get("key", "")
    username = request.args.get("username", "")
    if key != INTERNAL_KEY:
        return jsonify({"error": "invalid internal key"}), 403
    ...
    conn.execute("UPDATE users SET role = 'admin' WHERE id = ?", (user["id"],))
```

Bewusst als `GET` mit Query-Parametern gebaut (nicht `POST`/JSON) — genau das macht ihn über eine simple SSRF-Lücke überhaupt erreichbar, da diese meist nur GET weiterleiten kann.

Mit Key (Schritt 1) und Port/Pfad-Hinweis (Schritt 2) lässt sich der Endpunkt per SSRF (Schritt 3) ansprechen:

```
POST /datasource   url=http://127.0.0.1:9090/internal/admin/promote?key=nxr_internal_8f2c91a07e4b4d5fa9c0&username=<eigener-account>
```

Ergebnis: `{"status": "promoted", "username": "<eigener-account>", "role": "admin"}`. `/admin` neu laden — voller Admin-Zugriff, ohne das Passwort eines echten Admins zu kennen und ohne direkten Netzwerkzugriff auf den internen Service.

---

## Angriffskette im Überblick

```
JS-Bundle-Kommentar          Path Traversal              SSRF                         Broken Access Control
(Key geleakt)         →      (/reports/download)   →     (/datasource)          →     (/internal/admin/promote)
     │                            │                           │                              │
     ▼                            ▼                           ▼                              ▼
nxr_internal_...      "Admin-Service auf          Server ruft 127.0.0.1:9090      role = 'admin' für
                        127.0.0.1:9090"             im eigenen Namen auf            eigenen Account
```

Jede einzelne Lücke für sich ist harmlos — Secret-Leak ohne erreichbares Ziel, interner Service ohne direkten Netzwerkzugriff, SSRF ohne interessantes internes Ziel. Erst die Verkettung aller drei ergibt Full Admin. Genau dieses "Chaining" ist der Grund, warum moderne Pentests/Bug-Bounty-Programme selten bei der ersten gefundenen Lücke aufhören.

---

## Reale Relevanz

- **SSRF** steht in den OWASP Top 10 (A10:2021) und ist bei Bug-Bounty-Programmen eine der häufigsten kritischen Findings, v. a. bei "Preview URL"/"Connect Data Source"/"Webhook"-Features. Prominentes Beispiel: der Capital-One-Breach 2019 (SSRF gegen eine Cloud-Metadaten-API, >100 Mio. betroffene Datensätze).
- **"Internal-only, daher keine Auth nötig"** ist ein verbreiteter Architekturfehler bei Microservices — Vertrauen auf Netzwerksegmentierung statt Zero-Trust (jeder Service validiert jede Anfrage selbst, unabhängig von der Quelle).
- **Secrets im Frontend-Bundle** gehören zu den häufigsten Findings in Web-Pentests überhaupt, meist verursacht durch Build-Tooling, das Umgebungsvariablen zu großzügig ins Client-Bundle durchreicht.

---

## Fixes

| Lücke | Fix |
|---|---|
| Secret im JS-Bundle | Secrets nie in Client-Code; Build-Pipeline auf versehentliches Env-Leaking prüfen |
| Path Traversal | `secure_filename()` / `realpath()`-Validierung gegen Basisverzeichnis |
| SSRF | Allowlist für Ziel-Hosts, private/Loopback-Ranges blocken, dedizierter Egress-Proxy |
| Schwache interne Auth | Netzwerk-Isolation ist keine Authentifizierung — interne Services brauchen eigene, robuste Auth (z. B. mTLS, kurzlebige Tokens statt statischer Keys) |

---

*Lab-Setup: eigenes, isoliertes Homelab (Proxmox/OPNsense/Kali). Nicht gegen Systeme einsetzen, die nicht vollständig unter eigener Kontrolle stehen.*
