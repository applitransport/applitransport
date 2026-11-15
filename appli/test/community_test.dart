import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:applitransport/data/community.dart';
import 'package:applitransport/data/prim.dart';
import 'package:applitransport/data/realtime.dart';
import 'package:applitransport/poc/data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

// Formats attendus par le serveur (communaute/serveur.py).
final _session = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _ident = RegExp(r'^[A-Za-z0-9:_.\-]{1,64}$');
final _empreinte = RegExp(r'^[0-9a-f]{64}$');

RequestUsage _usage() => RequestUsage(File('${Directory.systemTemp.createTempSync().path}/requests.json'));

void main() {
  test('identifiant de session : UUID v4, différent à chaque trajet', () {
    final a = newSessionId(), b = newSessionId();
    expect(a, matches(_session));
    expect(a[14], '4');
    expect(a, isNot(b));
    expect(newSessionId(Random(1)), newSessionId(Random(1)));
  });

  test('empreinte du jour : stable dans la journée UTC, différente le lendemain et selon la clé', () {
    final key = newInstallKey();
    expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    final matin = dailyFingerprint(key, DateTime.utc(2026, 11, 14, 0, 5));
    expect(matin, matches(_empreinte));
    expect(dailyFingerprint(key, DateTime.utc(2026, 11, 14, 23, 55)), matin);
    expect(dailyFingerprint(key, DateTime.utc(2026, 11, 15, 0, 5)), isNot(matin));
    expect(dailyFingerprint(newInstallKey(), DateTime.utc(2026, 11, 14, 0, 5)), isNot(matin));
    expect(matin.contains(key), isFalse);
  });

  test('identifiants de course et d\'arrêt acceptés par le serveur', () {
    final v = Variant(
      'Pas du Lac',
      const [Stop('A', LatLng(48.78, 2.04), '', 'IDFM:20612'), Stop('B', LatLng(48.79, 2.05))],
      const [],
      const [
        [0, 60],
        [600, 660],
      ],
      const ['IDFM:SQY:12345-C01527-123456', 'bizarre/+ é'],
    );
    expect(courseId(v, 0), '123456');
    expect(courseId(v, 1), matches(_ident));
    expect(stopId(v, 0), 'IDFM:20612');
    expect(stopId(v, 1), 'a1'); // arrêt sans identifiant
  });

  group('client', () {
    test('envoi d\'une position : JSON, empreinte, compteur', () async {
      late http.Request sent;
      final usage = _usage();
      final c = CommunityClient(
        baseUrl: () => 'https://serveur.exemple',
        installKey: () => 'k' * 64,
        usage: usage,
        client: MockClient((r) async {
          sent = r;
          return http.Response('', 204);
        }),
      );
      await c.sendPosition({'v': 1, 'ligne': 'C01527'});
      expect(sent.url.toString(), 'https://serveur.exemple/v1/positions');
      expect(sent.headers['X-Empreinte'], matches(_empreinte));
      expect(jsonDecode(sent.body), {'v': 1, 'ligne': 'C01527'});
      expect(usage.of('communauté envoi'), 1);
    });

    test('refus du serveur : message lisible', () async {
      final c = CommunityClient(
        baseUrl: () => 'http://pi/',
        installKey: () => 'k',
        usage: _usage(),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'erreur': 'debit', 'message': 'au plus une position toutes les 20 s'}),
            429,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      expect(
        () => c.sendPosition({}),
        throwsA(isA<CommunityException>().having((e) => e.message, 'message', contains('20 s (HTTP 429)'))),
      );
    });

    test('lecture de l\'état d\'une ligne', () async {
      final body = {
        't': 1794640362,
        'vehicules': [
          {
            'course': '123456',
            'sens': 0,
            'arret_prec': 'IDFM:1',
            'arret_suiv': 'IDFM:2',
            'progression': 0.45,
            'lat': 48.7803,
            'lon': 2.0418,
            'vitesse_kmh': 23,
            'sources': 2,
            'concordant': true,
            'vu_il_y_a_s': 12,
          },
        ],
        'signalements': [
          {
            'id': 's-1',
            'type': 'incident',
            'detail': 'colis_suspect',
            'course': null,
            'arret': 'IDFM:2',
            'sources': 2,
            'premier': 1794640000,
            'dernier': 1794640300,
          },
          {
            'id': 's-2',
            'type': 'retard',
            'detail': 'bloque',
            'course': '123456',
            'arret': null,
            'sources': 1,
            'premier': 1794640200,
            'dernier': 1794640200,
          },
        ],
      };
      final usage = _usage();
      final c = CommunityClient(
        baseUrl: () => 'http://pi:8765/',
        installKey: () => 'k',
        usage: usage,
        client: MockClient((r) async {
          expect(r.url.path, '/v1/lignes/C01527');
          return http.Response(jsonEncode(body), 200);
        }),
      );
      final l = await c.line('C01527');
      expect(l.vehicles.single.course, '123456');
      expect(l.vehicles.single.sources, 2);
      expect(l.ageOf(l.vehicles.single, l.receivedAt.add(const Duration(seconds: 30))), 42);
      expect(usage.of('communauté lecture'), 1);
      final (a, b) = (l.reports[0], l.reports[1]);
      expect((a.label, a.stop, a.course, a.confirmed), ('Colis suspect', 'IDFM:2', null, true));
      expect((b.label, b.course, b.confirmed), ('Bloqué', '123456', false));
    });

    test('test de l\'adresse saisie', () async {
      final c = CommunityClient(
        baseUrl: () => '',
        installKey: () => 'k',
        usage: _usage(),
        client: MockClient((r) async => http.Response(r.url.path == '/sante' ? '{"ok":true}' : '', 200)),
      );
      expect(c.configured, isFalse);
      expect((await c.test('http://pi:8765')).ok, isTrue);
      expect((await c.test('')).ok, isFalse);
    });
  });

  group('position d\'un voyageur → horaire à votre arrêt', () {
    final v = Variant(
      'Pas du Lac',
      [for (var i = 1; i <= 4; i++) Stop('Arrêt $i', LatLng(48.78, 2.04 + i / 100), '', 'IDFM:$i')],
      const [],
      const [
        [36000, 36300, 36600, 36900], // 10:00, 10:05, 10:10, 10:15
      ],
      const ['IDFM:x-123'],
    );
    CrowdVehicle seenAt(String prev, String next, double progression, {int age = 20}) => CrowdVehicle.fromJson({
      'course': '123',
      'sens': 0,
      'arret_prec': prev,
      'arret_suiv': next,
      'progression': progression,
      'lat': 48.78,
      'lon': 2.06,
      'sources': 1,
      'concordant': true,
      'vu_il_y_a_s': age,
    });

    test('à mi-chemin entre les arrêts 2 et 3 : retard par rapport à l\'horaire', () {
      // prévu à mi-chemin à 10:07:30 ; il est 10:08:20 et la position date de 20 s : vu à 10:08:00
      final e = crowdEstimate(v, 0, seenAt('IDFM:2', 'IDFM:3', 0.5), ageSec: 20, nowSec: 36500)!;
      expect(e.lastStop, 1);
      expect(e.delaySec, 30);
    });

    test('arrêts dépassés et heure estimée aux suivants', () {
      final e = crowdEstimate(v, 0, seenAt('IDFM:2', 'IDFM:3', 0.5), ageSec: 0, nowSec: 36510)!;
      expect(e.delaySec, 60); // prévu 10:07:30 à mi-chemin, vu à 10:08:30
      expect(e.passed(0), isTrue);
      expect(e.passed(1), isTrue);
      expect(e.passed(2), isFalse);
      expect(e.expectedAt(v.trips[0], 3), 36960); // 10:15 + 1 min
    });

    test('en avance entre deux arrêts : retard négatif', () {
      // prévu à mi-chemin à 10:02:30, vu à 10:01:30
      final e = crowdEstimate(v, 0, seenAt('IDFM:1', 'IDFM:2', 0.5), ageSec: 0, nowSec: 36090)!;
      expect(e.delaySec, -60);
    });

    test('au terminus avant le départ : pas d\'avance, le véhicule attend son heure', () {
      final e = crowdEstimate(v, 0, seenAt('IDFM:1', 'IDFM:2', 0.0), ageSec: 0, nowSec: 35880)!; // 9:58
      expect(e.delaySec, 0);
      expect(e.expectedAt(v.trips[0], 2), 36600);
    });

    test('arrêts absents de cette variante : pas d\'estimation', () {
      expect(crowdEstimate(v, 0, seenAt('IDFM:9', 'IDFM:10', 0.5), ageSec: 0, nowSec: 36500), isNull);
      expect(crowdEstimate(v, 0, seenAt('IDFM:3', 'IDFM:2', 0.5), ageSec: 0, nowSec: 36500), isNull); // autre sens
    });
  });

  group('confiance d\'un signalement', () {
    CrowdReport report(String type, String detail, {int sources = 1}) => CrowdReport.fromJson({
      'id': 's',
      'type': type,
      'detail': detail,
      'course': '123',
      'arret': 'IDFM:2',
      'sources': sources,
      'premier': 0,
      'dernier': 0,
    });
    final v = Variant(
      'Est',
      [for (var i = 1; i <= 4; i++) Stop('Arrêt $i', LatLng(48.78, 2.04 + i / 100), '', 'IDFM:$i')],
      const [],
      const [
        [36000, 36300, 36600, 36900],
      ],
      const ['x-123'],
    );
    CrowdEstimate seenBetween(String a, String b, {int now = 36500}) => crowdEstimate(
      v,
      0,
      CrowdVehicle.fromJson({
        'course': '123',
        'sens': 0,
        'arret_prec': a,
        'arret_suiv': b,
        'progression': 0.5,
        'lat': 48.78,
        'lon': 2.06,
        'sources': 1,
        'concordant': true,
        'vu_il_y_a_s': 0,
      }),
      ageSec: 0,
      nowSec: now,
    )!;

    test('un seul voyageur : non confirmé ; deux : confirmé', () {
      expect(assessReport(report('incident', 'panne')).trust, ReportTrust.unconfirmed);
      final two = assessReport(report('incident', 'panne', sources: 2));
      expect((two.trust, two.reason), (ReportTrust.confirmed, 'Confirmé par 2 voyageurs'));
    });

    test('supprimé : confirmé par PRIM, contredit par un voyageur à bord', () {
      final cancelled = TripRealtime(const {}, 4, cancelled: true);
      expect(assessReport(report('supprime', 'supprime'), rt: cancelled, stopIndex: 1).reason, 'Confirmé par PRIM');
      final aboard = assessReport(report('supprime', 'supprime', sources: 3), seen: seenBetween('IDFM:1', 'IDFM:2'));
      expect(aboard.trust, ReportTrust.contradicted);
    });

    test('pas encore passé : contredit si déjà passé, confirmé par un retard de 3 min', () {
      final passedStop = assessReport(
        report('retard', 'pas_passe'),
        seen: seenBetween('IDFM:3', 'IDFM:4'),
        stopIndex: 1,
      );
      expect(passedStop.trust, ReportTrust.contradicted);
      final late = assessReport(
        report('retard', 'pas_passe'),
        rt: TripRealtime(const {1: 240}, 4, nextIndex: 1),
        stopIndex: 1,
      );
      expect((late.trust, late.reason), (ReportTrust.confirmed, 'Confirmé par PRIM'));
      final onTime = assessReport(report('retard', 'pas_passe'), rt: TripRealtime(const {1: 30}, 4), stopIndex: 1);
      expect(onTime.trust, ReportTrust.unconfirmed);
    });

    test('incident : confirmé par l\'Info Trafic ; affluence : jamais par PRIM', () {
      expect(assessReport(report('incident', 'panne'), trafficIncident: true).reason, 'Confirmé par l\'Info Trafic');
      expect(assessReport(report('affluence', 'plein'), trafficIncident: true).trust, ReportTrust.unconfirmed);
    });
  });
}
