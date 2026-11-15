// Trajets « à bord » : démarrage (GPS ou simulation, partage de position si l'usager participe) et
// recherche de la course où se trouve l'usager. Partagé par le suivi de ligne et l'état de la ligne ;
// le trajet en cours est tenu par AppState (il continue en changeant d'écran).
import 'package:latlong2/latlong.dart';

import '../data/community.dart';
import '../data/realtime.dart';
import '../data/ride.dart';
import '../data/ride_session.dart';
import 'app_state.dart';
import 'data.dart';
import 'position.dart';

String capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// « Tram de 23:10 (départ Viroflay Rive Droite) → Châtillon ».
String tripName(DemoLine l, Direction d, int variant, int trip) {
  final v = d.variants[variant];
  return '${capitalized(vehicleWord(l.type))} de ${hhmm(v.trips[trip].first)} (départ ${v.stops.first.name}) '
      '→ ${v.headsign}';
}

/// Démarre un trajet sur la course [trip] de la variante [variant] du sens d'index [dirIndex] et le
/// confie à [app]. [startAlong] : point de départ le long du tracé ; [boardAt] : arrêt de montée à
/// moins de 400 m duquel doit être le premier point GPS (null : pas de contrôle). Lève une erreur
/// lisible si la position est indisponible.
Future<RideSession> beginRide(
  AppState app,
  DemoLine l,
  int dirIndex, {
  required int variant,
  required int trip,
  required double startAlong,
  required String label,
  LatLng? boardAt,
  String boardStop = '',
  bool simulate = false,
}) async {
  final d = l.directions[dirIndex];
  final v = d.variants[variant];
  final track = trackOf(v);
  RideTracker tracker(int start) => RideTracker(
    track,
    startSec: start,
    thresholds: RideThresholds.forType(l.type),
    hintAlong: startAlong,
    boardAt: boardAt,
  );
  Future<void> share(RideSample sample, String session) => app.community.sendPosition({
    'v': 1,
    'session': session,
    'ligne': l.id,
    'course': courseId(v, trip),
    'sens': d.id,
    'arret_prec': stopId(v, sample.prevStop),
    'arret_suiv': stopId(v, sample.nextStop),
    'progression': double.parse(sample.progression.toStringAsFixed(3)),
    'lat': double.parse(sample.projection!.point.latitude.toStringAsFixed(4)),
    'lon': double.parse(sample.projection!.point.longitude.toStringAsFixed(4)),
    'vitesse_kmh': sample.speedKmh?.roundToDouble(),
    't': sample.timeSec,
  });
  final sharing = app.communityShare && app.community.configured ? share : null;
  final ride = simulate
      ? RideSession.simulate(
          lineId: l.id,
          direction: dirIndex,
          variant: variant,
          trip: trip,
          tracker: tracker,
          track: track,
          startAlong: startAlong,
          speedKmh: l.type == 'bus' || l.type == 'tram' ? 25 : 60,
          share: sharing,
        )
      : await RideSession.start(
          lineId: l.id,
          direction: dirIndex,
          variant: variant,
          trip: trip,
          tracker: tracker,
          share: sharing,
        );
  ride
    ..boardStop = boardStop
    ..label = '$label${simulate ? ' (simulation)' : ''}';
  app.setRide(ride);
  return ride;
}

/// Course candidate pour « Je suis à bord » : écart (m) le long du tracé entre l'usager et la
/// position estimée de la course, et position de l'usager le long du tracé.
typedef AboardCandidate = ({int v, int t, double gap, double along});

/// Écart maximal le long du tracé entre l'usager et la position estimée d'une course (m).
const aboardMaxGap = 3000.0;

/// Courses du sens [d] en circulation près de [me], la plus probable en premier. La position d'une
/// course est celle vue par un voyageur ([crowd], par « variante/course »), sinon celle de PRIM
/// ([rt]), sinon celle de l'horaire. [onTrack] : l'usager est-il sur le tracé d'une variante ?
({bool onTrack, List<AboardCandidate> candidates}) aboardCandidates(
  Direction d,
  LatLng me,
  int nowSec, {
  Map<String, CrowdEstimate> crowd = const {},
  TripRealtime? Function(int variant, int trip)? rt,
}) {
  const th = RideThresholds();
  final found = <AboardCandidate>[];
  var onTrack = false;
  for (var v = 0; v < d.variants.length; v++) {
    final track = trackOf(d.variants[v]);
    final mine = track.project(me);
    if (mine == null || mine.offset > th.maxOffset) continue;
    onTrack = true;
    for (var t = 0; t < d.variants[v].trips.length; t++) {
      final seen = crowd['$v/$t'];
      final LatLng at;
      if (seen != null) {
        at = LatLng(seen.vehicle.lat, seen.vehicle.lon);
      } else {
        final s = busStatus(d.variants[v], t, nowSec, rt?.call(v, t));
        if (s == null) continue;
        at = s.position;
      }
      final along = track.project(at)?.along;
      if (along == null) continue;
      final gap = (along - mine.along).abs();
      if (gap <= aboardMaxGap) found.add((v: v, t: t, gap: gap, along: mine.along));
    }
  }
  found.sort((a, b) => a.gap.compareTo(b.gap));
  return (onTrack: onTrack, candidates: found);
}

/// Distance maximale entre l'usager et le bus choisi pour monter à bord (m, le long du tracé).
const boardMaxGap = 400.0;

/// Résultat du contrôle « À bord » d'un bus choisi sur la carte.
enum BoardCheck {
  /// Monter : l'usager est sur le tracé, près du bus.
  ok,

  /// À plus de 60 m du tracé : pas sur cette ligne (ou un autre bus).
  offLine,

  /// Position du bus connue (voyageur ou PRIM) et loin de l'usager : refusé.
  tooFar,

  /// Position seulement théorique et loin de l'usager : confirmation demandée.
  confirm,
}

/// Contrôle avant de monter dans la course [trip] de la variante [v] : l'usager en [me] doit être à
/// moins de 60 m du tracé et à moins de 400 m (le long du tracé) du bus, placé en [busAt].
/// [theoretical] : position du bus déduite de l'horaire seul. [along] : position de l'usager le
/// long du tracé (point de départ du suivi), [gap] : écart avec le bus.
({BoardCheck check, double along, double gap}) boardCheck(
  Variant v,
  LatLng me,
  LatLng busAt, {
  required bool theoretical,
}) {
  final track = trackOf(v);
  final mine = track.project(me);
  if (mine == null || mine.offset > const RideThresholds().maxOffset) {
    return (check: BoardCheck.offLine, along: 0, gap: 0);
  }
  final bus = track.project(busAt)?.along ?? 0;
  final gap = (bus - mine.along).abs();
  final check = gap <= boardMaxGap
      ? BoardCheck.ok
      : theoretical
      ? BoardCheck.confirm
      : BoardCheck.tooFar;
  return (check: check, along: mine.along, gap: gap);
}
