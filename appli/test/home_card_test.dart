// Accueil, ligne qui ne circule pas (ou dans un seul sens) le jour même : l'appli plantait (écran gris)
// en 1.5.2, et l'accueil affichait le sens opposé quand un seul sens circulait.
import 'dart:io';

import 'package:applitransport/data/package_decoder.dart';
import 'package:applitransport/poc/data.dart';
import 'package:applitransport/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

Direction dir(int id, String label, List<String> stops) => Direction(id, label, [
  Variant(
    label,
    [for (final s in stops) Stop(s, const LatLng(48.77, 2.04))],
    const [],
    [
      [for (var i = 0; i < stops.length; i++) 8 * 3600 + i * 120],
    ],
  ),
]);

DemoLine line(List<Direction> ds) => DemoLine('C01527', '5104', 'bus', Colors.red, Colors.white, ds);

void main() {
  final aller = dir(0, 'Pas du Lac', ['Le Hameau', 'Paul Fort', 'Pas du Lac']);
  final retour = dir(1, 'Trappes Gare', ['Pas du Lac', 'Paul Fort', 'Le Hameau', 'Trappes Gare']);

  group('sens : identifiant ↔ place dans les horaires du jour', () {
    test('les deux sens circulent : place = identifiant', () {
      expect(dirIndexOf([aller, retour], 0), 0);
      expect(dirIndexOf([aller, retour], 1), 1);
      expect(dirIdAt([aller, retour], 1), 1);
    });

    test('seul le sens 1 circule : il est à la place 0', () {
      expect(dirIndexOf([retour], 1), 0);
      expect(dirIdAt([retour], 0), 1);
      expect(dirIndexOf([retour], 0), isNull); // le sens 0 ne circule pas aujourd'hui
    });

    test('aucun parcours ce jour-là', () {
      expect(dirIndexOf([], 0), isNull);
      expect(dirIdAt([], 0), 0);
    });
  });

  group('carte de l\'accueil', () {
    test('sens retenu présent : arrêt → direction', () {
      final c = homeCard(line([aller, retour]), (dir: 1, stop: 'Le Hameau'));
      expect(c.direction, same(retour));
      expect(homeCardTitle(c.stop!, c.direction), 'Le Hameau → Trappes Gare');
      expect(homeCardEmpty(c.direction), 'Plus de passage aujourd\'hui.');
    });

    test('aucun parcours aujourd\'hui (plantage de la 1.5.2) : arrêt seul, pas de service', () {
      final c = homeCard(line([]), (dir: 0, stop: 'Le Hameau'));
      expect(c.direction, isNull);
      expect(homeCardTitle(c.stop!, c.direction), 'Le Hameau');
      expect(homeCardEmpty(c.direction), 'Pas de service aujourd\'hui.');
    });

    test('sens retenu absent aujourd\'hui : pas l\'autre sens à sa place', () {
      // lineStop() renvoie dir: null quand le sens retenu ne circule pas ce jour-là
      final c = homeCard(line([retour]), (dir: null, stop: 'Le Hameau'));
      expect(c.direction, isNull);
      expect(homeCardTitle(c.stop!, c.direction), 'Le Hameau');
    });

    test('aucun arrêt retenu : premier sens du jour, pas d\'arrêt', () {
      final c = homeCard(line([retour]), null);
      expect(c.direction, same(retour));
      expect(c.stop, isNull);
      expect(homeCard(line([]), null).direction, isNull);
    });
  });

  test('vrai paquet (5104) un jour sans service : aucun sens, sans erreur', () {
    final pkg = readPackage(File('test/fixtures/C01527.json.gz').readAsBytesSync());
    final last = lastServiceDay(pkg)!;
    // surlendemain du dernier jour de service : ni courses du jour, ni courses de la nuit précédente
    final l = timetableFor(pkg, DateTime(last.year, last.month, last.day + 2));
    expect(l.directions, isEmpty);
    final c = homeCard(l, (dir: dirIndexOf(l.directions, 0), stop: 'Le Hameau'));
    expect(c.direction, isNull);
    expect(homeCardTitle(c.stop!, c.direction), 'Le Hameau');
  });
}
