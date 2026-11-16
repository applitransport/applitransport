import 'package:applitransport/screens/walk_nav_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('bearing : nord, est', () {
    expect(bearing(const LatLng(48.8, 2.0), const LatLng(48.9, 2.0)), closeTo(0, 0.5));
    expect(bearing(const LatLng(48.8, 2.0), const LatLng(48.8, 2.1)), closeTo(90, 0.5));
  });

  test('remainingPath repart du point le plus proche', () {
    const path = [LatLng(48.8, 2.0), LatLng(48.801, 2.0), LatLng(48.802, 2.0)];
    final r = remainingPath(path, const LatLng(48.8012, 2.0));
    expect(r.first, const LatLng(48.8012, 2.0));
    expect(r.last, path.last);
    expect(pathLength(r), closeTo(89, 3));
  });

  test('chevrons tous les 25 m dans le sens du chemin', () {
    const path = [LatLng(48.8, 2.0), LatLng(48.801, 2.0)]; // ≈ 111 m vers le nord
    final c = chevrons(path);
    expect(c.length, 4);
    expect(c.every((x) => x.$2 < 1 || x.$2 > 359), isTrue);
  });
}
