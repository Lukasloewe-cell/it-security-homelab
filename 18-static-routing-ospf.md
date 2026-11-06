# Kapitel 18: Static Routing & OSPF zwischen zwei Routern (Cisco Packet Tracer)

## 1. Ziel & Setup

Drittes eigenständiges Netzwerk-Lab, diesmal mit zwei Routern statt einem — Fokus liegt auf
Routing zwischen zwei getrennten Netzen, die über kein gemeinsames Layer-2-Gerät verbunden sind,
sondern ausschließlich über eine Router-zu-Router-Verbindung.

**Topologie:** 2 Router (Router0, Router1), jeweils ein Switch + Client pro Router, die Router
direkt über ein `/30`-Transfernetz verbunden.

| Komponente | Netz | Router |
|---|---|---|
| Client A | 192.168.10.0/24 | Router0 |
| Client B | 192.168.20.0/24 | Router1 |
| Transfernetz | 10.10.10.0/30 | Router0 (.1) ↔ Router1 (.2) |

**Ziel:** Client A und Client B sollen sich über die beiden Router hinweg pingen können — zuerst
mit **Static Routing**, danach dieselbe Aufgabe nochmal mit **OSPF**, um den Unterschied zwischen
manuell eingetragenen und dynamisch ausgehandelten Routen direkt zu erleben.

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

## 4. Kernlektionen

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
