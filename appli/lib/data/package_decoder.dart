// Décodage d'un paquet de ligne de l'usine (format 1, voir usine/export.py) en horaires d'un jour :
// sens → variantes (parcours types) → courses, le modèle utilisé par les écrans.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart' show Color;
import 'package:latlong2/latlong.dart';

import '../poc/data.dart';

const supportedFormat = 1;

/// Décode une polyligne « Google » (précision 1e-5), comme l'encode l'usine.
List<LatLng> decodePolyline(String s) {
  final out = <LatLng>[];
  var i = 0, lat = 0, lon = 0;
  while (i < s.length) {
    final vals = <int>[];
    for (var k = 0; k < 2; k++) {
      var shift = 0, result = 0, b = 0;
      do {
        b = s.codeUnitAt(i++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      vals.add((result & 1) != 0 ? ~(result >> 1) : result >> 1);
    }
    lat += vals[0];
    lon += vals[1];
    out.add(LatLng(lat / 1e5, lon / 1e5));
  }
  return out;
}

/// Lit un paquet publié (.json.gz). Si l'hébergeur l'a déjà décompressé en route, on lit le JSON tel quel.
Map<String, dynamic> readPackage(List<int> bytes) {
  final gz = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  return jsonDecode(utf8.decode(gz ? gzip.decode(bytes) : bytes)) as Map<String, dynamic>;
}

String _yyyymmdd(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

/// Le service (jeu de jours de circulation) roule-t-il ce jour-là ?
bool serviceActive(Map<String, dynamic> pkg, String serviceId, DateTime day) {
  final key = _yyyymmdd(day);
  for (final e in (pkg['calendar_dates'][serviceId] ?? const []) as List) {
    if (e[0] == key) return e[1] == 1; // 1 = ajouté ce jour, 2 = supprimé ce jour
  }
  final c = pkg['calendar'][serviceId];
  if (c == null) return false;
  final String bits = c[0], start = c[1], end = c[2];
  return start.compareTo(key) <= 0 && key.compareTo(end) <= 0 && bits[day.weekday - 1] == '1';
}

/// Dernier jour couvert par les horaires du paquet (pour avertir quand ils deviennent périmés).
DateTime? lastServiceDay(Map<String, dynamic> pkg) {
  String? last;
  for (final c in (pkg['calendar'] as Map).values) {
    if (last == null || (c[2] as String).compareTo(last) > 0) last = c[2];
  }
  for (final dates in (pkg['calendar_dates'] as Map).values) {
    for (final e in dates as List) {
      if (e[1] == 1 && (last == null || (e[0] as String).compareTo(last) > 0)) last = e[0];
    }
  }
  return last == null ? null : DateTime.parse(last);
}

/// Horaires d'une ligne pour un jour de service : une variante par parcours type qui roule ce
/// jour-là, la plus fréquente en premier ; les sens sans course sont omis.
DemoLine timetableFor(Map<String, dynamic> pkg, DateTime day) {
  if (pkg['format'] != supportedFormat) {
    throw FormatException('format de paquet ${pkg['format']} non géré (attendu $supportedFormat)');
  }
  final stops = (pkg['stops'] as Map<String, dynamic>);
  final shapes = <String, List<LatLng>>{};
  final patterns = pkg['patterns'] as List;

  // courses du jour, regroupées par parcours type
  final byPattern = <int, List<List<dynamic>>>{};
  for (final t in pkg['trips'] as List) {
    if (serviceActive(pkg, t[2], day)) byPattern.putIfAbsent(t[1] as int, () => []).add(t as List);
  }

  final directions = <Direction>[];
  for (final dir in const [0, 1]) {
    final indexes = byPattern.keys.where((p) => patterns[p]['direction_id'] == dir).toList()
      ..sort((a, b) => byPattern[b]!.length.compareTo(byPattern[a]!.length));
    if (indexes.isEmpty) continue;
    final variants = <Variant>[];
    for (final p in indexes) {
      final pattern = patterns[p];
      final trips = byPattern[p]!..sort((a, b) => (a[3] as int).compareTo(b[3] as int));
      final shapeId = pattern['shape_id'] as String?;
      variants.add(Variant(
        pattern['headsign'] ?? '',
        [
          for (final id in pattern['stops'])
            Stop(stops[id][0], LatLng((stops[id][1] as num).toDouble(), (stops[id][2] as num).toDouble()),
                stops[id][3] ?? id, id),
        ],
        shapeId == null ? const [] : shapes.putIfAbsent(shapeId, () => decodePolyline(pkg['shapes'][shapeId])),
        [
          for (final t in trips)
            () {
              // départ au 1er arrêt + écarts successifs -> départ à chaque arrêt
              final deps = <int>[t[3] as int];
              for (final d in t[4] as List) {
                deps.add(deps.last + (d as int));
              }
              return deps;
            }(),
        ],
        [for (final t in trips) t[0] as String],
      ));
    }
    directions.add(Direction(dir, variants.first.headsign, variants));
  }

  final line = pkg['line'];
  return DemoLine(
    pkg['route_id'].split(':').last,
    line['short_name'],
    line['type'],
    readableLineColor(hexColor(line['color'])),
    readableTextColor(hexColor(line['color']), hexColor(line['text_color'], const Color(0xFFFFFFFF))),
    directions,
  );
}
