import 'package:applitransport/data/walk_router.dart';
import 'package:applitransport/poc/itineraries.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chemin à pied IGN : tracé, distance, durée', () {
    final p = parseWalkPath({
      'distance': 2206.4,
      'duration': 1993.8,
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [2.03676, 48.77131],
          [2.04, 48.775],
          [2.05012, 48.78478],
        ],
      },
    })!;
    expect(p.shape.length, 3);
    expect(p.shape.first.latitude, 48.77131);
    expect(p.meters, 2206.4);
    expect(p.seconds, 1994);
    expect(
      parseWalkPath({
        'geometry': {'coordinates': []},
      }),
      isNull,
    );
  });

  test('géocodage inverse : première adresse', () {
    final p = parseReverse({
      'features': [
        {
          'geometry': {
            'coordinates': [2.050065, 48.784639],
          },
        },
      ],
    })!;
    expect(p.longitude, 2.050065);
    expect(parseReverse({'features': []}), isNull);
  });

  test('itinéraire « à vol d\'oiseau » seulement, ou vrai trajet', () {
    Map<String, dynamic> section(String type, int d) => {
      'type': type,
      'duration': d,
      'geojson': {'coordinates': []},
    };
    final day = DateTime(2026, 11, 20);
    final crow = Journey.fromNavitia({
      'sections': [section('crow_fly', 2208)],
    }, day);
    expect(crow.onlyCrowFly, isTrue);
    expect(crow.sections.single.crowFly, isTrue);
    final real = Journey.fromNavitia({
      'sections': [section('street_network', 808), section('public_transport', 180)],
    }, day);
    expect(real.onlyCrowFly, isFalse);
  });
}
