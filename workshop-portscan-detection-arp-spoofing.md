# Workshop: Portscan-Detection, Reconnaissance-Evasion & ARP-Spoofing

## Kontext

Direkter Anschluss an den Perimeter-Firewall-Workshop (siehe
`workshop-perimeter-firewall-elster-portal.md`), in dem OPNsense so
konfiguriert wurde, dass vom externen Netz nur noch ein einzelner,
verwundbarer Dienst erreichbar ist. Die naheliegende Anschlussfrage: Wie
sieht so eine Firewall-Regel speziell gegen **Portscans** aus — und was
bleibt einem Angreifer noch übrig, wenn genau dieser Weg versperrt ist?
Dieses Kapitel deckt beides ab: den Bau einer Rate-Limit-Regel gegen
Portscans, die konzeptionelle Frage nach Umgehungsmöglichkeiten, und als
praktische Antwort darauf ARP-Spoofing als Layer-2-MITM-Technik, die eine
klassische Firewall grundsätzlich nicht erfassen kann.

## Teil 1: Portscan-Detection via Rate-Limiting

### Theorie

Eine klassische "Block Port X"-Regel schützt nur einen einzelnen Port. Ein
Portscan testet aber systematisch viele/alle Ports eines Ziels — das
eigentliche Angriffsmuster ist nicht "jemand will auf Port X", sondern
"jemand öffnet ungewöhnlich viele neue Verbindungen in kurzer Zeit,
unabhängig vom Zielport". `pf` (und damit OPNsense) kann genau dieses
Verhalten portunabhängig erkennen: Die Firewall zählt neue
Verbindungsversuche pro Quell-IP in einem konfigurierbaren Zeitfenster.
Überschreitet eine IP den Schwellwert, trägt `pf` sie automatisch in eine
**Overload-Tabelle** ein (ein dynamisch befüllter Alias) — erst eine
separate Regel, die genau diese Tabelle blockt, sorgt dafür, dass
nachfolgende Pakete tatsächlich gedroppt werden. Dasselbe Prinzip greift
auch bei SYN-Flood/DoS-Mustern.

### Umsetzung — drei Teile

1. **Alias** (Firewall → Aliases, Typ Host(s)), z. B. `portscan_blacklist`
   — bleibt anfangs leer, wird von `pf` dynamisch befüllt.
2. **Block-Regel ganz oben** im Regelwerk des betroffenen Interfaces:
   Source = dieser Alias, Action = Block. Muss vor der eigentlichen
   Allow-Regel ausgewertet werden.
3. **Rate-Limit in der Allow-Regel** selbst, unter Advanced Options:
   `Max. new connections / per second(s)` gesetzt, und unter
   Source-Tracking der Overload-Table-Alias eingetragen.

### Verifikation

<img src="opnsense-portscan-liveview.png" alt="OPNsense Firewall Live View – geblockter Portscan" width="720">

Live View zeigt exakt das erwartete Muster: Quelle `192.168.20.10` (Kali)
mit wechselnden Quell-Ports, Ziel `192.168.10.20` mit durchgehend
wechselnden Zielports, Action `block`, Label `portscan` — bestätigt, dass
die Rate-Limit-Regel greift, nicht eine generische Deny-All-Regel.

### Nuance: State-Killing

Der Overload-Mechanismus blockt zuverlässig **neue** Pakete, killt aber
nicht automatisch **bestehende** States der geblockten IP — das geht nur
manuell/gescriptet über `pfctl -k <IP>`. Für den Portscan-Use-Case
praktisch zu vernachlässigen, da die meisten Scan-Pakete ohnehin keinen
vollständigen State aufbauen (nacktes SYN ohne Handshake).

### Nebeneffekt entdeckt: Bremst auch Kerberoasting

Beim späteren Testen fiel auf, dass dieselbe Regel auch frühe
Kerberoasting-Anfragen (`impacket-GetUserSPNs ... -request`, siehe Kapitel
4) blockte, bevor der eigentliche Scan-Angriff überhaupt lief — mehrere
TGS-Requests in kurzer Zeit vom selben Host erzeugen aus Firewall-Sicht ein
ähnliches Muster wie ein Portscan. Gutes Beispiel für **Defense in
Depth**: Eine Regel, die für einen bestimmten Angriffstyp gedacht war,
bremst nebenbei auch andere, technisch unterschiedliche Angriffe mit
ähnlichem Netzwerk-Fingerprint.

## Teil 2: Theorie — Reconnaissance, wenn der klassische Scan geblockt ist

Realistische Frage für jedes Unternehmensnetz mit einer solchen Regel: Wie
verschafft sich ein Angreifer trotzdem ein Bild vom Netzwerk, ohne ein
offensichtliches Scan-Muster zu erzeugen?

- **Verteilte/langsame Scans:** Zeitlich gestreckt oder über mehrere
  kompromittierte Hosts verteilt, um unter dem Rate-Limit zu bleiben.
  Trade-off: Zeitverlust vs. Entdeckungsrisiko, keine verlässliche
  Garantie gegen Detection.
- **Passive Reconnaissance:** Statt aktiv zu senden, nur mitlesen, was im
  Segment an Broadcast-/Multicast-Traffic ohnehin anfällt — z. B.
  ARP-Requests (jeder Host, der mit einem anderen sprechen will, verrät
  sich selbst) oder **LLMNR/NBT-NS** (Windows-Namensauflösung per
  Broadcast; ein Tool wie `Responder` kann aktiv antworten und bekommt
  NTLMv2-Hashes direkt zugeschickt — verwandtes Konzept zum
  AS-REP-Roasting aus Kapitel 4).
- **Horizontaler vs. vertikaler Scan:** Vertikal = viele Ports auf einem
  Host (tiefe Recon eines bekannten Ziels). Horizontal = ein Port auf
  vielen Hosts (schnelle Suche nach einer bekannten Schwachstelle über das
  ganze Netz, z. B. Port 445/SMB — genau das Muster, mit dem WannaCry 2017
  weltweit nach EternalBlue-anfälligen Maschinen gesucht hat).

Der praktisch relevanteste Punkt aus dieser Diskussion: Ein Switch leitet
Unicast-Traffic gezielt nur an die richtige MAC-Adresse weiter (CAM-Tabelle)
— ein Angreifer sieht also standardmäßig nur noch Broadcast/Multicast-
Traffic, nicht den vollen Unicast-Verkehr anderer Hosts. **ARP-Spoofing**
ist der Weg, das aufzubrechen, ganz ohne Switch-Admin-Zugriff — und genau
das wird im zweiten Teil praktisch umgesetzt.

## Teil 3: ARP-Spoofing / MITM — praktische Umsetzung

### Warum das eine andere Angriffsklasse als ein Portscan ist

ARP ist ein reines Layer-2-Protokoll, das nie über einen Router (hier:
OPNsense) hinausgeht. Zwei Hosts im selben Subnetz kommunizieren direkt
miteinander, ohne dass die Firewall als Layer-3-Gerät den Traffic
überhaupt zu sehen bekommt. Eine Firewall-Regel kann also grundsätzlich
nichts gegen ARP-Spoofing innerhalb eines Segments ausrichten.

### Topologie-Problem

Kali sitzt auf OPT1 (`192.168.20.0/24`), die Zielsysteme Ubuntu und das
OPNsense-LAN-Interface liegen im LAN (`192.168.10.0/24`) — getrennt durch
OPNsense als Router. Da ARP nicht geroutet wird, ist ein Angriff direkt
von OPT1 aus technisch unmöglich. **Workaround**, um ein realistisches
"Angreifer hat bereits einen Fuß im LAN"-Szenario nachzustellen: Kali
bekommt eine zweite virtuelle Netzwerkkarte direkt im LAN-Segment,
`192.168.10.50/24`.

### Durchführung

IP-Forwarding auf Kali aktivieren (notwendig, damit Kali als transparenter
Durchleiter agiert statt die umgeleiteten Pakete stillschweigend zu
verwerfen):

```bash
echo 1 > /proc/sys/net/ipv4/ip_forward
```

Bidirektionales ARP-Spoofing zwischen Ubuntu (`192.168.10.20`) und dem
OPNsense-LAN-Gateway (`192.168.10.1`), zwei separate `arpspoof`-Prozesse,
jeweils eine Richtung:

```bash
arpspoof -i eth1 -t 192.168.10.20 192.168.10.1
arpspoof -i eth1 -t 192.168.10.1 192.168.10.20
```

Ziel: Der komplette Internet-Traffic von Ubuntu soll unbemerkt über Kali
laufen, bevor er zum echten Gateway weitergeleitet wird.

### Verifikation — und eine Troubleshooting-Kette

Reine ARP-Tabellen-Manipulation beweist noch nicht, dass tatsächlich
Traffic mitgelesen wird. Deshalb mehrstufig verifiziert, statt dem ersten
Teilerfolg zu vertrauen:

**ARP-Tabelle auf Ubuntu:**
```
gateway (192.168.10.1) at bc:24:11:5d:13:7b [ether] on ens18
```
Die MAC stimmt mit der zweiten Kali-NIC überein — die Vergiftung greift.

**Erster Verbindungstest (`ping 8.8.8.8`):** Antworten kamen durch, aber
mit einer unerwarteten Zeile:

<img src="ping-icmp-redirect.png" alt="Ping mit ICMP-Redirect-Meldung" width="600">

Eine ICMP-Redirect-Nachricht von Kali selbst. Hintergrund: Der Linux-Kernel
auf Kali erkennt beim Weiterleiten, dass der eigentliche Gateway im selben
Subnetz wie der Absender liegt, und informiert den Sender automatisch
darüber, dass ein direkterer Weg existiert — ein Standardverhalten, das
für verdecktes Mitlesen unerwünscht ist, weil es als Anomalie auffallen
kann (z. B. in NIDS-Regeln oder bei einem aufmerksamen Admin, der
ICMP-Redirects im Netz generell nicht erwartet). Abschaltbar über
`net.ipv4.conf.all.send_redirects=0`.

**Widersprüchlicher Traceroute-Befund:** Ein erster `traceroute 8.8.8.8`
von Ubuntu zeigte als Hop 1 direkt `_gateway (192.168.10.1)` — nicht die
Kali-IP, obwohl die ARP-Tabelle bereits vergiftet war. Das wäre ein
Hinweis gewesen, dass der MITM doch nicht wie erwartet funktioniert.

**Auflösung per Wireshark statt Spekulation:** Capture auf der Kali-LAN-
Schnittstelle mit Filter `icmp` während eines erneuten Traceroutes zeigte
eindeutig:

<img src="wireshark-ttl-exceeded.png" alt="Wireshark: ICMP Time-to-live exceeded von Kali" width="720">

```
Src: 192.168.10.50 → Dst: 192.168.10.20   ICMP Time-to-live exceeded
```

Kali beantwortet das TTL-1-Paket also tatsächlich selbst — der Beweis für
echtes, aktives Layer-3-Forwarding durch Kali, nicht nur eine vergiftete
Tabelle ohne Wirkung. Der widersprüchliche erste Traceroute-Lauf lässt
sich am ehesten damit erklären, dass zu diesem Zeitpunkt die beidseitige
Vergiftung (Ubuntu→Gateway *und* Gateway→Ubuntu) noch nicht vollständig
durchgesetzt war. Ein Wiederholungslauf nach Bestätigung beider aktiver
`arpspoof`-Prozesse zeigte danach korrekt Kali (`192.168.10.50`) als
Hop 1.

**Lerneffekt:** Eine vergiftete ARP-Tabelle ist eine notwendige, aber
keine hinreichende Bedingung für ein funktionierendes MITM — erst eine
echte Paket-Capture beweist, dass Traffic wirklich umgeleitet wird. Diese
Troubleshooting-Kette ist realistischer für den SOC-/Red-Team-Alltag als
ein Tutorial, bei dem der erste Versuch sofort sauber durchläuft.

## Teil 4: Detection — geht das überhaupt ohne Wireshark?

Zentrale Erkenntnis, die direkt an Teil 1 und 3 anknüpft: **Eine klassische
Layer-3-Firewall wie OPNsense kann ARP-Spoofing innerhalb eines Segments
weder blocken noch von sich aus erkennen**, weil der Traffic sie nie
passiert. Das ist eine fundamentale Grenze des Perimeter-Firewall-Modells,
nicht eine Fehlkonfiguration.

### Manuelle Detection — Wireshark Expert Info

<img src="wireshark-duplicate-ip.png" alt="Wireshark: Duplicate IP address detected" width="720">

Wireshark erkennt das Muster automatisch und markiert es als
`[Duplicate IP address detected for 192.168.10.20/192.168.10.1 ...]`,
sobald zwei unterschiedliche MAC-Adressen kurz hintereinander dieselbe IP
beanspruchen — ein klarer, leicht erkennbarer Indicator of Compromise.

### Produktive, automatisierte Gegenmaßnahmen — wo sie tatsächlich sitzen

| Mechanismus | Ebene | Wirkung |
|---|---|---|
| Dynamic ARP Inspection (DAI) | Managed Switch | Verwirft ARP-Antworten, die nicht zu einer vertrauenswürdigen IP-MAC-Bindung passen |
| DHCP Snooping | Managed Switch | Baut die Bindungstabelle für DAI automatisch aus legitimen DHCP-Transaktionen auf |
| Port Security | Managed Switch | Bindet einen Port fest an eine erlaubte MAC-Adresse |
| 802.1X / NAC | Switch/RADIUS | Verhindert unautorisierte Geräte im Segment von vornherein |
| Statische ARP-Einträge | Einzelhost | Schützt kritische Hosts (z. B. Gateway), aber nicht skalierbar |

Der Kern: Echte Prävention sitzt auf dem **Switch**, nicht auf der
Firewall — und genau das ist die Lücke in diesem Homelab, da Proxmox'
`vmbr1` nur eine einfache Linux-Bridge ohne DAI-/Port-Security-Fähigkeiten
ist, anders als ein Enterprise-Switch.

### Offener Punkt: Automatisierte Detection via Arpwatch (nicht abgeschlossen)

Versuch, `arpwatch` auf dem Wazuh-Manager-Host (im LAN-Segment, sieht also
denselben Broadcast-Traffic) zu installieren, um ARP-Änderungen
automatisiert zu loggen und später in eine eigene Wazuh-Regel zu
überführen (analog zur Kerberoasting-Regel aus Kapitel 5). Ergebnis
bisher:

- Ein `os-arpwatch`-Plugin für OPNsense selbst war im Plugin-Repository
  dieser Version nicht auffindbar.
- Auf dem Wazuh-Host (RHEL-Familie, `dnf`) ist `arpwatch` nicht in den
  Standard-Repos enthalten; auch der Versuch, `epel-release`
  nachzuinstallieren, schlug mit "Unable to find a match" fehl —
  vermutlich entweder eine andere RHEL-Version als angenommen oder
  eingeschränkte Repo-Konfiguration auf dem Wazuh-Appliance-Image.

**Nächste Schritte:**
1. RHEL-Version auf dem Wazuh-Host klären (`cat /etc/os-release`), dann
   `epel-release` über die versionsspezifische Fedora-URL direkt per RPM
   installieren statt über `dnf search`.
2. Nach erfolgreicher Installation: Service-Logs (`journalctl -u
   arpwatch`) in die Wazuh-Manager-`ossec.conf` als `<localfile>`
   einbinden.
3. Eigene Wazuh-Regel für "changed ethernet address" / "flip flop"-
   Meldungen schreiben, inkl. MITRE-ATT&CK-Mapping ([T1557.002 – ARP
   Cache Poisoning](https://attack.mitre.org/techniques/T1557/002/)).
4. Optional, separat: `os-wazuh-agent`-Plugin auf OPNsense installieren,
   um allgemein Firewall-/System-Logs (inkl. der Portscan-Blocks aus
   diesem Kapitel) zentral in Wazuh sichtbar zu machen — eigenständiger
   Mehrwert unabhängig von der ARP-Detection.

## Lessons Learned

- **Eine Firewall-Regel ist kein Rundumschutz.** Die Rate-Limit-Regel
  gegen Portscans ist wirkungslos gegen Techniken, die innerhalb eines
  bereits erreichten Segments ablaufen — Perimeter-Security und interne
  Segment-Security sind zwei unterschiedliche Probleme mit
  unterschiedlichen Lösungen (Switch-Ebene statt Firewall-Ebene).
- **Eine portunabhängige Rate-Limit-Regel erkennt mehr als nur Portscans**
  — der Kerberoasting-Nebeneffekt zeigt, dass netzwerkbasierte
  Heuristiken oft breiter wirken als ursprünglich geplant.
- **ARP-Spoofing ist kein Selbstläufer.** Eine vergiftete ARP-Tabelle
  allein beweist noch kein funktionierendes MITM — nur eine echte
  Paket-Capture zeigt, ob Traffic tatsächlich umgeleitet wird.
  Unvollständige Vergiftung (nur eine Richtung aktiv) erzeugt
  irreführende Teilergebnisse.
- **ICMP-Redirects sind ein unterschätztes OPSEC-Problem** bei einfachem
  `arpspoof` + IP-Forwarding, weil Linux dieses Verhalten standardmäßig
  automatisch auslöst.
- **"Detection ohne Wireshark" ist eine reale Lücke**, kein Nice-to-have
  — ohne Switch-seitige Mechanismen (DAI/DHCP Snooping) oder einen
  host-basierten Monitor wie Arpwatch bleibt ARP-Spoofing in einem
  Standard-Setup praktisch unsichtbar.
