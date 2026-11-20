// Recherche de lieux et d'adresses : service d'autocomplétion de la Géoplateforme de l'IGN (lieux
// publics, adresses) et API Recherche d'entreprises de l'État (bureaux, sociétés : base Sirene).
// Publics, gratuits, sans clé. Seul le texte tapé est envoyé, jamais la position de l'usager (les chemins
// à pied de l'IGN, eux, reçoivent les deux points d'un tronçon : voir walk_router.dart).
// Recherche limitée à l'Île-de-France.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const _completionUrl = 'https://data.geopf.fr/geocodage/completion/';
const _companiesUrl = 'https://recherche-entreprises.api.gouv.fr/search';

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

  /// Entreprise (base Sirene) : coordonnées de son adresse postale.
  bool get isCompany => _company;
  final bool _company = false;
}

class _Company extends GeoPlace {
  const _Company({required super.name, required super.detail, required super.pos}) : super(isPoi: false);
  @override
  bool get isCompany => true;
}

/// « 53 RUE DE CHATEAUDUN 75009 PARIS » → « 53 Rue De Chateaudun 75009 Paris » (plus lisible).
String _title(String s) => s
    .toLowerCase()
    .split(' ')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ')
    .replaceAllMapped(RegExp(r"\b(De|Du|Des|La|Le|Les|Et|D'|L')\b"), (m) => m[0]!.toLowerCase());

/// Lit la réponse de l'API Recherche d'entreprises : établissements ouverts d'Île-de-France qui ont
/// des coordonnées (au plus [perCompany] par entreprise, le siège d'abord).
List<GeoPlace> parseCompanies(Map<String, dynamic> json, {int perCompany = 2}) {
  final out = <GeoPlace>[];
  for (final r in (json['results'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    final name = (r['nom_complet'] as String?)?.trim();
    if (name == null || name.isEmpty) continue;
    final sites = [
      for (final e in (r['matching_etablissements'] as List? ?? const []).cast<Map<String, dynamic>>())
        if (e['etat_administratif'] == 'A' && e['region'] == '11') e,
    ]..sort((a, b) => (b['est_siege'] == true ? 1 : 0) - (a['est_siege'] == true ? 1 : 0));
    var n = 0;
    for (final e in sites) {
      final lat = double.tryParse('${e['latitude']}'), lon = double.tryParse('${e['longitude']}');
      if (lat == null || lon == null) continue;
      final enseigne = (e['liste_enseignes'] as List?)?.whereType<String>().firstOrNull;
      out.add(
        _Company(
          name: _title(enseigne ?? name),
          detail: ['Entreprise', _title('${e['adresse'] ?? ''}')].where((x) => x.isNotEmpty).join(' · '),
          pos: LatLng(lat, lon),
        ),
      );
      if (++n >= perCompany) break;
    }
  }
  return out;
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

  /// Entreprises d'Île-de-France correspondant à [text] (base Sirene). Liste vide en cas d'erreur.
  Future<List<GeoPlace>> searchCompanies(String text, {int limit = 3}) async {
    try {
      final uri = Uri.parse(_companiesUrl).replace(
        queryParameters: {
          'q': text,
          'departement': '75,77,78,91,92,93,94,95',
          'etat_administratif': 'A',
          'per_page': '$limit',
        },
      );
      final r = await _client.get(uri, headers: {'User-Agent': 'AppliTransport'}).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return const [];
      return parseCompanies(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return const [];
    }
  }
}
