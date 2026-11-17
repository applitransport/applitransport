// Arrêts à proximité de l'usager : calculés sur le téléphone à partir du catalogue (coordonnées des
// zones d'arrêt) et des arrêts de la ligne, sans requête ni envoi.
import '../data/geo.dart';
import 'package:latlong2/latlong.dart';

import '../data/location.dart';
import '../data/track.dart' show distanceMeters;
import 'data.dart';

/// Rayon de la liste « Arrêts près de moi » (m).
const nearbyRadius = 800.0;

/// Distance sous laquelle l'arrêt le plus proche d'une ligne est choisi d'office (m).
const autoStopRadius = 500.0;

/// Zones d'arrêt à moins de [radius] de [me], les plus proches d'abord (au plus [limit]).
List<(StopArea, double)> nearbyAreas(
  Iterable<StopArea> areas,
  LatLng me, {
  double radius = nearbyRadius,
  int limit = 10,
}) {
  final out = <(StopArea, double)>[
    for (final a in areas)
      if (a.lines.isNotEmpty)
        if (distanceMeters(me, a.pos) case final d when d <= radius) (a, d),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return out.take(limit).toList();
}

/// Arrêt de [stops] le plus proche de [me] et sa distance, ou null s'il n'y en a pas.
(Stop, double)? nearestStop(List<Stop> stops, LatLng me) {
  (Stop, double)? best;
  for (final s in stops) {
    final d = distanceMeters(me, s.pos);
    if (best == null || d < best.$2) best = (s, d);
  }
  return best;
}

/// Position actuelle du téléphone. [ask] : demander la permission si besoin (appui de l'usager) ;
/// sinon, seulement si elle est déjà accordée. Null si indisponible.
Future<LatLng?> currentPosition({bool ask = false}) async {
  try {
    if (ask) {
      await ensureLocationPermission();
    } else {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return null;
      if (!await Geolocator.isLocationServiceEnabled()) return null;
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).timeout(const Duration(seconds: 15));
    return LatLng(p.latitude, p.longitude);
  } catch (_) {
    return null;
  }
}

/// « 250 m », « 1,2 km ».
String distanceLabel(double m) =>
    m < 1000 ? '${(m / 10).round() * 10} m' : '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
