// Géométrie d'un parcours : longueur cumulée du tracé, position des arrêts le long du tracé,
// point à une distance donnée et projection d'un point GPS sur le tracé (recalage).
import 'dart:math';

import 'package:latlong2/latlong.dart';

const _earth = 6371000.0;

/// Distance en mètres (approximation plane, précise à l'échelle d'une ligne).
double distanceMeters(LatLng a, LatLng b) {
  final lat = (a.latitude + b.latitude) / 2 * pi / 180;
  final dx = (b.longitude - a.longitude) * pi / 180 * cos(lat);
  final dy = (b.latitude - a.latitude) * pi / 180;
  return _earth * sqrt(dx * dx + dy * dy);
}

/// Point GPS ramené sur le tracé.
class TrackProjection {
  const TrackProjection({required this.along, required this.offset, required this.point});

  /// Distance parcourue depuis le début du tracé (m).
  final double along;

  /// Écart entre le point GPS et le tracé (m).
  final double offset;

  /// Point recalé sur le tracé.
  final LatLng point;
}

class TrackGeometry {
  /// [shape] : tracé du parcours ; s'il manque, la ligne droite d'arrêt en arrêt.
  TrackGeometry(List<LatLng> shape, List<LatLng> stops) : points = shape.length >= 2 ? shape : stops {
    cum = [0];
    for (var i = 1; i < points.length; i++) {
      cum.add(cum.last + distanceMeters(points[i - 1], points[i]));
    }
    // abscisse de chaque arrêt : point du tracé le plus proche, sans revenir en arrière
    var start = 0;
    for (final s in stops) {
      var best = start;
      for (var i = start; i < points.length; i++) {
        if (distanceMeters(points[i], s) < distanceMeters(points[best], s)) best = i;
      }
      stopAt.add(points.isEmpty ? 0 : cum[best]);
      start = best;
    }
  }

  final List<LatLng> points;
  late final List<double> cum;

  /// Distance de chaque arrêt depuis le début du tracé (m), croissante.
  final List<double> stopAt = [];

  double get length => cum.isEmpty ? 0 : cum.last;

  /// Point du tracé à [meters] du début.
  LatLng pointAt(double meters) {
    for (var i = 1; i < cum.length; i++) {
      if (cum[i] >= meters) {
        final seg = cum[i] - cum[i - 1];
        final f = seg == 0 ? 0.0 : (meters - cum[i - 1]) / seg;
        return _lerp(points[i - 1], points[i], f);
      }
    }
    return points.last;
  }

  /// Dernier arrêt atteint à [along] (au plus l'avant-dernier : il y a toujours un arrêt suivant).
  int stopBefore(double along) {
    var i = 0;
    while (i + 2 < stopAt.length && stopAt[i + 1] <= along) {
      i++;
    }
    return i;
  }

  /// Projection de [p] sur le tracé, en ne regardant que la portion [from, to] (m) quand elle est
  /// donnée : une ligne qui repasse au même endroit (boucle, aller-retour) n'est pas confondue.
  TrackProjection? project(LatLng p, {double from = double.negativeInfinity, double to = double.infinity}) {
    if (points.length < 2) return null;
    // repère local en mètres centré sur p
    final k = pi / 180 * _earth, kx = k * cos(p.latitude * pi / 180);
    double x(LatLng q) => (q.longitude - p.longitude) * kx;
    double y(LatLng q) => (q.latitude - p.latitude) * k;
    TrackProjection? best;
    for (var i = 1; i < points.length; i++) {
      if (cum[i] < from || cum[i - 1] > to) continue;
      final ax = x(points[i - 1]), ay = y(points[i - 1]);
      final dx = x(points[i]) - ax, dy = y(points[i]) - ay;
      final len2 = dx * dx + dy * dy, seg = cum[i] - cum[i - 1];
      // partie du segment comprise dans [from, to]
      final lo = seg == 0 ? 0.0 : ((from - cum[i - 1]) / seg).clamp(0.0, 1.0);
      final hi = seg == 0 ? 1.0 : ((to - cum[i - 1]) / seg).clamp(0.0, 1.0);
      final t = len2 == 0 ? lo : (-(ax * dx + ay * dy) / len2).clamp(lo, hi);
      final cx = ax + t * dx, cy = ay + t * dy;
      final offset = sqrt(cx * cx + cy * cy);
      if (best == null || offset < best.offset) {
        best = TrackProjection(
          along: cum[i - 1] + t * (cum[i] - cum[i - 1]),
          offset: offset,
          point: _lerp(points[i - 1], points[i], t),
        );
      }
    }
    return best;
  }
}

LatLng _lerp(LatLng a, LatLng b, double f) =>
    LatLng(a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f);
