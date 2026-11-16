// Recherche de lieux et d'adresses : service d'autocomplétion de la Géoplateforme de l'IGN
// (public, gratuit, sans clé). Seul le texte tapé est envoyé, jamais la position de l'usager.
// Recherche limitée à l'Île-de-France (rectangle englobant).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const _completionUrl = 'https://data.geopf.fr/geocodage/completion/';

/// Rectangle englobant de l'Île-de-France (lon min, lat min, lon max, lat max).
const _idfBbox = '1.44,48.12,3.56,49.24';

/// Un lieu ou une adresse trouvé par le géocodeur.
class GeoPlace {
  const GeoPlace({required this.name, required this.detail, required this.pos, required this.isPoi});
  final String name;

  /// « complexe sportif couvert · 78180 Montigny-le-Bretonneux », « 75004 Paris ».
  final String detail;
  final LatLng pos;

  /// Lieu d'intérêt (gymnase, mairie, lycée…) plutôt qu'adresse ou rue.
  final bool isPoi;
}

/// Lit la réponse JSON du service d'autocomplétion.
List<GeoPlace> parseCompletion(Map<String, dynamic> json) {
  final out = <GeoPlace>[];
  for (final r in (json['results'] as List? ?? const [])) {
    final m = r as Map<String, dynamic>;
    final x = (m['x'] as num?)?.toDouble(), y = (m['y'] as num?)?.toDouble();
    if (x == null || y == null) continue;
    final poi = m['country'] == 'PositionOfInterest';
    final place = [m['zipcode'], m['city']].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    final names = (m['names'] as List?)?.whereType<String>().toList() ?? const <String>[];
    final full = (m['fulltext'] as String?) ?? '';
    // nom : celui du lieu, ou l'adresse sans la ville (déjà dans le détail)
    final name = poi && names.isNotEmpty ? names.first : full.split(',').first.trim();
    if (name.isEmpty) continue;
    final kind = poi ? (m['kind'] as String?) : null;
    out.add(
      GeoPlace(
        name: name,
        detail: [if (kind != null && kind.isNotEmpty) kind, if (place.isNotEmpty) place].join(' · '),
        pos: LatLng(y, x),
        isPoi: poi,
      ),
    );
  }
  return out;
}

class Geocoder {
  Geocoder({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Lieux et adresses d'Île-de-France correspondant à [text] (au plus [limit]). Liste vide en cas
  /// d'erreur réseau : l'appli continue avec les arrêts seuls.
  Future<List<GeoPlace>> search(String text, {int limit = 6}) async {
    try {
      final uri = Uri.parse(_completionUrl).replace(
        queryParameters: {
          'text': text,
          'type': 'PositionOfInterest,StreetAddress',
          'maximumResponses': '$limit',
          'bbox': _idfBbox,
        },
      );
      final r = await _client.get(uri, headers: {'User-Agent': 'AppliTransport'}).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return const [];
      return parseCompletion(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return const [];
    }
  }
}
