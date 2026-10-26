# Incident Investigation Report: SSH Brute-Force Detection

## Metadaten
- **Datum der Untersuchung:** 2026-10-26, 19:07
- **Analyst:** Lukas
- **Szenario:** Simulierter SSH-Brute-Force via Hydra gegen Ubuntu-Host
- **Tools eingesetzt:** Hydra v9.6, Wazuh, OPNsense (pf-Filterlog)

## 1. Ziel & Scope
- Untersuchung, ob ein per Wazuh ausgelöster SSH-Authentication-Failure-Alert einen echten Brute-Force-Versuch darstellt (True Positive) oder ein Fehlalarm ist.
- Im Scope: Ubuntu-Host (SSH-Dienst), Wazuh-Agent auf Ubuntu, Wazuh-Manager, OPNsense-Firewall-Logs.

## 2. Umgebung
- **Angreifer-System:** IP 192.168.20.10 (Kali), Tool: Hydra v9.6
- **Ziel-System:** IP 192.168.10.20 (Ubuntu), Dienst: SSH, Account: `lowpriv`
- **Log-Pipeline:** OPNsense → Wazuh-Manager (Syslog, TCP/514), Wazuh-Agent auf Ubuntu (`/var/log/auth.log`)

## 3. Angriffs-Simulation (Zeitleiste)

| Zeit | Aktion |
|---|---|
| 19:14:20 | Hydra-Brute-Force gegen SSH (Ubuntu, Account `lowpriv`) gestartet |
| 19:14:22 | Erster Wazuh-Alert sichtbar (Rule-ID 5760, "sshd: authentication failed") |

## 4. Triage / Initial Assessment
- **Alert:** Rule-ID 5760, Level 5
- **MITRE-Mapping:** T1110.001 (Password Guessing), T1021.004 (SSH) — Taktiken: Credential Access, Lateral Movement
- **Erster Eindruck:** Plausibel, weiter untersuchen — nach derselben Quell-IP filtern, um zu prüfen, ob es sich um wiederholte, zusammenhängende Versuche (Brute Force) handelt.

## 5. Datensammlung / Scoping
- **Zusätzliche Felder:** `predecoder.program_name: sshd-session`, `rule.mitre.technique: Password Guessing, SSH`
- **Rohlog-Auszug (Wazuh-Alert-JSON):**

```json
{
  "_index": "wazuh-alerts-4.x-2026.10.26",
  "_id": "dy9seaEBQCv6qqz9BUPE",
  "_source": {
    "predecoder": {
      "program_name": "sshd-session",
      "timestamp": "2026-10-26T19:14:42.833450+01:00"
    },
    "agent": {
      "ip": "192.168.10.20",
      "name": "wazuhfalcon",
      "id": "001"
    },
    "data": {
      "srcip": "192.168.20.10",
      "dstuser": "lowpriv",
      "srcport": "51644"
    },
    "rule": {
      "level": 5,
      "description": "sshd: authentication failed.",
      "groups": ["syslog", "sshd", "authentication_failed"],
      "firedtimes": 87,
      "mitre": {
        "technique": ["Password Guessing", "SSH"],
        "id": ["T1110.001", "T1021.004"],
        "tactic": ["Credential Access", "Lateral Movement"]
      },
      "id": "5760"
    },
    "location": "/var/log/auth.log",
    "decoder": {
      "parent": "sshd",
      "name": "sshd"
    },
    "full_log": "2026-10-26T19:14:42.833450+01:00 ubuntu-server sshd-session[14028]: Failed password for lowpriv from 192.168.20.10 port 51644 ssh2",
    "timestamp": "2026-10-26T18:14:43.147+0000"
  }
}
```

## 6. Analyse
- **Beweise:** Der `full_log`-Eintrag zeigt eine abgeschlossene SSH-Session, bei der tatsächlich ein Passwort übermittelt und vom Zielsystem abgelehnt wurde ("Failed password for lowpriv ... ssh2") — im Gegensatz zum Portscan-Fall zuvor, bei dem `data.length: 0` war und nur ein nacktes SYN-Paket ankam, ohne jede Möglichkeit, überhaupt Zugangsdaten zu übertragen.
- **`firedtimes: 87`** — diese exakte Regel hat 87-mal gefeuert, also 87 fehlgeschlagene Login-Versuche in kurzer Zeit gegen denselben Account. Das ist das entscheidende quantitative Indiz, das einen einmaligen Tippfehler eines legitimen Nutzers ausschließt und für einen systematischen, automatisierten Brute-Force-Versuch spricht.
- **Vergleich zum Portscan-False-Positive:** Beim Portscan deutete die Heuristik (viele Verbindungsversuche) fälschlich auf Brute Force hin, obwohl nie ein vollständiger Handshake oder eine Datenübertragung stattfand. Hier dagegen: vollständige SSH-Session, echter Passwort-Payload, Decoder `sshd` statt `pf`, und eine hohe Wiederholungsrate (87×) — klar unterscheidbare Evidenzlage.

## 7. Klassifizierung / Disposition
- **True Positive**
- **Begründung:** Die IP 192.168.20.10 hat 87-mal (firedtimes) versucht, sich per SSH mit dem Account `lowpriv` auf dem Ubuntu-Host anzumelden, jedes Mal mit "authentication failed" quittiert — das Muster (hohe Wiederholungsrate, vollständige Sessions mit tatsächlicher Passwortübertragung) entspricht klassischem Password Guessing, bestätigt durch das MITRE-Mapping (T1110.001). Im echten Unternehmenskontext wäre vor der endgültigen Eskalation noch sinnvoll, Rücksprache zu halten, ob der Nutzer selbst versucht hat, sich mehrfach falsch anzumelden (z. B. vergessenes Passwort) — bei 87 Versuchen in kurzer Zeit ist das jedoch unwahrscheinlich.

## 8. Reaktion / Empfehlung
- **Sofortmaßnahmen:** Network Containment (Quell-IP blocken/isolieren), betroffenen Account sperren, Eskalation an Engineering/Incident Response sowie Information an das Management.
- **Präventive Maßnahmen:** Multi-Faktor-Authentifizierung für SSH-Zugänge, SSH-Dienst deaktivieren bzw. auf VPN-/Bastion-Host beschränken wo möglich, Rate-Limiting per Firewall-Regel gegen wiederholte Verbindungsversuche von derselben Quelle.

## 9. Lessons Learned
- `data.length: 0` (Portscan) vs. ein tatsächlicher Passwort-Payload im `full_log` (Brute Force) ist der zuverlässigste Unterschied zwischen den beiden Alert-Typen, nicht allein der Decoder-Name.
- `firedtimes` ist ein unterschätztes, aber starkes quantitatives Beweisstück, das in die Dokumentation gehört, nicht nur eine qualitative Einschätzung.
- Es ist sinnvoll, zuerst selbst eine Hypothese anhand der Rohdaten zu bilden und diese anschließend über MITRE-ATT&CK-Mapping zu validieren, statt sich allein auf die automatische Klassifizierung zu verlassen.

## Anhang
- Vollständiger Rohlog-Auszug: siehe Abschnitt 5
- Vergleichsfall (False Positive, Portscan): separat dokumentiert, Rule-ID 11 / Decoder `pf`, `data.length: 0`, TCP-Flag `S` (SYN only)
