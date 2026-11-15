// « Je suis dedans » : suivi d'un trajet déclaré par l'usager. Chaque point GPS est recalé sur le
// tracé de la course, contrôlé (précision, écart, sens, vitesse) puis accepté ou rejeté ; le trajet
// se termine tout seul (hors tracé, terminus, immobilité, durée). Aucun réseau : logique pure, testée
// sans GPS. Seuils de la note de conception « Signalements communautaires », à ajuster sur le terrain.
import 'package:latlong2/latlong.dart';

import 'track.dart';

class RideThresholds {
  const RideThresholds({
    this.maxAccuracy = 50,
    this.maxOffset = 60,
    this.maxBackward = 100,
    this.maxSpeedKmh = 90,
    this.offTrackLimit = 3,
    this.immobileSec = 600,
    this.immobileRadius = 30,
    this.nearStop = 50,
    this.maxDurationSec = 5400,
    this.terminusMargin = 30,
    this.searchBack = 500,
    this.searchAhead = 2000,
    this.maxBoardDistance = 400,
  });

  /// Seuils selon le type de ligne : les trains roulent plus vite que les bus.
  factory RideThresholds.forType(String type) => switch (type) {
    'train' || 'metro' => const RideThresholds(maxSpeedKmh: 160),
    _ => const RideThresholds(),
  };

  /// Précision GPS minimale (m) ; au-delà, le point est ignoré.
  final double maxAccuracy;

  /// Écart maximal au tracé (m).
  final double maxOffset;

  /// Recul toléré le long du tracé (m) : imprécision GPS, pas un demi-tour.
  final double maxBackward;
  final double maxSpeedKmh;

  /// Nombre de points hors tracé de suite qui terminent le trajet.
  final int offTrackLimit;

  /// Immobilité hors d'un arrêt qui termine le trajet (s), et rayon qui compte pour « immobile » (m).
  final int immobileSec;
  final double immobileRadius;

  /// Distance le long du tracé sous laquelle on est « à un arrêt » (m).
  final double nearStop;
  final int maxDurationSec;

  /// Distance avant la fin du tracé à partir de laquelle le terminus est atteint (m).
  final double terminusMargin;

  /// Portion du tracé où chercher le point suivant, autour du dernier point accepté (m).
  final double searchBack, searchAhead;

  /// Distance maximale (à vol d'oiseau) entre le premier point et l'arrêt de montée (m).
  final double maxBoardDistance;
}

enum SampleVerdict { accepted, poorAccuracy, notAtStop, offTrack, backwards, tooFast, ended }

enum RideEnd { stopped, offTrack, terminus, immobile, tooLong }

/// Ce qui serait envoyé au serveur pour un point accepté (format de la note de conception).
class RideSample {
  const RideSample({
    required this.verdict,
    required this.timeSec,
    this.projection,
    this.prevStop = 0,
    this.nextStop = 1,
    this.progression = 0,
    this.speedKmh,
  });

  final SampleVerdict verdict;
  final int timeSec;
  final TrackProjection? projection;

  /// Arrêt précédent et suivant (index dans la variante), et avancement entre les deux (0 à 1).
  final int prevStop, nextStop;
  final double progression;
  final double? speedKmh;

  bool get accepted => verdict == SampleVerdict.accepted;
}

class RideTracker {
  /// [startSec] : début du trajet (s, même horloge que les points). [hintAlong] : position estimée
  /// du véhicule le long du tracé au départ, pour ne pas confondre l'aller et le retour d'une boucle.
  /// [boardAt] : arrêt de montée ; tant qu'aucun point n'est accepté, un point précis à plus de
  /// [RideThresholds.maxBoardDistance] de cet arrêt est refusé (l'usager n'y est pas).
  RideTracker(
    this.track, {
    required this.startSec,
    this.thresholds = const RideThresholds(),
    double? hintAlong,
    this.boardAt,
  }) : _hint = hintAlong;

  final LatLng? boardAt;

  final TrackGeometry track;
  final RideThresholds thresholds;
  final int startSec;
  final double? _hint;

  RideEnd? ended;
  RideSample? last; // dernier point accepté
  int accepted = 0, rejected = 0;
  int _offTrackStreak = 0;
  double? _anchorAlong; // immobilité : position et heure du dernier vrai déplacement
  int _anchorSec = 0;

  /// Arrêt volontaire par l'usager.
  void stop() => ended ??= RideEnd.stopped;

  RideSample add(LatLng p, {required double accuracy, required int timeSec}) {
    final th = thresholds;
    if (ended == null && timeSec - startSec > th.maxDurationSec) ended = RideEnd.tooLong;
    if (ended != null) return RideSample(verdict: SampleVerdict.ended, timeSec: timeSec);
    if (accuracy > th.maxAccuracy) return _reject(SampleVerdict.poorAccuracy, timeSec);
    if (last == null && boardAt != null && distanceMeters(p, boardAt!) > th.maxBoardDistance) {
      return _reject(SampleVerdict.notAtStop, timeSec);
    }

    final prev = last?.projection?.along;
    final center = prev ?? _hint;
    TrackProjection? proj;
    if (center != null) {
      proj = track.project(p, from: center - th.searchBack, to: center + th.searchAhead);
    }
    // premier point sans indication, ou indication fausse : tout le tracé
    if (prev == null && (proj == null || proj.offset > th.maxOffset)) proj = track.project(p);
    if (proj == null || proj.offset > th.maxOffset) {
      if (++_offTrackStreak >= th.offTrackLimit) ended = RideEnd.offTrack;
      return _reject(SampleVerdict.offTrack, timeSec, proj);
    }
    _offTrackStreak = 0;

    double? speed;
    var along = proj.along;
    if (prev != null) {
      if (along < prev - th.maxBackward) return _reject(SampleVerdict.backwards, timeSec, proj);
      final dt = timeSec - last!.timeSec;
      if (dt > 0) {
        speed = (along - prev).clamp(0, double.infinity) / dt * 3.6;
        if (speed > th.maxSpeedKmh) return _reject(SampleVerdict.tooFast, timeSec, proj);
      }
      if (along < prev) along = prev; // petit recul : le véhicule n'a pas reculé
    }
    final snapped = along == proj.along
        ? proj
        : TrackProjection(along: along, offset: proj.offset, point: track.pointAt(along));

    final i = track.stopBefore(along);
    final a = track.stopAt[i], b = track.stopAt[i + 1];
    final sample = RideSample(
      verdict: SampleVerdict.accepted,
      timeSec: timeSec,
      projection: snapped,
      prevStop: i,
      nextStop: i + 1,
      progression: b > a ? ((along - a) / (b - a)).clamp(0.0, 1.0) : 1.0,
      speedKmh: speed,
    );
    last = sample;
    accepted++;

    if (along >= track.stopAt.last - th.terminusMargin) {
      ended = RideEnd.terminus;
    } else if (_anchorAlong == null || along - _anchorAlong! > th.immobileRadius) {
      _anchorAlong = along;
      _anchorSec = timeSec;
    } else if (timeSec - _anchorSec > th.immobileSec && !_nearStop(along)) {
      ended = RideEnd.immobile;
    }
    return sample;
  }

  bool _nearStop(double along) => track.stopAt.any((s) => (s - along).abs() <= thresholds.nearStop);

  RideSample _reject(SampleVerdict v, int timeSec, [TrackProjection? proj]) {
    rejected++;
    return RideSample(verdict: v, timeSec: timeSec, projection: proj);
  }
}
