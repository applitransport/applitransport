import 'package:applitransport/screens/lines_map_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('shapeFrom repart du point du tracé le plus proche de l\'arrêt', () {
    const shape = [LatLng(48.80, 2.0), LatLng(48.81, 2.0), LatLng(48.82, 2.0), LatLng(48.83, 2.0)];
    final r = shapeFrom(shape, const LatLng(48.8205, 2.0001));
    expect(r.first, const LatLng(48.8205, 2.0001));
    expect(r.sublist(1), [shape[2], shape[3]]);
  });
}
