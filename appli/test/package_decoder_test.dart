import 'dart:convert';
import 'dart:io';

import 'package:applitransport/data/package_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

// Les paquets réels (test/fixtures) décodés en Dart doivent donner les mêmes horaires que le
// générateur Python de la maquette (test/fixtures/poc_data_reference.json, produit pour le 29/10/2026).
void main() {
  final poc = jsonDecode(File('test/fixtures/poc_data_reference.json').readAsStringSync());
  final day = DateTime.parse(poc['generated_for']);

  for (final code in ['C01527', 'C01528']) {
    test('paquet $code identique aux données de la maquette', () {
      final pkg = readPackage(File('test/fixtures/$code.json.gz').readAsBytesSync());
      final line = timetableFor(pkg, day);
      final ref = (poc['demo_lines'] as List).firstWhere((l) => l['id'] == code);
      expect(line.name, ref['name']);
      expect(line.directions.length, (ref['directions'] as List).length);
      for (var d = 0; d < line.directions.length; d++) {
        final mine = line.directions[d], theirs = ref['directions'][d];
        expect(mine.label, theirs['label']);
        expect(mine.variants.length, (theirs['variants'] as List).length);
        for (var v = 0; v < mine.variants.length; v++) {
          final a = mine.variants[v], b = theirs['variants'][v];
          expect(a.headsign, b['headsign']);
          expect([for (final s in a.stops) s.name], [for (final s in b['stops']) s[0]]);
          expect([for (final s in a.stops) s.area], [for (final s in b['stops']) s[3]]);
          expect(a.trips, [for (final t in b['trips']) List<int>.from(t)]);
          expect(a.tripIds.length, a.trips.length);
        }
      }
      expect(lastServiceDay(pkg)!.isAfter(day), isTrue);
    });
  }

  test('polyligne : décodage de l\'exemple Google', () {
    final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(pts.length, 3);
    expect(pts[0].latitude, closeTo(38.5, 1e-6));
    expect(pts[2].longitude, closeTo(-126.453, 1e-6));
  });
}
