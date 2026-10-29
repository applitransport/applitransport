import 'dart:convert';
import 'dart:io';

import 'package:applitransport/data/package_decoder.dart';
import 'package:applitransport/data/realtime.dart';
import 'package:flutter_test/flutter_test.dart';

// Rattachement de vraies réponses PRIM (enregistrées le 29/10/2026) aux horaires téléchargés.
Map<String, dynamic> json(String f) => jsonDecode(File('test/fixtures/$f').readAsStringSync());

void main() {
  final day = DateTime(2026, 10, 29);

  test('identifiants SIRI → GTFS', () {
    expect(gtfsStopId('STIF:StopPoint:Q:20612:'), 'IDFM:20612');
    expect(gtfsStopId('STIF:StopArea:SP:461504:'), 'IDFM:monomodalStopPlace:461504');
    expect(gtfsStopId('529FSQY:StopPoint:BP:50186754:LOC'), isNull);
  });

  test('bus 5104 : rattachement par numéro de course', () {
    final data = json('prim_et_5104_1022.json');
    final now = DateTime.parse(data['Siri']['ServiceDelivery']['ResponseTimestamp']).toLocal();
    final line = timetableFor(readPackage(File('test/fixtures/C01527.json.gz').readAsBytesSync()), day);
    final journeys = parseEstimatedTimetable(data);
    expect(journeys.length, 12);
    final rt = matchToTimetable(line, journeys, day, now, remaining: true);
    expect(rt.length, 12); // toutes les courses retrouvées
    for (final e in rt.entries) {
      expect(e.value.nextIndex, isNotNull, reason: e.key);
      expect(e.value.delays.length, e.value.stopCount);
    }
    // une course en circulation : arrêts déjà desservis avant le prochain arrêt
    final running = rt.values.firstWhere((r) => r.nextIndex! > 0);
    expect(running.passed(0), isTrue);
    expect(running.passed(running.nextIndex!), isFalse);
  });

  test('train N : rattachement par arrêt et heure prévue (identifiants SNCF)', () {
    final data = json('prim_et_N_1359.json');
    final now = DateTime.parse(data['Siri']['ServiceDelivery']['ResponseTimestamp']).toLocal();
    final line = timetableFor(readPackage(File('test/fixtures/C01736.json.gz').readAsBytesSync()), day);
    final journeys = parseEstimatedTimetable(data);
    expect(journeys.length, 24);
    expect(journeys.first.number.contains('-'), isTrue); // identifiant SNCF, pas un numéro GTFS
    final rt = matchToTimetable(line, journeys, day, now, remaining: true);
    // presque tous les trains retrouvés par l'heure ; aucun rattaché deux fois
    expect(rt.length, greaterThanOrEqualTo(20));
  });

  test('retards : remplissage entre arrêts connus', () {
    final r = TripRealtime({2: 60, 5: 180}, 7, nextIndex: 2);
    expect(r.delays, [60, 60, 60, 180, 180, 180, 180]);
    expect(r.passed(1), isTrue);
    expect(r.passed(2), isFalse);
  });
}
