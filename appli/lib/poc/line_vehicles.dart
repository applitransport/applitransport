// Véhicules d'un sens de ligne à afficher : position PRIM ou théorique (rouges sur la carte), position
// vue par un voyageur (verts), celle de l'usager à bord. Partagé par le suivi de ligne et l'état de
// la ligne.
import 'package:latlong2/latlong.dart';

import '../data/community.dart';
import '../data/ride_session.dart';
import '../data/traffic.dart';
import '../widgets/line_map.dart';
import 'app_state.dart';
import 'data.dart';
import 'position.dart';

/// Âge maximal d'une position de voyageur pour remplacer l'estimation (s).
const crowdMaxAgeSec = 90;

/// Course (variante, course) du sens [d] portant le numéro [course] ; à numéro égal (même course la
/// veille et le jour même), celle dont l'horaire est le plus proche de [nowSec] : 0 si elle est
/// censée circuler, sinon l'écart à son départ ou à son arrivée.
(int, int)? tripOfCourse(Direction d, String course, int nowSec) {
  (int, int)? found;
  var best = 1 << 30;
  for (var v = 0; v < d.variants.length; v++) {
    for (var t = 0; t < d.variants[v].trips.length; t++) {
      if (courseId(d.variants[v], t) != course) continue;
      final times = d.variants[v].trips[t];
      final gap = nowSec < times.first
          ? times.first - nowSec
          : nowSec > times.last
          ? nowSec - times.last
          : 0;
      if (gap < best) {
        best = gap;
        found = (v, t);
      }
    }
  }
  return found;
}

/// Véhicules du sens [d] vus récemment par des voyageurs : (variante, course, véhicule).
List<(int, int, CrowdVehicle)> crowdSeen(AppState app, DemoLine l, Direction d) {
  final cl = app.communityLines[l.id];
  if (cl == null || !app.communityShow) return const [];
  final now = DateTime.now(), sec = app.nowSec();
  return [
    for (final c in cl.vehicles)
      if (c.direction == d.id && cl.ageOf(c, now) <= crowdMaxAgeSec)
        if (tripOfCourse(d, c.course, sec) case (final v, final t)) (v, t, c),
  ];
}

/// Estimations « vu par un voyageur » des courses du sens [d], par identifiant « variante/course » :
/// position sur la ligne et retard déduit de l'horaire.
Map<String, CrowdEstimate> crowdEstimates(AppState app, DemoLine l, Direction d) {
  final cl = app.communityLines[l.id];
  if (cl == null) return const {};
  final now = DateTime.now(), sec = app.nowSec();
  return {
    for (final (v, t, c) in crowdSeen(app, l, d))
      '$v/$t': ?crowdEstimate(d.variants[v], t, c, ageSec: cl.ageOf(c, now), nowSec: sec),
  };
}

/// Véhicules à dessiner pour le sens [d] (index [dirIndex]). [show] : afficher ceux que PRIM ou
/// l'horaire placent (après Actualiser). Les positions vues par un voyageur, puis celle
/// de l'usager à bord ([ride]), remplacent l'estimation de leur course.
List<MapBus> lineVehicles(
  AppState app,
  DemoLine l,
  Direction d,
  int dirIndex, {
  required bool show,
  String? selected,
  RideSession? ride,
  Set<String> alerts = const {},
}) {
  final now = app.nowSec();
  final buses = <MapBus>[];
  if (show) {
    for (var v = 0; v < d.variants.length; v++) {
      for (var t = 0; t < d.variants[v].trips.length; t++) {
        final r = app.rt(l.id, d.id, v, t);
        final s = busStatus(d.variants[v], t, now, r);
        if (s != null) {
          buses.add(
            MapBus(
              id: '$v/$t',
              position: s.position,
              selected: '$v/$t' == selected,
              realtime: r != null,
              alert: alerts.contains('$v/$t'),
            ),
          );
        }
      }
    }
  }
  void replace(String id, LatLng at) => buses
    ..removeWhere((b) => b.id == id)
    ..add(
      MapBus(id: id, position: at, selected: id == selected, realtime: true, crowd: true, alert: alerts.contains(id)),
    );
  for (final (v, t, c) in crowdSeen(app, l, d)) {
    replace('$v/$t', LatLng(c.lat, c.lon));
  }
  final mine = ride != null && ride.lineId == l.id && ride.direction == dirIndex ? ride.freshPosition() : null;
  if (mine != null) replace('${ride!.variant}/${ride.trip}', mine);
  return buses;
}

/// Où porte un signalement dans le sens [d] : course (variante, course) et arrêt (index dans la
/// variante de la course, ou dans la première variante qui le dessert). Null s'il concerne l'autre
/// sens.
typedef ReportPlace = ({int? variant, int? trip, int? stopIndex, Stop? stop});

ReportPlace? reportPlace(Direction d, CrowdReport r, int nowSec) {
  int? variant, trip;
  if (r.course != null) {
    final found = tripOfCourse(d, r.course!, nowSec);
    if (found == null) return null;
    (variant, trip) = found;
  }
  int? stopIndex;
  Stop? stop;
  if (r.stop != null) {
    for (var v = 0; v < d.variants.length && stop == null; v++) {
      if (variant != null && v != variant) continue;
      for (var i = 0; i < d.variants[v].stops.length; i++) {
        if (stopId(d.variants[v], i) == r.stop) {
          stopIndex = i;
          stop = d.variants[v].stops[i];
          break;
        }
      }
    }
    if (stop == null && trip == null) return null;
  }
  return (variant: variant, trip: trip, stopIndex: stopIndex, stop: stop);
}

/// Signalement placé dans le sens affiché et évalué (confirmé, non confirmé, contredit).
typedef PlacedReport = ({CrowdReport report, ReportPlace place, ReportAssessment assessment});

/// Signalements en cours de la ligne [l] qui concernent le sens [d], les plus récents en premier.
List<PlacedReport> placedReports(AppState app, DemoLine l, Direction d) {
  final cl = app.communityLines[l.id];
  if (cl == null || !app.communityShow) return const [];
  final now = app.nowSec(), crowd = crowdEstimates(app, l, d);
  final traffic = (app.traffic(l.id) ?? const <Disruption>[]).any(
    (x) => x.kind == DisruptionKind.incident && x.activeAt(app.now()),
  );
  final out = <PlacedReport>[];
  for (final r in cl.reports) {
    final place = reportPlace(d, r, now);
    if (place == null) continue;
    final (v, t) = (place.variant, place.trip);
    out.add((
      report: r,
      place: place,
      assessment: assessReport(
        r,
        rt: v == null ? null : app.rt(l.id, d.id, v, t!),
        seen: v == null ? null : crowd['$v/$t'],
        stopIndex: place.stopIndex,
        trafficIncident: traffic,
      ),
    ));
  }
  return out..sort((a, b) => b.report.last.compareTo(a.report.last));
}

/// « Tram de 23:10 (départ Viroflay Rive Droite), à Chaville » : où porte un signalement placé.
String placeLabel(DemoLine l, Direction d, ReportPlace p) {
  final word = vehicleWord(l.type);
  final trip = p.variant == null
      ? null
      : '${word[0].toUpperCase()}${word.substring(1)} de ${hhmm(d.variants[p.variant!].trips[p.trip!].first)} '
            '(départ ${d.variants[p.variant!].stops.first.name})';
  return switch ((trip, p.stop?.name)) {
    (final t?, final s?) => '$t, à $s',
    (final t?, null) => t,
    (null, final s?) => 'À $s',
    _ => 'Sur la ligne',
  };
}

bool _alerting(PlacedReport p) =>
    p.assessment.trust != ReportTrust.contradicted &&
    (p.report.type == 'incident' || (p.report.type == 'retard' && p.report.detail == 'bloque'));

/// Courses (« variante/course ») signalées bloquées ou en incident, non contredites.
Set<String> alertTrips(List<PlacedReport> reports) => {
  for (final p in reports)
    if (p.place.variant != null && _alerting(p)) '${p.place.variant}/${p.place.trip}',
};

/// Arrêts où un incident est signalé sans course précise, non contredit.
List<LatLng> alertStops(List<PlacedReport> reports) => [
  for (final p in reports)
    if (p.place.variant == null && p.place.stop != null && _alerting(p)) p.place.stop!.pos,
];
