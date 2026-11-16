import 'package:applitransport/poc/data.dart';
import 'package:applitransport/poc/nearby.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

StopArea _area(String name, double lat, double lon, {List<String> lines = const ['IDFM:C01527']}) =>
    StopArea.fromJson({'id': name, 'name': name, 'lat': lat, 'lon': lon, 'lines': lines});

void main() {
  const me = LatLng(48.7800, 2.0400);
  // 0,001° de latitude ≈ 111 m
  final areas = [
    _area('Loin', 48.7900, 2.0400), // ≈ 1,1 km
    _area('Proche', 48.7810, 2.0400), // ≈ 110 m
    _area('Moyen', 48.7850, 2.0400), // ≈ 560 m
    _area('Sans ligne', 48.7801, 2.0400, lines: []),
  ];

  test('arrêts à moins de 800 m, du plus proche au plus loin, sans les zones sans ligne', () {
    final r = nearbyAreas(areas, me);
    expect([for (final (a, _) in r) a.name], ['Proche', 'Moyen']);
    expect(r.first.$2, closeTo(111, 2));
  });

  test('arrêt le plus proche d\'une ligne', () {
    final stops = [const Stop('A', LatLng(48.7850, 2.0400)), const Stop('B', LatLng(48.7805, 2.0400))];
    final (s, d) = nearestStop(stops, me)!;
    expect(s.name, 'B');
    expect(d, lessThan(autoStopRadius));
    expect(nearestStop(const [], me), isNull);
  });

  test('distances lisibles', () {
    expect(distanceLabel(247), '250 m');
    expect(distanceLabel(1234), '1,2 km');
  });
}
