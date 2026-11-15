// Position estimée d'un bus : interpolation le long du tracé entre deux arrêts,
// au prorata du temps écoulé (même principe que le POC Python).
import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../data/realtime.dart';
import '../data/track.dart';
import 'data.dart';

/// Géométrie d'un parcours, calculée une fois par variante.
TrackGeometry trackOf(Variant d) =>
    _cache.putIfAbsent(d, () => TrackGeometry(d.shape, [for (final s in d.stops) s.pos]));

final _cache = <Variant, TrackGeometry>{};

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
List<int> tripTimes(Variant d, int trip, TripRealtime? rt) => [
  for (var i = 0; i < d.trips[trip].length; i++) d.trips[trip][i] + (rt?.delayAt(i) ?? 0),
];

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
  final g = trackOf(d);
  final pos = g.pointAt(g.stopAt[i] + f * (g.stopAt[i + 1] - g.stopAt[i]));
  return BusStatus(
    position: pos,
    lastStop: i,
    sinceSec: max(0, nowSec - times[i]),
    nextStop: i + 1,
    nextInSec: max(0, times[i + 1] - nowSec),
  );
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
