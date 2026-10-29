import 'dart:convert';
import 'dart:io';

import 'package:applitransport/poc/itineraries.dart';
import 'package:flutter_test/flutter_test.dart';

// Vraie réponse du calculateur IDFM : Le Hameau → Paris Montparnasse, 29/10/2026 vers 14 h 50.
void main() {
  test('itinéraires du calculateur', () {
    final data = jsonDecode(File('test/fixtures/calcul_hameau_montparnasse.json').readAsStringSync());
    final s = ItinerarySearch.fromNavitia(data, DateTime(2026, 10, 29));
    expect(s.journeys.length, 4);
    // triés par heure de départ
    for (var i = 1; i < s.journeys.length; i++) {
      expect(s.journeys[i].dep >= s.journeys[i - 1].dep, isTrue);
    }
    final withBus = s.journeys.firstWhere((j) => j.transit.first.lineCode == '5143');
    final bus = withBus.transit.first;
    expect(bus.lineId, 'C01532'); // ligne du catalogue, pour le temps réel et « Suivre ce bus »
    expect(bus.from!.area, 'IDFM:63626'); // zone Le Hameau
    expect(bus.from!.name, startsWith('Le Hameau'));
    expect(bus.shape.length, greaterThan(10));
    expect(bus.baseDep, 15 * 3600 + 9 * 60); // 15:09
    expect(withBus.transit.map((t) => t.lineCode), ['5143', 'N', 'TER']);
    // perturbations jointes, lisibles
    expect(s.disruptions, isNotEmpty);
    expect(bus.disruptions.every(s.disruptions.containsKey), isTrue);
  });
}
