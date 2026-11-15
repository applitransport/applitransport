import 'dart:io';
import 'dart:math';

import 'package:applitransport/data/package_decoder.dart';
import 'package:applitransport/data/ride.dart';
import 'package:applitransport/data/ride_session.dart';
import 'package:applitransport/data/track.dart';
import 'package:applitransport/poc/position.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

// Tracé d'essai : une ligne droite vers l'est de 3 km à Saint-Quentin, arrêts tous les 1 000 m.
const _lat = 48.78, _lon0 = 2.04;
final _mPerDegLon = 6371000 * pi / 180 * cos(_lat * pi / 180);
const _mPerDegLat = 6371000 * pi / 180;

/// Point à [x] m à l'est du départ et [y] m au nord du tracé.
LatLng _at(double x, [double y = 0]) => LatLng(_lat + y / _mPerDegLat, _lon0 + x / _mPerDegLon);

final _shape = [for (var x = 0.0; x <= 3000; x += 250) _at(x)];
final _stops = [for (var x = 0.0; x <= 3000; x += 1000) _at(x)];

void main() {
  group('géométrie du tracé', () {
    final g = TrackGeometry(_shape, _stops);

    test('longueur et position des arrêts', () {
      expect(g.length, closeTo(3000, 1));
      expect(g.stopAt.map((s) => s.round()), [0, 1000, 2000, 3000]);
    });

    test('projection : distance parcourue et écart au tracé', () {
      final p = g.project(_at(1234, 20))!;
      expect(p.along, closeTo(1234, 1));
      expect(p.offset, closeTo(20, 0.5));
      expect(distanceMeters(p.point, _at(1234)), lessThan(1));
    });

    test('projection limitée à une portion du tracé', () {
      final p = g.project(_at(2500), from: 0, to: 1000)!;
      expect(p.along, closeTo(1000, 1)); // bout de la portion
      expect(p.offset, closeTo(1500, 2));
    });

    test('arrêt précédent', () {
      expect(g.stopBefore(0), 0);
      expect(g.stopBefore(1500), 1);
      expect(g.stopBefore(3000), 2); // jamais le terminus : il faut un arrêt suivant
    });

    test('sans tracé : ligne droite d\'arrêt en arrêt', () {
      final s = TrackGeometry(const [], _stops);
      expect(s.length, closeTo(3000, 1));
      expect(s.project(_at(500, 10))!.along, closeTo(500, 1));
    });
  });

  group('suivi d\'un trajet', () {
    RideTracker ride({String type = 'bus', double? hint}) => RideTracker(
      TrackGeometry(_shape, _stops),
      startSec: 0,
      thresholds: RideThresholds.forType(type),
      hintAlong: hint,
    );

    test('trajet normal : points acceptés, arrêts et avancement', () {
      final r = ride();
      final s = r.add(_at(1500, 15), accuracy: 10, timeSec: 0);
      expect(s.verdict, SampleVerdict.accepted);
      expect([s.prevStop, s.nextStop], [1, 2]);
      expect(s.progression, closeTo(0.5, 0.01));
      final s2 = r.add(_at(1700, -10), accuracy: 10, timeSec: 30); // 200 m en 30 s = 24 km/h
      expect(s2.accepted, isTrue);
      expect(s2.speedKmh, closeTo(24, 0.5));
      expect(r.accepted, 2);
      expect(r.ended, isNull);
    });

    test('point imprécis ignoré sans compter comme hors tracé', () {
      final r = ride();
      for (var i = 0; i < 5; i++) {
        expect(r.add(_at(500, 300), accuracy: 80, timeSec: i * 10).verdict, SampleVerdict.poorAccuracy);
      }
      expect(r.ended, isNull);
    });

    test('trois points hors tracé de suite terminent le trajet', () {
      final r = ride();
      r.add(_at(500), accuracy: 10, timeSec: 0);
      expect(r.add(_at(600, 200), accuracy: 10, timeSec: 10).verdict, SampleVerdict.offTrack);
      expect(r.add(_at(600, 200), accuracy: 10, timeSec: 20).verdict, SampleVerdict.offTrack);
      expect(r.ended, isNull);
      r.add(_at(600, 200), accuracy: 10, timeSec: 30);
      expect(r.ended, RideEnd.offTrack);
      expect(r.add(_at(700), accuracy: 10, timeSec: 40).verdict, SampleVerdict.ended);
    });

    test('un point de retour sur le tracé remet le compteur à zéro', () {
      final r = ride();
      r.add(_at(500), accuracy: 10, timeSec: 0);
      r.add(_at(600, 200), accuracy: 10, timeSec: 10);
      r.add(_at(600, 200), accuracy: 10, timeSec: 20);
      r.add(_at(650), accuracy: 10, timeSec: 30);
      r.add(_at(700, 200), accuracy: 10, timeSec: 40);
      expect(r.ended, isNull);
    });

    test('petit recul toléré sans faire reculer le véhicule, grand recul rejeté', () {
      final r = ride();
      r.add(_at(1000), accuracy: 10, timeSec: 0);
      final s = r.add(_at(960), accuracy: 10, timeSec: 10);
      expect(s.accepted, isTrue);
      expect(s.projection!.along, closeTo(1000, 1));
      expect(r.add(_at(700), accuracy: 10, timeSec: 20).verdict, SampleVerdict.backwards);
    });

    test('vitesse : limite des bus, plus haute pour les trains', () {
      final bus = ride();
      bus.add(_at(0), accuracy: 10, timeSec: 0);
      expect(bus.add(_at(1000), accuracy: 10, timeSec: 30).verdict, SampleVerdict.tooFast); // 120 km/h
      final train = ride(type: 'train');
      train.add(_at(0), accuracy: 10, timeSec: 0);
      expect(train.add(_at(1000), accuracy: 10, timeSec: 30).accepted, isTrue);
    });

    test('terminus atteint', () {
      final r = ride();
      r.add(_at(2800), accuracy: 10, timeSec: 0);
      expect(r.ended, isNull);
      r.add(_at(2990), accuracy: 10, timeSec: 30);
      expect(r.ended, RideEnd.terminus);
    });

    test('immobile hors d\'un arrêt plus de 10 min : fin ; à un arrêt : on continue', () {
      final away = ride();
      for (var t = 0; t <= 660; t += 60) {
        away.add(_at(1500, 5), accuracy: 10, timeSec: t);
      }
      expect(away.ended, RideEnd.immobile);
      final atStop = ride();
      for (var t = 0; t <= 660; t += 60) {
        atStop.add(_at(1010), accuracy: 10, timeSec: t);
      }
      expect(atStop.ended, isNull);
    });

    test('durée maximale', () {
      final r = ride();
      r.add(_at(100), accuracy: 10, timeSec: 0);
      expect(r.add(_at(150), accuracy: 10, timeSec: 5401).verdict, SampleVerdict.ended);
      expect(r.ended, RideEnd.tooLong);
    });

    test('montée : premier point à plus de 400 m de l\'arrêt refusé, sans terminer le trajet', () {
      final r = RideTracker(TrackGeometry(_shape, _stops), startSec: 0, hintAlong: 1000, boardAt: _at(1000));
      expect(r.add(_at(1600), accuracy: 10, timeSec: 0).verdict, SampleVerdict.notAtStop); // 600 m
      expect(r.add(_at(1000, 2000), accuracy: 80, timeSec: 5).verdict, SampleVerdict.poorAccuracy); // imprécis
      for (var t = 10; t < 60; t += 10) {
        r.add(_at(2500), accuracy: 10, timeSec: t);
      }
      expect(r.ended, isNull);
      expect(r.add(_at(1300, 20), accuracy: 10, timeSec: 60).accepted, isTrue); // 300 m : à l'arrêt
      // ensuite, le trajet s'éloigne normalement de l'arrêt
      expect(r.add(_at(1500), accuracy: 10, timeSec: 80).accepted, isTrue);
    });

    test('arrêt par l\'usager', () {
      final r = ride()..stop();
      expect(r.ended, RideEnd.stopped);
      expect(r.add(_at(100), accuracy: 10, timeSec: 0).verdict, SampleVerdict.ended);
    });
  });

  test('aller-retour sur la même rue : l\'indication de départ choisit le bon passage', () {
    // tracé aller puis retour sur la même rue (3 km chacun), arrêts aux deux bouts et au milieu
    final shape = [..._shape, ..._shape.reversed.skip(1)];
    final stops = [_at(0), _at(3000), _at(0)];
    final g = TrackGeometry(shape, stops);
    expect(g.stopAt.map((s) => s.round()), [0, 3000, 6000]);
    final r = RideTracker(g, startSec: 0, hintAlong: 4500); // le bus est sur le retour
    final s = r.add(_at(1500, 5), accuracy: 10, timeSec: 0);
    expect(s.projection!.along, closeTo(4500, 2));
    expect([s.prevStop, s.nextStop], [1, 2]);
  });

  test('vrai tracé (paquet C01527) : un trajet bruité d\'arrêt en arrêt est suivi jusqu\'au terminus', () {
    final pkg = readPackage(File('test/fixtures/C01527.json.gz').readAsBytesSync());
    final line = timetableFor(pkg, DateTime(2026, 10, 29), withPreviousNight: false);
    final v = line.directions.first.variants.first;
    final g = trackOf(v);
    expect(g.stopAt.length, v.stops.length);
    final r = RideTracker(g, startSec: 0);
    var t = 0;
    var lastStop = -1;
    // un point tous les 150 m, décalé de 15 m alternativement de chaque côté (bruit GPS)
    for (var along = 0.0; along <= g.length && r.ended == null; along += 150) {
      final p = g.pointAt(along);
      final side = (along ~/ 150).isEven ? 15 : -15;
      final noisy = LatLng(p.latitude + side / _mPerDegLat, p.longitude);
      final s = r.add(noisy, accuracy: 12, timeSec: t += 20); // 150 m / 20 s = 27 km/h
      expect(s.accepted, isTrue, reason: 'point à ${along.round()} m refusé : ${s.verdict}');
      expect(s.prevStop, greaterThanOrEqualTo(lastStop));
      lastStop = s.prevStop;
    }
    r.add(g.points.last, accuracy: 12, timeSec: t + 20);
    expect(r.ended, RideEnd.terminus);
    expect(r.rejected, 0);
  });

  test('simulation : premier point accepté et envoyé tout de suite, puis arrêt', () async {
    final g = TrackGeometry(_shape, _stops);
    final sent = <(int, String)>[];
    final ride = RideSession.simulate(
      lineId: 'C01527',
      direction: 0,
      variant: 0,
      trip: 3,
      tracker: (start) => RideTracker(g, startSec: start, hintAlong: 1200),
      track: g,
      startAlong: 1200,
      speedKmh: 25,
      share: (s, session) async => sent.add((s.prevStop, session)),
    );
    expect(ride.simulated, isTrue);
    expect(ride.lastSample!.accepted, isTrue);
    expect(ride.lastSample!.projection!.along, closeTo(1200, 15));
    await Future<void>.delayed(Duration.zero);
    expect(sent.single.$1, 1);
    expect(sent.single.$2, ride.session);
    expect(ride.sent, 1);
    ride.stop();
    expect(ride.active, isFalse);
    ride.dispose();
  });
}
