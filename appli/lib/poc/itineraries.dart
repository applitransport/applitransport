// Itinéraires du calculateur IDFM (API Navitia « journeys » de PRIM), lus dans le modèle des écrans.
// Heures en secondes depuis minuit du jour de la recherche (peuvent dépasser 24 h).
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../data/traffic.dart';
import 'data.dart';

class Place {
  Place.fromNavitia(Map<String, dynamic> p)
      : name = p['name'] ?? '',
        pos = _coord(p[p['embedded_type']]?['coord']),
        area = ((p[p['embedded_type']]?['stop_area']?['id'] ?? (p['embedded_type'] == 'stop_area' ? p['id'] : '')) as String)
            .replaceFirst('stop_area:', '');
  final String name, area;
  final LatLng pos;

  static LatLng _coord(dynamic c) =>
      c == null ? const LatLng(0, 0) : LatLng(double.parse('${c['lat']}'), double.parse('${c['lon']}'));
}

int _sec(String? navitia, DateTime day) {
  final t = navitiaTime(navitia);
  return t == null ? 0 : t.difference(DateTime(day.year, day.month, day.day)).inSeconds;
}

class Section {
  Section.fromNavitia(Map<String, dynamic> s, DateTime day)
      : type = const {
              'public_transport': 'pt',
              'street_network': 'walk',
              'crow_fly': 'walk',
              'transfer': 'transfer',
              'waiting': 'wait',
            }[s['type']] ??
            s['type'],
        duration = s['duration'] ?? 0,
        dep = _sec(s['departure_date_time'], day),
        arr = _sec(s['arrival_date_time'], day),
        baseDep = _sec(s['base_departure_date_time'] ?? s['departure_date_time'], day),
        from = s['from'] == null ? null : Place.fromNavitia(s['from']),
        to = s['to'] == null ? null : Place.fromNavitia(s['to']),
        shape = [
          for (final c in (s['geojson']?['coordinates'] ?? const []) as List)
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())
        ],
        lineCode = s['display_informations']?['code'],
        lineId = [
          for (final l in (s['links'] ?? const []) as List)
            if (l['type'] == 'line') (l['id'] as String).split(':').last
        ].firstOrNull,
        mode = s['display_informations']?['commercial_mode'],
        // couleur absente ou grise (ex. TER #AAAAAA) : indigo, lisible sur la carte
        color = readableLineColor(hexColor(s['display_informations']?['color'], readableFallback)),
        textColor = readableTextColor(hexColor(s['display_informations']?['color'], readableFallback),
            hexColor(s['display_informations']?['text_color'], Colors.white)),
        direction = s['display_informations']?['direction'],
        stops = [for (final d in (s['stop_date_times'] ?? const []) as List) d['stop_point']['name'] as String],
        disruptions = [
          for (final l in (s['display_informations']?['links'] ?? const []) as List)
            if (l['type'] == 'disruption') l['id'] as String
        ];

  /// « pt » (transport), « walk », « transfer » (marche de correspondance) ou « wait ».
  final String type;
  final int duration, dep, arr;

  /// Départ prévu (horaire théorique) : sert à retrouver la course dans le temps réel.
  final int baseDep;
  final Place? from, to;
  final List<LatLng> shape;
  final String? lineCode, lineId, mode, direction;
  final Color color, textColor;
  final List<String> stops, disruptions;

  bool get isTransit => type == 'pt';
}

class Journey {
  Journey.fromNavitia(Map<String, dynamic> j, DateTime day)
      : dep = _sec(j['departure_date_time'], day),
        arr = _sec(j['arrival_date_time'], day),
        transfers = j['nb_transfers'] ?? 0,
        sections = [
          for (final s in (j['sections'] ?? const []) as List)
            // liaisons « à vol d'oiseau » de 0 min (arrêt = point d'arrivée) : sans intérêt
            if (!(s['type'] == 'crow_fly' && (s['duration'] ?? 0) == 0)) Section.fromNavitia(s, day)
        ];
  final int dep, arr, transfers;
  final List<Section> sections;

  Iterable<Section> get transit => sections.where((s) => s.isTransit);
}

class ItinerarySearch {
  ItinerarySearch.fromNavitia(Map<String, dynamic> data, this.day)
      : journeys = [for (final j in (data['journeys'] ?? const []) as List) Journey.fromNavitia(j, day)]
          ..sort((a, b) => a.dep.compareTo(b.dep)),
        disruptions = {
          for (final d in (data['disruptions'] ?? const []) as List)
            for (final x in parseLineReports({
              'disruptions': [d]
            }))
              d['id'] as String: x
        };

  final DateTime day;
  final List<Journey> journeys;
  final Map<String, Disruption> disruptions;
}
