// Client du serveur communautaire (dossier communaute/ du dépôt) : envoi des positions « je suis
// dedans » et lecture des véhicules vus par les voyageurs. Formats de la note de conception.
// Vie privée : une session tirée au hasard par trajet ; l'en-tête X-Empreinte est un HMAC de la date
// du jour (UTC) par la clé d'installation, qui ne quitte jamais l'appareil.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../poc/data.dart';
import '../widgets/locked_field.dart' show TestResult;
import 'prim.dart' show RequestUsage;
import 'realtime.dart' show TripRealtime;

/// Compteurs de requêtes vers le serveur communautaire (sans limite PRIM).
const communityKinds = {
  'communauté envoi': 'positions envoyées',
  'communauté signalement': 'signalements envoyés',
  'communauté lecture': 'état des lignes',
};

final _ident = RegExp(r'[^A-Za-z0-9:_.\-]');

/// Identifiant d'une course partagé entre téléphones : numéro de course (suffixe du trip_id GTFS,
/// comme pour le rattachement au temps réel), ou rang de la course sans trip_id.
String courseId(Variant v, int trip) {
  final raw = trip < v.tripIds.length ? v.tripIds[trip].split('-').last : 'c$trip';
  final id = raw.replaceAll(_ident, '');
  return id.isEmpty ? 'c$trip' : (id.length > 64 ? id.substring(id.length - 64) : id);
}

/// Identifiant d'arrêt accepté par le serveur.
String stopId(Variant v, int index) {
  final id = v.stops[index].id.replaceAll(_ident, '');
  return id.isEmpty || id.length > 64 ? 'a$index' : id;
}

/// Identifiant aléatoire (UUID v4) d'une session.
String newSessionId([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Clé d'installation : 32 octets aléatoires en hexadécimal.
String newInstallKey() {
  final r = Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Empreinte du jour : change chaque jour (UTC), ne permet pas de remonter à la clé.
String dailyFingerprint(String installKey, DateTime nowUtc) {
  final day = nowUtc.toUtc().toIso8601String().substring(0, 10);
  return Hmac(sha256, utf8.encode(installKey)).convert(utf8.encode(day)).toString();
}

/// Véhicule vu par des voyageurs.
class CrowdVehicle {
  CrowdVehicle.fromJson(Map<String, dynamic> j)
    : course = j['course'],
      direction = j['sens'],
      prevStop = j['arret_prec'],
      nextStop = j['arret_suiv'],
      progression = (j['progression'] as num).toDouble(),
      lat = (j['lat'] as num).toDouble(),
      lon = (j['lon'] as num).toDouble(),
      sources = j['sources'],
      concordant = j['concordant'] ?? true,
      seenAgoSec = j['vu_il_y_a_s'];

  final String course, prevStop, nextStop;
  final int direction, sources, seenAgoSec;
  final double progression, lat, lon;
  final bool concordant;
}

/// Types de signalement et leurs valeurs, avec leur libellé (mêmes valeurs que le serveur).
const reportDetails = {
  'retard': {'pas_passe': 'Pas encore passé', 'bloque': 'Bloqué', 'retard': 'En retard'},
  'incident': {
    'panne': 'Panne',
    'accident': 'Accident',
    'deviation': 'Déviation',
    'agression': 'Agression',
    'malaise': 'Malaise voyageur',
    'trafic_interrompu': 'Trafic interrompu',
    'colis_suspect': 'Colis suspect',
  },
  'supprime': {'supprime': 'Supprimé'},
  'affluence': {'assis': 'Places assises', 'debout': 'Debout', 'plein': 'Plein'},
};

String reportLabel(String type, String detail) => reportDetails[type]?[detail] ?? detail;

/// Signalement en cours sur une ligne (agrégé par le serveur : nombre de voyageurs distincts).
class CrowdReport {
  CrowdReport.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      type = j['type'],
      detail = j['detail'],
      course = j['course'],
      stop = j['arret'],
      sources = j['sources'],
      first = j['premier'],
      last = j['dernier'];

  final String id, type, detail;
  final String? course, stop;
  final int sources;

  /// Premier et dernier signalement reçus (s UTC).
  final int first, last;

  String get label => reportLabel(type, detail);

  /// Confirmé : signalé par au moins deux voyageurs distincts.
  bool get confirmed => sources >= 2;
}

enum ReportTrust { unconfirmed, confirmed, contradicted }

/// Confiance dans un signalement, et ce qui la fonde (affiché sous le signalement).
typedef ReportAssessment = ({ReportTrust trust, String reason});

/// Retard à partir duquel PRIM ou la position d'un voyageur confirment « pas encore passé » ou
/// « bloqué » (s).
const reportDelayConfirm = 180;

/// Recoupe un signalement avec ce que l'on sait de sa course : temps réel PRIM [rt], position d'un
/// voyageur à bord [seen], arrêt concerné [stopIndex] (dans la variante de la course), perturbation
/// en cours dans l'Info Trafic de la ligne [trafficIncident]. Contredit l'emporte sur confirmé.
ReportAssessment assessReport(
  CrowdReport r, {
  TripRealtime? rt,
  CrowdEstimate? seen,
  int? stopIndex,
  bool trafficIncident = false,
}) {
  final i = stopIndex;
  switch ((r.type, r.detail)) {
    case ('supprime', _):
      if (seen != null) return (trust: ReportTrust.contradicted, reason: 'Contredit : un voyageur est à bord');
      if (rt != null && (rt.cancelled || (i != null && rt.cancelledStops.contains(i)))) {
        return (trust: ReportTrust.confirmed, reason: 'Confirmé par PRIM');
      }
    case ('retard', 'pas_passe'):
      if (i != null && ((seen?.passed(i) ?? false) || (rt?.passed(i) ?? false))) {
        return (trust: ReportTrust.contradicted, reason: 'Contredit : déjà passé à cet arrêt');
      }
      if (seen != null && seen.delaySec >= reportDelayConfirm) {
        return (trust: ReportTrust.confirmed, reason: 'Confirmé par la position d\'un voyageur');
      }
      if (rt != null && i != null && rt.delayAt(i) >= reportDelayConfirm) {
        return (trust: ReportTrust.confirmed, reason: 'Confirmé par PRIM');
      }
    case ('retard', _):
      if (rt != null && i != null && rt.delayAt(i) >= reportDelayConfirm) {
        return (trust: ReportTrust.confirmed, reason: 'Confirmé par PRIM');
      }
    case ('incident', _):
      if (trafficIncident) return (trust: ReportTrust.confirmed, reason: 'Confirmé par l\'Info Trafic');
  }
  return r.confirmed
      ? (trust: ReportTrust.confirmed, reason: 'Confirmé par ${r.sources} voyageurs')
      : (trust: ReportTrust.unconfirmed, reason: '1 signalement, non confirmé');
}

/// État communautaire d'une ligne, daté de sa réception.
class CommunityLine {
  CommunityLine.fromJson(Map<String, dynamic> j, this.receivedAt)
    : vehicles = [for (final v in j['vehicules'] as List) CrowdVehicle.fromJson(v)],
      reports = [for (final r in j['signalements'] as List) CrowdReport.fromJson(r)];

  final DateTime receivedAt;
  final List<CrowdVehicle> vehicles;
  final List<CrowdReport> reports;

  /// Âge actuel de la dernière position d'un véhicule (s).
  int ageOf(CrowdVehicle v, DateTime now) => v.seenAgoSec + now.difference(receivedAt).inSeconds;
}

/// Où en est une course d'après un voyageur à bord : dernier arrêt passé, avancement, et retard
/// déduit en comparant sa position à l'horaire théorique (positif : en retard).
class CrowdEstimate {
  const CrowdEstimate({required this.vehicle, required this.lastStop, required this.delaySec, required this.ageSec});

  final CrowdVehicle vehicle;

  /// Index, dans la variante, du dernier arrêt passé.
  final int lastStop;
  final int delaySec, ageSec;

  int get nextStop => lastStop + 1;

  /// Le véhicule a dépassé l'arrêt [index] (il est au-delà, ou y est arrivé).
  bool passed(int index) => lastStop >= index;

  /// Heure de passage estimée à l'arrêt [index] (s depuis minuit).
  int expectedAt(List<int> times, int index) => times[index] + delaySec;
}

/// Avancement sous lequel un véhicule est considéré à l'arrêt qu'il vient de desservir.
const atStopProgression = 0.05;

/// Estimation pour la course [trip] de [v] à partir du véhicule [c] vu il y a [ageSec] s, à l'heure
/// [nowSec] (s depuis minuit, heure de Paris). Null si ses arrêts ne sont pas dans cette variante.
CrowdEstimate? crowdEstimate(Variant v, int trip, CrowdVehicle c, {required int ageSec, required int nowSec}) {
  var i = -1;
  for (var k = 0; k + 1 < v.stops.length; k++) {
    if (stopId(v, k) == c.prevStop && stopId(v, k + 1) == c.nextStop) {
      i = k;
      break;
    }
  }
  if (i < 0) return null;
  final times = v.trips[trip];
  final scheduled = times[i] + c.progression * (times[i + 1] - times[i]);
  var delay = (nowSec - ageSec - scheduled).round();
  // à l'arrêt (au terminus avant le départ, ou en régulation) : un véhicule en avance attend son
  // heure, il ne repartira pas plus tôt
  if (c.progression < atStopProgression && delay < 0) delay = 0;
  return CrowdEstimate(vehicle: c, lastStop: i, delaySec: delay, ageSec: ageSec);
}

class CommunityException implements Exception {
  CommunityException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CommunityClient {
  CommunityClient({required this.baseUrl, required this.installKey, required this.usage, http.Client? client})
    : _client = client ?? http.Client();

  final String Function() baseUrl;
  final String Function() installKey;
  final RequestUsage usage;
  final http.Client _client;

  static const _timeout = Duration(seconds: 5);

  bool get configured => baseUrl().trim().isNotEmpty;

  Uri _uri(String path, [String? base]) {
    final b = (base ?? baseUrl()).trim();
    return Uri.parse(b.endsWith('/') ? b : '$b/').resolve(path);
  }

  Future<void> sendPosition(Map<String, Object?> message) async {
    usage.count('communauté envoi');
    final r = await _client
        .post(
          _uri('v1/positions'),
          headers: {
            'Content-Type': 'application/json',
            'X-Empreinte': dailyFingerprint(installKey(), DateTime.now().toUtc()),
          },
          body: jsonEncode(message),
        )
        .timeout(_timeout);
    if (r.statusCode != 204) throw CommunityException(_refusal(r));
  }

  Future<void> sendReport(Map<String, Object?> message) async {
    usage.count('communauté signalement');
    final r = await _client
        .post(
          _uri('v1/signalements'),
          headers: {
            'Content-Type': 'application/json',
            'X-Empreinte': dailyFingerprint(installKey(), DateTime.now().toUtc()),
          },
          body: jsonEncode(message),
        )
        .timeout(_timeout);
    if (r.statusCode != 201) throw CommunityException(_refusal(r));
  }

  Future<CommunityLine> line(String lineId) async {
    usage.count('communauté lecture');
    final r = await _client.get(_uri('v1/lignes/${Uri.encodeComponent(lineId)}')).timeout(_timeout);
    if (r.statusCode != 200) throw CommunityException(_refusal(r));
    return CommunityLine.fromJson(jsonDecode(utf8.decode(r.bodyBytes)), DateTime.now());
  }

  /// Vérifie une adresse (celle saisie, avant de l'enregistrer).
  Future<TestResult> test(String url) async {
    if (url.trim().isEmpty) return (ok: false, message: 'Aucune adresse saisie');
    try {
      final r = await _client.get(_uri('sante', url)).timeout(_timeout);
      final ok = r.statusCode == 200 && (jsonDecode(r.body) as Map)['ok'] == true;
      return ok
          ? (ok: true, message: 'Serveur communautaire joignable')
          : (ok: false, message: 'Réponse inattendue (HTTP ${r.statusCode})');
    } catch (e) {
      return (ok: false, message: 'Serveur injoignable ($e)');
    }
  }

  static String _refusal(http.Response r) {
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['message'] != null) return '${j['message']} (HTTP ${r.statusCode})';
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }
}
