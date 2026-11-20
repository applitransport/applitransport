// Chemins à pied et adresse la plus proche, par les services de la Géoplateforme de l'IGN (itinéraire
// piéton sur la BD TOPO, géocodage inverse). Publics, gratuits, sans clé. Utilisés seulement quand le
// calculateur PRIM ne trouve pas de chemin (tronçon « à vol d'oiseau ») : un lieu au milieu d'un grand
// terrain (lycée, parc…) ou une position loin d'une rue. Reçoivent les deux points du tronçon.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const _routeUrl = 'https://data.geopf.fr/navigation/itineraire';
const _reverseUrl = 'https://data.geopf.fr/geocodage/reverse';

/// Chemin à pied : tracé, longueur (m) et durée (s) estimées par l'IGN.
class WalkPath {
  const WalkPath(this.shape, this.meters, this.seconds);
  final List<LatLng> shape;
  final double meters;
  final int seconds;
}

/// Réponse du service d'itinéraire de l'IGN (géométrie GeoJSON) ; null si inexploitable.
WalkPath? parseWalkPath(Map<String, dynamic> j) {
  final coords = (j['geometry'] as Map?)?['coordinates'] as List?;
  if (coords == null || coords.length < 2) return null;
  return WalkPath(
    [for (final c in coords) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())],
    (j['distance'] as num?)?.toDouble() ?? 0,
    (j['duration'] as num?)?.round() ?? 0,
  );
}

/// Réponse du géocodage inverse : position de la première adresse, ou null.
LatLng? parseReverse(Map<String, dynamic> j) {
  final f = (j['features'] as List?)?.firstOrNull as Map?;
  final c = (f?['geometry'] as Map?)?['coordinates'] as List?;
  if (c == null || c.length < 2) return null;
  return LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
}

class WalkRouter {
  WalkRouter({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<Map<String, dynamic>?> _get(String url, Map<String, String> query) async {
    try {
      final r = await _client
          .get(Uri.parse(url).replace(queryParameters: query), headers: {'User-Agent': 'AppliTransport'})
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null; // pas de réseau ou service indisponible : le tronçon reste « à vol d'oiseau »
    }
  }

  /// Chemin à pied de [a] à [b] par les rues et chemins, ou null.
  Future<WalkPath?> path(LatLng a, LatLng b) async {
    final j = await _get(_routeUrl, {
      'resource': 'bdtopo-valhalla',
      'profile': 'pedestrian',
      'optimization': 'fastest',
      'start': '${a.longitude},${a.latitude}',
      'end': '${b.longitude},${b.latitude}',
      'geometryFormat': 'geojson',
      'getSteps': 'false',
    });
    return j == null ? null : parseWalkPath(j);
  }

  /// Adresse la plus proche de [p] (au plus 300 m), ou null.
  Future<LatLng?> nearestAddress(LatLng p) async {
    final j = await _get(_reverseUrl, {
      'lon': '${p.longitude}',
      'lat': '${p.latitude}',
      'index': 'address',
      'limit': '1',
      'searchgeom': jsonEncode({
        'type': 'Circle',
        'coordinates': [p.longitude, p.latitude],
        'radius': 300,
      }),
    });
    return j == null ? null : parseReverse(j);
  }
}
