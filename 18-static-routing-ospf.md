# Kapitel 18: Static Routing, OSPF & NAT/PAT zwischen zwei Routern (Cisco Packet Tracer)

## 1. Ziel & Setup

Drittes eigenständiges Netzwerk-Lab, diesmal mit zwei Routern statt einem — Fokus liegt auf
Routing zwischen zwei getrennten Netzen, die über kein gemeinsames Layer-2-Gerät verbunden sind,
sondern ausschließlich über eine Router-zu-Router-Verbindung. Im letzten Teil kommt zusätzlich
NAT/PAT dazu, mit Router1 als simulierter "Außenwelt"-Seite.

**Topologie:** 2 Router (Router0, Router1), jeweils ein Switch + Client pro Router, die Router
direkt über ein `/30`-Transfernetz verbunden.

| Komponente | Netz | Router |
|---|---|---|
| Client A | 192.168.10.0/24 | Router0 |
| Client B | 192.168.20.0/24 | Router1 |
| Transfernetz | 10.10.10.0/30 | Router0 (.1) ↔ Router1 (.2) |

**Ziel:** Client A und Client B sollen sich über die beiden Router hinweg pingen können — zuerst
mit **Static Routing**, danach dieselbe Aufgabe nochmal mit **OSPF**, um den Unterschied zwischen
manuell eingetragenen und dynamisch ausgehandelten Routen direkt zu erleben. Im dritten Teil wird
Router1 konzeptionell zur "Außenwelt": Client A's Netz soll über **NAT/PAT** so übersetzt werden,
dass es nach außen wie eine einzige IP erscheint.

**Wahl der `/30`-Maske für das Transfernetz:** Zwischen zwei Routern werden nur zwei nutzbare
Adressen benötigt (je eine pro Router-Interface) — eine `/30` (`255.255.255.252`) liefert exakt
das, ohne Adressen zu verschwenden, die ohnehin nie genutzt würden.

## 2. Static Routing

### Befehlsaufbau

Eine statische Route braucht immer drei Angaben: das Zielnetz, dessen Maske, und die
**Next-Hop-Adresse** — die Adresse des *Nachbarn*, nie die eigene.

Auf Router0 (kennt Client A's Netz direkt, braucht eine Route zu Client B's Netz):

```
ip route 192.168.20.0 255.255.255.0 10.10.10.2
```

Auf Router1 (umgekehrt, Route zu Client A's Netz):

```
ip route 192.168.10.0 255.255.255.0 10.10.10.1
```

Beide Routen tauchen danach in `show ip route` mit dem Code `S` auf.

### Debugging: Ping funktioniert trotz korrekter Routen nicht

Nach Eintragen beider Routen: `show ip route` auf beiden Routern korrekt, beide Interfaces
`up/up`. Trotzdem schlug der Ping zwischen den Clients fehl (`Request timed out`).

**Eingrenzung über Testreihe statt Rätselraten:**

1. Router0 → Client B (192.168.20.2) direkt angepingt: **erfolgreich.**
2. Router1 → Client A (192.168.10.x) direkt angepingt: **fehlgeschlagen.**

Dieser Unterschied täuschte zunächst eine Asymmetrie in der Router-Konfiguration vor — beide
`show ip route`-Outputs waren aber nachweislich korrekt (beide Static Routes vorhanden, beide
Interfaces up). Das Problem lag also nicht im Routing selbst.

**Root Cause:** Im DHCP-Pool für Client A's Netz fehlte das **Default-Gateway**
(`default-router`). Ohne eingetragenes Gateway weiß ein Client zwar, welche IP er selbst hat,
aber nicht, wohin er Pakete für Ziele außerhalb seines eigenen Subnetzes schicken soll — er
schickt sie dann gar nicht erst raus, statt sie (falsch) zu versenden. Das erklärt auch, warum
Router0 → Client B funktionierte: dieser Test prüft nur die Rückroute zum Router selbst
(directly connected), nicht den Weg vom Client aus.

**Fix:** `default-router 192.168.10.1` im DHCP-Pool ergänzt. Danach Ping in beide Richtungen
erfolgreich.

## 3. OSPF — dieselbe Aufgabe dynamisch gelöst

Static Routes auf beiden Routern entfernt (`no ip route ...`), um sauber zu sehen, dass OSPF die
Arbeit eigenständig übernimmt.

### Grundbegriffe

- **Process-ID** (`router ospf 1`): rein lokale Nummer, muss zwischen Routern nicht
  übereinstimmen — dient nur zur Unterscheidung mehrerer OSPF-Instanzen auf demselben Router.
- **Area**: Gruppierungsnummer, die auf allen Routern **übereinstimmen muss**, die sich als
  Nachbarn sehen sollen. In diesem Lab reicht eine einzige Area (`0`, die Backbone-Area).
- **Wildcard-Maske**: das Gegenteil einer Subnetzmaske (`1` = "muss nicht übereinstimmen",
  `0` = "muss übereinstimmen") — exakt dasselbe Prinzip wie bei Extended ACLs in Kapitel 16,
  nur jetzt im OSPF-`network`-Statement. Berechnung: 255 minus jedes Oktett der Subnetzmaske.

### Debugging 1: Falsches Netz in der `network`-Zeile

Erster Versuch auf Router0:

```
router ospf 1
 network 192.168.20.0 0.0.0.255 area 0
```

Das ist jedoch Client B's Netz — das hängt an Router1, nicht an Router0. Die `network`-Zeile
sagt OSPF nicht "lerne dieses fremde Netz", sondern "aktiviere OSPF auf dem Interface, das zu
diesem **eigenen, direkt verbundenen** Netz gehört". Da auf Router0 kein Interface zu
192.168.20.0 existiert, passierte schlicht nichts — kein Neighbor, keine OSPF-Route.

**Fix:** Die `network`-Zeile muss die tatsächlich an diesem Router direkt verbundenen Netze
referenzieren:

```
router ospf 1
 network 192.168.10.0 0.0.0.255 area 0
```

### Debugging 2: Fehlendes Transfernetz

Auch nach der Korrektur blieb `show ip ospf neighbor` auf beiden Routern leer. Grund: Keiner der
beiden Router hatte eine `network`-Zeile für das gemeinsame Transfernetz `10.10.10.0/30`
eingetragen — ohne das sendet keiner der Router OSPF-Hello-Pakete auf dem Interface, über das die
beiden sich überhaupt erreichen könnten. Es fehlte nicht die Konfiguration zum fremden Netz,
sondern zum **gemeinsamen** Netz dazwischen.

**Fix**, auf beiden Routern ergänzt:

```
network 10.10.10.0 0.0.0.3 area 0
```

(Wildcard für `255.255.255.252`: `0.0.0.3`.)

Direkt danach: `show ip ospf neighbor` zeigte kurz den Zwischenzustand `EXSTART/BDR`, dann im
Log automatisch `%OSPF-5-ADJCHG: ... from LOADING to FULL, Loading Done`. `show ip route` zeigte
anschließend die vorher fehlenden Netze als `O`-Route, z. B.:

```
O    192.168.10.0/24 [110/2] via 10.10.10.1, 00:00:01, GigabitEthernet0/0
```

**`[110/2]` erklärt:**
- `110` = **Administrative Distance** von OSPF — ein protokollfester Vertrauenswert, der nur
  entscheidet, welcher Quelle der Router glaubt, falls mehrere Routing-Protokolle dieselbe Route
  anbieten (Static Route: AD `1`, OSPF: AD `110`, RIP: AD `120`).
- `2` = **Metric/Cost**, bei OSPF auf Basis der Bandbreite der durchlaufenen Interfaces
  berechnet — niedrigerer Wert bedeutet einen (aus OSPF-Sicht) besseren Pfad.

### Debugging 3 (Vorhersage, verifiziert): Area-Mismatch

Erwartung vor dem Test: Setzt man auf einem der beiden Router die Area in der `network`-Zeile
bewusst anders (`area 1` statt `area 0`), sehen sich die Router nicht mehr — weil die Area auf
beiden Seiten übereinstimmen muss, um überhaupt eine Nachbarschaft aufzubauen.

**Test:** Auf Router1 `no network 10.10.10.0 0.0.0.3 area 0` und erneut mit `area 1`
eingetragen. Ergebnis: `show ip ospf neighbor` auf beiden Routern sofort leer — die Nachbarschaft
verschwindet komplett, nicht nur teilweise. Bestätigt die Vorhersage.

**Bemerkenswert:** Ein Area-Mismatch erzeugt dabei keine explizite Fehlermeldung wie z. B. ein
Passwort-Mismatch — die Router ignorieren sich einfach stillschweigend. In einem echten Netz ist
das schwerer zu debuggen, weil kein Log direkt auf die Ursache zeigt.

## 4. NAT/PAT — Router1 als simulierte Außenwelt

**Szenario:** Router1 (und damit Client B's Netz) übernimmt konzeptionell die Rolle der
"Außenwelt"/eines ISPs. Client A's Netz (hinter Router0) soll per **PAT (NAT Overload)** so
übersetzt werden, dass alle seine Clients nach außen unter einer einzigen IP erscheinen —
genau wie ein Heimrouter, der mehrere Geräte hinter nur einer öffentlichen IP versteckt.

### Grundbegriffe

- **NAT-Zweck:** IPv4-Adressen sind begrenzt; statt jedem internen Gerät eine eigene öffentliche
  IP zu geben, übersetzt der Router zwischen privaten (internen) und öffentlichen (externen)
  Adressen und merkt sich die Zuordnung in einer NAT-Tabelle.
- **Static NAT:** feste, manuell eingetragene 1:1-Zuordnung einer privaten zu einer öffentlichen
  IP.
- **Dynamic NAT:** ebenfalls 1:1, aber automatisch aus einem **Pool mehrerer öffentlicher IPs**
  vergeben (first come, first served) — ohne Pool kein Dynamic NAT.
- **PAT (NAT Overload):** mehrere private IPs teilen sich **eine einzige** öffentliche IP,
  unterschieden über die Portnummer (bzw. bei ICMP über das Identifier-Feld, da ICMP keine
  echten Ports hat). Das ist, was ein gewöhnlicher Heimrouter nutzt — er bekommt vom ISP nur eine
  öffentliche IP, kann also gar kein Dynamic NAT (das einen Pool braucht) einsetzen.

### Befehlsaufbau

Drei Bausteine:

```
! 1. Interface-Rollen markieren
interface GigabitEthernet0/1
 ip nat inside

interface GigabitEthernet0/0
 ip nat outside

! 2. Access-List: welcher Traffic übersetzt werden soll
access-list 1 permit 192.168.10.0 0.0.0.255

! 3. Das eigentliche PAT-Statement
ip nat inside source list 1 interface GigabitEthernet0/0 overload
```

Auf Router0: Gi0/1 (Richtung Client A) = inside, Gi0/0 (Richtung Router1/Transfernetz) =
outside. Das Schlüsselwort `overload` ist das, was aus gewöhnlichem Dynamic NAT PAT macht —
ohne das würde der Router versuchen, pro internem Client eine eigene öffentliche IP zu
reservieren, hätte aber nur eine.

### Debugging: Doppeltes NAT auf beiden Routern

Erster Versuch: NAT/PAT wurde versehentlich auf **beiden** Routern eingerichtet — einmal für
192.168.10.0/24 auf Router0, einmal für 192.168.20.0/24 auf Router1. Danach funktionierte der
Ping zwischen den Clients nicht mehr.

**Root Cause:** Das Szenario sah vor, dass nur Router0 NAT macht (Client A's Netz nach außen
versteckt), während Router1 die Außenwelt simuliert. Übersetzen **beide** Seiten gleichzeitig,
verändert jeder Router die Quelladresse auf seiner eigenen Seite — die Antwortpakete lassen sich
dadurch keiner bestehenden Übersetzung mehr eindeutig zuordnen, weil beide Router sich
gegenseitig die Adressen verändern, bevor der jeweils andere sie wieder zuordnen kann.

**Fix:** NAT/PAT-Konfiguration auf Router1 vollständig per `no` zurückgebaut (PAT-Statement,
`ip nat inside`/`outside` auf den Interfaces, Access-List) — dasselbe Rückbau-Prinzip wie bei
OSPF-`network`-Zeilen und ACLs vorher: der exakt gleiche Befehl, nur mit `no` davor.

### Verifikation

Nach dem Rückbau auf Router1: Ping von Client A zu Client B lief wieder. Direkt danach
`show ip nat translations` auf Router0:

```
Pro  Inside global     Inside local       Outside local      Outside global
icmp 10.10.10.1:14     192.168.10.3:14    192.168.20.2:14    192.168.20.2:14
icmp 10.10.10.1:15     192.168.10.3:15    192.168.20.2:15    192.168.20.2:15
icmp 10.10.10.1:16     192.168.10.3:16    192.168.20.2:16    192.168.20.2:16
icmp 10.10.10.1:17     192.168.10.3:17    192.168.20.2:17    192.168.20.2:17
```

**Beweis, dass PAT tatsächlich greift:** Jede der vier Ping-Antworten bekam eine eigene
Übersetzungs-ID (14–17), **Inside local** (`192.168.10.3`) wurde zu **Inside global**
(`10.10.10.1`) übersetzt — nach außen sieht der Traffic aus, als käme er direkt von Router0,
nicht von Client A. Da ICMP keine echten Ports besitzt, nutzt der Router das ICMP-
Identifier-Feld als Ersatz, um pro "Verbindung" trotzdem eine eindeutige Zuordnung zur
Rückübersetzung zu haben. Bei einer echten TCP-Verbindung stünde in derselben Tabelle stattdessen
ein echter, zufälliger Source-Port (z. B. aus dem Bereich 49152–65535) und ein fester
Destination-Port (z. B. `443`).

## 5. Kernlektionen

- **Eine korrekte Router-Konfiguration reicht nicht, wenn der Client sein Gateway nicht kennt:**
  Ohne `default-router` im DHCP-Pool (oder manuell gesetztes Gateway) verlässt ein Paket für ein
  fremdes Netz den Client gar nicht erst — unabhängig davon, wie korrekt die Routen auf den
  Routern selbst sind. Das ist der Client-seitige Spiegel zur fehlenden `permit`-Zeile in einer
  ACL (Kapitel 16): ein einzelner fehlender Eintrag legt eine ganze Richtung lahm.
- **Ein einseitig erfolgreicher Ping beweist nicht, dass die Route in beide Richtungen steht:**
  Ein Ping vom Router aus zum fremden Client testet immer auch die (meist unkritische)
  Rückroute zum eigenen, direkt verbundenen Interface — nicht die eigentlich kritische Strecke
  über den Client selbst.
- **OSPF `network`-Zeilen beschreiben eigene, nicht fremde Netze:** Die Zeile aktiviert OSPF auf
  dem lokalen Interface, das zum angegebenen Netz gehört — sie importiert kein fremdes Netz.
  Fremde Netze lernt der Router automatisch, sobald die Nachbarschaft über das **gemeinsame**
  Netz (hier das Transfernetz) steht.
- **Die Area-Nummer ist eine Zugangsbedingung für die Nachbarschaft, keine Konfigurationsdetail:**
  Stimmt sie nicht überein, bauen zwei Router gar keine Beziehung auf — ohne klare
  Fehlermeldung, was das in der Praxis zu einer der unauffälligeren OSPF-Fehlerquellen macht.
- **Static Routing vs. OSPF — der praktische Unterschied:** Bei Static Routing trägt man jede
  Route einzeln und explizit ein (`ip route <ziel> <maske> <next-hop>`); bei OSPF markiert man
  nur die eigenen, direkt verbundenen Netze (`network`-Zeilen) und die Router handeln den Rest —
  Nachbarschaft, Linkstate-Austausch, Pfadberechnung — selbstständig aus.
- **NAT/PAT gehört nur auf die Seite, die tatsächlich "nach außen" tritt:** Richtet man es
  versehentlich auf beiden Seiten einer Verbindung ein, übersetzen sich beide Router gegenseitig
  die Adressen weg, bevor der andere sie zuordnen kann — die Verbindung bricht komplett, nicht
  nur teilweise.
- **Dynamic NAT und PAT sind keine Synonyme:** Dynamic NAT braucht einen Pool mehrerer
  öffentlicher IPs für automatische 1:1-Zuordnung; PAT (Overload) kommt mit nur einer einzigen
  öffentlichen IP aus, weil zusätzlich die Portnummer (bzw. bei ICMP das Identifier-Feld) zur
  Unterscheidung genutzt wird — genau das, was ein gewöhnlicher Heimrouter mit nur einer
  ISP-zugewiesenen IP einsetzt.
