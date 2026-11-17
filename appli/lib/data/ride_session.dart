// Trajet « je suis dedans » en cours : relie le GPS du téléphone au suivi du trajet (ride.dart).
// Étape 1 de la note de conception : tout reste sur le téléphone, rien n'est envoyé.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'geo.dart';
import 'package:latlong2/latlong.dart';

import 'community.dart' show newSessionId;
import 'location.dart';
import 'ride.dart';
import 'track.dart';

/// Intervalle minimal entre deux envois au serveur (s), comme dans la note de conception.
const shareIntervalSec = 30;

class RideSession extends ChangeNotifier {
  RideSession._(this.lineId, this.direction, this.variant, this.trip, this.tracker, this.share);

  /// Course suivie : ligne, sens, variante et course (indices de l'écran de suivi).
  final String lineId;
  final int direction, variant, trip;
  final RideTracker tracker;

  /// Envoi d'un point accepté au serveur communautaire ; null quand l'usager ne participe pas.
  final Future<void> Function(RideSample sample, String session)? share;

  /// Identifiant aléatoire de ce trajet, jeté à la fin.
  final String session = newSessionId();
  int sent = 0;
  int? _lastShareSec;
  String? shareError;

  /// Libellé de la course pour le bandeau (« Bus de 08:12 → Pas du Lac »).
  String label = '';

  /// Arrêt de montée, pour le message « Vous ne semblez pas être à … ».
  String boardStop = '';

  /// Dernier point reçu, accepté ou non.
  RideSample? lastSample;
  String? error;
  StreamSubscription<Position>? _gps;
  Timer? _sim;

  /// Trajet simulé (compilations de debug) : fausse position le long du tracé.
  bool simulated = false;

  static int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Demande la permission puis suit le GPS. Lève une erreur lisible si la position est indisponible.
  static Future<RideSession> start({
    required String lineId,
    required int direction,
    required int variant,
    required int trip,
    required RideTracker Function(int startSec) tracker,
    Future<void> Function(RideSample sample, String session)? share,
  }) async {
    await ensureLocationPermission();
    final s = RideSession._(lineId, direction, variant, trip, tracker(nowSec()), share);
    s._gps = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
    ).listen(s._onPosition, onError: s._onError);
    return s;
  }

  /// Simulation d'un trajet, pour tester l'envoi et l'affichage sans être dans le véhicule : un
  /// point toutes les 5 s, en temps réel, de [startAlong] au terminus à [speedKmh], avec un bruit GPS
  /// de ±10 m. Passe par le même suivi et le même envoi qu'un vrai trajet.
  static RideSession simulate({
    required String lineId,
    required int direction,
    required int variant,
    required int trip,
    required RideTracker Function(int startSec) tracker,
    required TrackGeometry track,
    required double startAlong,
    required double speedKmh,
    Future<void> Function(RideSample sample, String session)? share,
  }) {
    final s = RideSession._(lineId, direction, variant, trip, tracker(nowSec()), share)..simulated = true;
    final random = Random();
    var along = startAlong;
    void step() {
      final p = track.pointAt(min(along, track.length));
      final noise = (random.nextDouble() * 2 - 1) * 10 / 111000; // ±10 m en latitude
      s._onFix(LatLng(p.latitude + noise, p.longitude), 8, nowSec());
      along += speedKmh / 3.6 * 5;
    }

    step();
    s._sim = Timer.periodic(const Duration(seconds: 5), (_) => step());
    return s;
  }

  bool isTrip(String line, int dir, int v, int t) => line == lineId && dir == direction && v == variant && t == trip;
  bool get active => tracker.ended == null;

  /// Position recalée du véhicule si le dernier point accepté a moins de [maxAgeSec] secondes.
  LatLng? freshPosition({int maxAgeSec = 60}) {
    final last = tracker.last;
    if (last == null || nowSec() - last.timeSec > maxAgeSec) return null;
    return last.projection?.point;
  }

  void _onPosition(Position p) =>
      _onFix(LatLng(p.latitude, p.longitude), p.accuracy, p.timestamp.millisecondsSinceEpoch ~/ 1000);

  void _onFix(LatLng point, double accuracy, int timeSec) {
    lastSample = tracker.add(point, accuracy: accuracy, timeSec: timeSec);
    final sample = lastSample!;
    if (share != null &&
        sample.accepted &&
        (_lastShareSec == null || sample.timeSec - _lastShareSec! >= shareIntervalSec)) {
      _lastShareSec = sample.timeSec;
      share!(sample, session).then(
        (_) {
          sent++;
          shareError = null;
          notifyListeners();
        },
        onError: (Object e) {
          shareError = '$e';
          notifyListeners();
        },
      );
    }
    if (!active) _cancel();
    notifyListeners();
  }

  void _cancel() {
    _gps?.cancel();
    _sim?.cancel();
  }

  void _onError(Object e) {
    error = '$e';
    notifyListeners();
  }

  void stop() {
    tracker.stop();
    _cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }
}

String verdictLabel(SampleVerdict v) => switch (v) {
  SampleVerdict.accepted => 'point accepté',
  SampleVerdict.poorAccuracy => 'GPS trop imprécis',
  SampleVerdict.notAtStop => 'trop loin de l\'arrêt de montée',
  SampleVerdict.offTrack => 'hors du tracé de la ligne',
  SampleVerdict.backwards => 'recul impossible',
  SampleVerdict.tooFast => 'vitesse impossible',
  SampleVerdict.ended => 'trajet terminé',
};

String endLabel(RideEnd e) => switch (e) {
  RideEnd.stopped => 'partage arrêté',
  RideEnd.offTrack => 'vous avez quitté le tracé de la ligne',
  RideEnd.terminus => 'terminus atteint',
  RideEnd.immobile => 'immobile depuis plus de 10 min hors d\'un arrêt',
  RideEnd.tooLong => 'durée maximale atteinte (1 h 30)',
};
