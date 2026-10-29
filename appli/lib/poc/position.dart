// Position estimée d'un bus : interpolation le long du tracé entre deux arrêts,
// au prorata du temps écoulé (même principe que le POC Python).
import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../data/realtime.dart';
import 'data.dart';

double _dist(LatLng a, LatLng b) {
  final lat = (a.latitude + b.latitude) / 2 * pi / 180;
  final dx = (b.longitude - a.longitude) * pi / 180 * cos(lat);
  final dy = (b.latitude - a.latitude) * pi / 180;
  return 6371000 * sqrt(dx * dx + dy * dy);
}

class _Geometry {
  _Geometry(Variant d) {
    final pts = d.shape;
    cum = [0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum.last + _dist(pts[i - 1], pts[i]));
    }
    // abscisse de chaque arrêt : point du tracé le plus proche, sans revenir en arrière
    var start = 0;
    for (final s in d.stops) {
      var best = start;
      for (var i = start; i < pts.length; i++) {
        if (_dist(pts[i], s.pos) < _dist(pts[best], s.pos)) best = i;
      }
      stopAt.add(pts.isEmpty ? 0 : cum[best]);
      start = best;
    }
  }

  late final List<double> cum;
  final List<double> stopAt = [];
}

final _cache = <Variant, _Geometry>{};

LatLng _pointAt(Variant d, double meters) {
  final g = _cache.putIfAbsent(d, () => _Geometry(d));
  final pts = d.shape;
  for (var i = 1; i < g.cum.length; i++) {
    if (g.cum[i] >= meters) {
      final seg = g.cum[i] - g.cum[i - 1];
      final f = seg == 0 ? 0.0 : (meters - g.cum[i - 1]) / seg;
      return LatLng(pts[i - 1].latitude + (pts[i].latitude - pts[i - 1].latitude) * f,
          pts[i - 1].longitude + (pts[i].longitude - pts[i - 1].longitude) * f);
    }
  }
  return pts.last;
}

class BusStatus {
  BusStatus({
    required this.position,
    required this.lastStop,
    required this.sinceSec,
    required this.nextStop,
    required this.nextInSec,
  });

  final LatLng position;
  final int lastStop, sinceSec, nextStop, nextInSec;
}

/// Heures de passage d'une course, corrigées du retard à chaque arrêt quand le temps réel est connu.
List<int> tripTimes(Variant d, int trip, TripRealtime? rt) =>
    [for (var i = 0; i < d.trips[trip].length; i++) d.trips[trip][i] + (rt?.delayAt(i) ?? 0)];

/// État d'une course en circulation à l'instant nowSec, ou null si elle n'a pas démarré ou est terminée.
/// Avec la requête « ligne », PRIM indique le prochain arrêt : le bus est placé avant lui.
BusStatus? busStatus(Variant d, int trip, int nowSec, TripRealtime? rt) {
  final times = tripTimes(d, trip, rt);
  final next = rt?.nextIndex;
  if (rt != null && rt.cancelled) return null;
  if (next != null) {
    if (next == 0) return null; // pas encore parti du terminus
  } else if (nowSec < times.first || nowSec >= times.last) {
    return null;
  }
  var i = 0;
  if (next != null) {
    i = next - 1;
  } else {
    while (i + 1 < times.length && times[i + 1] <= nowSec) {
      i++;
    }
  }
  final span = times[i + 1] - times[i];
  // bornée : les heures estimées peuvent contredire l'arrêt annoncé par PRIM
  final f = span <= 0 ? 1.0 : ((nowSec - times[i]) / span).clamp(0.0, 1.0);
  final LatLng pos;
  if (d.shape.length >= 2) {
    final g = _cache.putIfAbsent(d, () => _Geometry(d));
    pos = _pointAt(d, g.stopAt[i] + f * (g.stopAt[i + 1] - g.stopAt[i]));
  } else {
    final a = d.stops[i].pos, b = d.stops[i + 1].pos;
    pos = LatLng(a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f);
  }
  return BusStatus(
      position: pos,
      lastStop: i,
      sinceSec: max(0, nowSec - times[i]),
      nextStop: i + 1,
      nextInSec: max(0, times[i + 1] - nowSec));
}

String hhmm(int sec) {
  sec = sec % 86400;
  return '${(sec ~/ 3600).toString().padLeft(2, '0')}:${(sec ~/ 60 % 60).toString().padLeft(2, '0')}';
}

String duration(int sec) {
  if (sec < 60) return '$sec s';
  final m = sec ~/ 60;
  return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')}';
}

String delayLabel(int? delay) {
  if (delay == null) return 'théorique';
  final m = (delay / 60).round();
  if (m == 0) return "à l'heure";
  return m > 0 ? '+$m min' : '$m min';
}
