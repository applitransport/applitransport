// Modèles des lignes et horaires utilisés par les écrans (remplis depuis le catalogue et les paquets
// de l'usine, voir data/package_decoder.dart).
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

Color hexColor(String? hex, [Color fallback = Colors.blueGrey]) {
  if (hex == null || hex.length != 6) return fallback;
  return Color(int.parse('FF$hex', radix: 16));
}

/// Couleur de ligne lisible sur la carte : les couleurs grises fournies par IDFM (ex. TER #AAAAAA)
/// se confondent avec le fond de carte, on les remplace par de l'indigo.
const readableFallback = Colors.indigo;

bool isGreyish(Color c) => HSLColor.fromColor(c).saturation < 0.15;

Color readableLineColor(Color c) => isGreyish(c) ? readableFallback : c;

/// Couleur du texte sur une pastille dont la couleur a pu être remplacée.
Color readableTextColor(Color line, Color text) => isGreyish(line) ? Colors.white : text;

/// Zones d'arrêt correspondant à une saisie : d'abord celles dont le nom commence par le texte,
/// puis les plus desservies (une gare passe avant un arrêt de bus homonyme).
List<StopArea> searchStopAreas(Iterable<StopArea> areas, String query, {int limit = 50}) {
  final q = query.toLowerCase().trim();
  if (q.isEmpty) return areas.take(limit).toList();
  // chaque mot doit figurer dans le nom, un nom de quai ou la commune (« hameau montigny »)
  final words = q.split(RegExp(r'\s+'));
  bool matches(StopArea a) {
    final names = [a.name, ...a.aliases].map((n) => n.toLowerCase()).toList();
    final town = a.town.toLowerCase();
    if (names.any((n) => n.contains(q))) return true;
    return words.every((w) => town.contains(w) || names.any((n) => n.contains(w)));
  }

  final hits = areas.where(matches).toList();
  int rank(StopArea a) => a.name.toLowerCase().startsWith(q) ? 0 : (a.name.toLowerCase().contains(q) ? 1 : 2);
  hits.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : b.lines.length.compareTo(a.lines.length);
  });
  return hits.take(limit).toList();
}

/// IDFM:C01527 -> C01527
String lineCode(String routeId) => routeId.split(':').last;

const typeLabels = {
  'bus': 'Bus',
  'tram': 'Tram',
  'metro': 'Métro',
  'train': 'RER / Train',
  'funiculaire': 'Funiculaire',
  'telepherique': 'Téléphérique',
};

class CatalogLine {
  /// Ligne du catalogue publié par l'usine (catalog.json.gz).
  CatalogLine.fromCatalog(Map<String, dynamic> j)
      : id = lineCode(j['route_id']),
        name = j['short_name'],
        longName = j['long_name'] ?? '',
        type = j['type'],
        network = j['network'],
        color = readableLineColor(hexColor(j['color'])),
        textColor = readableTextColor(hexColor(j['color']), hexColor(j['text_color'], Colors.white)),
        size = j['size'];


  final String id, name, longName, type, network;
  final Color color, textColor;
  final int size;

  String get typeLabel => typeLabels[type] ?? type;
}

class StopArea {
  StopArea.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        town = j['town'] ?? '',
        aliases = List<String>.from(j['aliases'] ?? const []),
        lines = [for (final r in j['lines']) lineCode(r)];

  final String id, name;

  /// Commune (référentiel des arrêts IDFM) : distingue les homonymes (« Le Hameau »).
  final String town;
  final List<String> aliases;
  final List<String> lines;

  /// Nom affiché : le nom de zone, complété par un nom de quai quand il est plus parlant.
  String get label => aliases.length == 1 && aliases.first.length > name.length ? aliases.first : name;
}

class Stop {
  const Stop(this.name, this.pos, [this.area = '', this.id = '']);
  final String name;
  final LatLng pos;

  /// Zone d'arrêt (regroupe les quais d'un même lieu, ex. la gare de Saint-Quentin).
  final String area;

  /// Identifiant GTFS du quai (IDFM:20612, IDFM:monomodalStopPlace:461504…), pour le temps réel.
  final String id;
}

/// Un parcours type : suite d'arrêts, tracé et courses (ex. 5104 vers Saint-Exupéry).
class Variant {
  Variant(this.headsign, this.stops, this.shape, this.trips, [this.tripIds = const []]);


  final String headsign;

  /// Identifiant GTFS de chaque course (rattachement au temps réel) ; vide pour les données de démo.
  final List<String> tripIds;
  final List<Stop> stops;
  final List<LatLng> shape;

  /// Pour chaque course, l'heure de départ (s depuis minuit) à chaque arrêt.
  final List<List<int>> trips;

  int indexOf(String stopName) => stops.indexWhere((s) => s.name == stopName);
  int indexOfArea(String area, [int start = 0]) => stops.indexWhere((s) => s.area == area, start);
}

/// Un sens de la ligne, avec toutes ses variantes (la plus fréquente en premier).
class Direction {
  Direction(this.id, this.label, this.variants) {
    _mergeStops();
  }


  // arrêts de toutes les variantes, dans l'ordre du parcours : chaque arrêt absent de la
  // variante principale est inséré après l'arrêt qui le précède dans sa propre variante
  void _mergeStops() {
    for (final v in variants) {
      var pos = -1;
      for (final s in v.stops) {
        final k = stops.indexWhere((x) => x.name == s.name);
        if (k >= 0) {
          pos = k;
        } else {
          stops.insert(++pos, s);
        }
      }
    }
  }

  final int id;
  final String label;
  final List<Variant> variants;
  final List<Stop> stops = [];
}

class DemoLine {
  DemoLine(this.id, this.name, this.type, this.color, this.textColor, this.directions);


  final String id, name, type;
  final Color color, textColor;
  final List<Direction> directions;
}
