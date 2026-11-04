# Chapter 17: Netzwerk-Störungen — Broadcast Storm & doppelte IP-Adresse

## 1. Ziel & Setup

Zweites Packet-Tracer-Lab, bewusst getrennt von Kapitel 16: statt Infrastruktur aufzubauen
(VLANs, Routing, ACLs), geht es hier um zwei Störungsbilder, die im echten Betrieb entstehen —
nicht durch einen Konfigurationsfehler beim Aufbau, sondern durch Entscheidungen oder Zufälle im
laufenden Betrieb.

**Topologie:** zwei Switches (Switch0, Switch1), mehrere Clients, alles im Default-VLAN 1, flaches
Subnetz `192.168.1.0/24` — bewusst ohne VLAN-Komplexität, um die beiden Störungsbilder isoliert zu
betrachten. Switch0 und Switch1 sind **doppelt** verkabelt (zwei separate Links), um eine physische
Redundanz/Schleife zu erzeugen.

## 2. Vorfall 1: Broadcast Storm durch deaktiviertes Spanning Tree

### Ausgangslage — STP schützt von selbst

Mit aktivem Spanning Tree zeigt `show spanning-tree vlan 1` auf Switch1:

```
Root ID    Priority    32769
           Address     0001.63B7.AB03      <- Switch0 (andere Adresse als Bridge ID)
           Cost        19
           Port        21(FastEthernet0/21)

Bridge ID  Priority    32769
           Address     00E0.F9D5.C832      <- dieser Switch (Switch1)

Interface        Role Sts Cost      Prio.Nbr Type
Fa0/1             Desg FWD 19        128.1    P2p
Fa0/21            Root FWD 19        128.21   P2p
Fa0/23            Altn BLK 19        128.23   P2p
```

Da die Root-ID-Adresse von der eigenen Bridge-ID-Adresse abweicht, ist klar: dieser Switch ist
nicht die Root Bridge. Von den zwei physischen Links zwischen Switch0 und Switch1 steht einer
(`Fa0/21`) auf **Root/Forwarding**, der andere (`Fa0/23`) auf **Alternate/Blocking** — STP erkennt
die Redundanz selbstständig und schaltet einen der beiden Pfade logisch ab, bevor überhaupt ein
Problem entstehen kann.

### Der Vorfall

Angenommener Auslöser: ein Kollege deaktiviert Spanning Tree auf beiden Switches, in der (falschen)
Annahme, es verzögere nur unnötig den Verbindungsaufbau beim Hochfahren der Ports — ein in der
Praxis real vorkommender Irrglaube.

```
no spanning-tree vlan 1
```

auf beiden Switches eingegeben. Damit sind **beide** Links zwischen Switch0 und Switch1 gleichzeitig
aktiv — eine echte Layer-2-Schleife.

**Symptom:** Ein einzelner Ping zwischen zwei Clients kommt entweder gar nicht mehr an oder nur mit
deutlicher Verzögerung. Im Simulation-Modus von Packet Tracer zeigt die Event-Detailansicht für das
betroffene Paket:

```
1. Placing packet in Strict Priority Queue.
2. QoS not enabled, packet placed in low priority queue.
3. Low queue size exceeded, packet is dropped.
```

**Interpretation:** Ein einzelner Ping erzeugt niemals genug Traffic, um eine Switch-Warteschlange
zum Überlaufen zu bringen. Der Queue-Overflow ist der eigentliche Beweis für den Broadcast Storm —
insbesondere der initiale ARP-Request (als Broadcast verschickt) wird ohne STP-Blockierung
zwischen den beiden Switches endlos im Kreis geflutet, bis die Ausgangswarteschlange überläuft und
Pakete verworfen werden. In einem echten Netz ist das der Moment, in dem Switches CPU-seitig
einbrechen und ein ganzes Segment lahmlegen.

### Fix

```
spanning-tree vlan 1
```

auf beiden Switches wieder aktiviert. `show spanning-tree vlan 1` zeigt danach erneut einen Port im
Blocking-Zustand auf der redundanten Verbindung, der Ping läuft wieder sauber und ohne Verzögerung
durch.

## 3. Vorfall 2: Doppelte IP-Adresse

### Setup

Zwei Clients im selben Subnetz erhalten absichtlich dieselbe statische IP-Adresse.

**Symptom:** Beim Versuch, die IP zu setzen, meldet das Endgerät selbst einen Konflikt
("Adresse bereits im Netzwerk vorhanden") — noch bevor es überhaupt zu einer echten Kommunikation
mit einem anderen Host kommt.

### Mechanismus dahinter

Die Erkennung läuft über **ARP**, nicht über ICMP: ICMP würde voraussetzen, dass die eigene
IP-Adresse bereits nutzbar ist — genau das soll aber erst geprüft werden, bevor die Adresse verwendet
wird. Stattdessen schickt das Gerät eine **Gratuitous ARP**-Anfrage bzw. einen **ARP Probe**
(RFC 5227) ins lokale Segment: sinngemäß "wer hat die IP X?", bezogen auf die eigene, noch nicht
bestätigte Adresse. Antwortet jemand darauf, ist die Adresse bereits vergeben, und das Gerät meldet
den Konflikt, statt die Adresse stillschweigend zu übernehmen.

### Fix

Einem der beiden Clients eine eindeutige, freie IP-Adresse im selben Subnetz zugewiesen. Die
Konfliktmeldung verschwindet, der Ping läuft danach wieder zuverlässig durch.

## 4. Kernlektionen

- **STP ist kein optionales Feature, sondern aktiver Schutz:** Ein einzelner blockierter Port
  verhindert strukturell jede Layer-2-Schleife. Wird er deaktiviert, entsteht die Schleife nicht
  theoretisch, sondern sofort beim ersten Broadcast (z. B. einem einzelnen ARP-Request).
- **Ein Queue-Overflow bei trivialem Traffic ist ein Alarmsignal, kein Zufall:** Wenn ein einzelner
  Ping zu "Low queue size exceeded" führt, steckt dahinter mit hoher Wahrscheinlichkeit um ein
  Vielfaches mehr Traffic, als der Nutzer selbst erzeugt hat — ein typisches Symptom für eine
  Schleife oder einen Storm, nicht für ein normales Lastproblem.
- **Doppelte IP-Adressen werden proaktiv erkannt, nicht erst durch fehlgeschlagene Kommunikation:**
  Gratuitous ARP/ARP Probe prüft die Adresse, bevor sie überhaupt genutzt wird — ein Beispiel dafür,
  dass ARP nicht nur für Adressauflösung, sondern auch für Konflikterkennung im lokalen Segment
  genutzt wird.
- **Beide Vorfälle entstehen typischerweise nicht durch Tippfehler beim Aufbau, sondern durch
  Entscheidungen im laufenden Betrieb** (STP "zur Vereinfachung" deaktiviert, eine vergessene
  statische IP neben einem DHCP-Pool) — genau die Art Störung, die in der Praxis häufiger vorkommt
  als ein falsch getippter Konfigurationsbefehl.
