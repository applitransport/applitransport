import 'dart:math';

import 'package:applitransport/data/community.dart';
import 'package:applitransport/poc/data.dart';
import 'package:applitransport/poc/line_vehicles.dart';
import 'package:applitransport/poc/ride_control.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

// Ligne droite de 3 km vers l'est, arrêts tous les 1 000 m ; 2 min entre deux arrêts.
const _lat = 48.78, _lon0 = 2.04;
final _mPerDegLon = 6371000 * pi / 180 * cos(_lat * pi / 180);
const _mPerDegLat = 6371000 * pi / 180;
LatLng _at(double x, [double y = 0]) => LatLng(_lat + y / _mPerDegLat, _lon0 + x / _mPerDegLon);

void main() {
  final variant = Variant(
    'Est',
    [for (var i = 0; i < 4; i++) Stop('Arrêt $i', _at(i * 1000.0), '', 'IDFM:$i')],
    [for (var x = 0.0; x <= 3000; x += 250) _at(x)],
    const [
      [36000, 36120, 36240, 36360], // 10:00 : à 10:03 elle est à 1 500 m
      [35900, 36020, 36140, 36260], // 9:58:20 : à 10:03 elle est vers 2 333 m
      [37000, 37120, 37240, 37360], // pas encore partie
    ],
    const ['x-1', 'x-2', 'x-3'],
  );
  final d = Direction(0, 'Est', [variant]);
  const now = 36180; // 10:03

  test('la course la plus proche de l\'usager en premier, celles hors de portée ou à l\'arrêt écartées', () {
    final r = aboardCandidates(d, _at(1520, 15), now);
    expect(r.onTrack, isTrue);
    expect([for (final c in r.candidates) c.t], [0, 1]);
    expect(r.candidates.first.gap, lessThan(50));
    expect(r.candidates.first.along, closeTo(1520, 2));
    expect(r.candidates[1].gap, closeTo(813, 20));
  });

  test('hors du tracé : aucun candidat', () {
    final r = aboardCandidates(d, _at(1500, 300), now);
    expect(r.onTrack, isFalse);
    expect(r.candidates, isEmpty);
  });

  test('la position vue par un voyageur prime sur l\'horaire', () {
    // la course 2 est vue à 1 600 m, alors que son horaire la place vers 2 333 m
    final seen = crowdEstimate(
      variant,
      1,
      CrowdVehicle.fromJson({
        'course': '2',
        'sens': 0,
        'arret_prec': 'IDFM:1',
        'arret_suiv': 'IDFM:2',
        'progression': 0.6,
        'lat': _at(1600).latitude,
        'lon': _at(1600).longitude,
        'sources': 1,
        'concordant': true,
        'vu_il_y_a_s': 5,
      }),
      ageSec: 5,
      nowSec: now,
    )!;
    final r = aboardCandidates(d, _at(1620), now, crowd: {'0/1': seen});
    expect(r.candidates.first.t, 1);
    expect(r.candidates.first.gap, lessThan(30));
  });

  test('nom d\'une course', () {
    final l = DemoLine('C1', 'T6', 'tram', const Color(0xFFFF0000), const Color(0xFFFFFFFF), [d]);
    expect(tripName(l, d, 0, 0), 'Tram de 10:00 (départ Arrêt 0) → Est');
  });

  test('signalement placé dans le sens affiché : course, arrêt ; autre sens écarté', () {
    CrowdReport r(String? course, String? stop) => CrowdReport.fromJson({
      'id': 's',
      'type': 'incident',
      'detail': 'panne',
      'course': course,
      'arret': stop,
      'sources': 1,
      'premier': 0,
      'dernier': 0,
    });
    final both = reportPlace(d, r('1', 'IDFM:2'), now)!;
    expect((both.variant, both.trip, both.stopIndex, both.stop!.name), (0, 0, 2, 'Arrêt 2'));
    final stopOnly = reportPlace(d, r(null, 'IDFM:3'), now)!;
    expect((stopOnly.variant, stopOnly.stopIndex), (null, 3));
    expect(reportPlace(d, r('999', null), now), isNull); // course d'un autre sens
    expect(reportPlace(d, r(null, 'IDFM:77'), now), isNull); // arrêt d'un autre sens
    final line = reportPlace(d, r(null, null), now)!;
    expect((line.variant, line.stop), (null, null));
  });

  test('À bord d\'un bus choisi : sur le tracé à 60 m près, à 400 m du bus ; théorique loin : confirmation', () {
    expect(boardCheck(variant, _at(1500, 100), _at(1500), theoretical: false).check, BoardCheck.offLine);
    final near = boardCheck(variant, _at(1500, 20), _at(1800), theoretical: false);
    expect((near.check, near.along.round(), near.gap.round()), (BoardCheck.ok, 1500, 300));
    expect(boardCheck(variant, _at(1500), _at(2100), theoretical: false).check, BoardCheck.tooFar);
    final far = boardCheck(variant, _at(1500), _at(2100), theoretical: true);
    expect((far.check, far.gap.round()), (BoardCheck.confirm, 600));
  });
}
