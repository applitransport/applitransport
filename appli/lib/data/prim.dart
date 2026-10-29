// Client des API PRIM d'Île-de-France Mobilités, appelées directement par l'appareil avec le jeton
// de l'utilisateur. Chaque ressource est gardée [cacheTtl] (les boutons rafraîchissent toutes les
// 30 s) et chaque type de requête est compté par jour, avec un garde-fou sous le quota de 1000.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const primBase = 'https://prim.iledefrance-mobilites.fr/marketplace';

/// Types de requêtes, chacun avec son quota journalier chez PRIM.
const primKinds = {
  'ligne': 'suivi de ligne',
  'arrêt': 'arrêt → destination, étapes des itinéraires',
  'calculateur': 'recherche d\'itinéraire et d\'adresse',
  'trafic': 'perturbations (Info Trafic)',
};
/// Quotas PRIM par jour (compte gratuit), et garde-fou de l'appli un peu en dessous.
const primQuota = {'ligne': 1000, 'arrêt': 1000, 'calculateur': 1000, 'trafic': 4000};
const primDailyLimit = {'ligne': 900, 'arrêt': 900, 'calculateur': 900, 'trafic': 3600};

class PrimException implements Exception {
  PrimException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Compteurs du jour, conservés sur l'appareil (requests.json).
class RequestUsage {
  RequestUsage(this._file) {
    try {
      final j = jsonDecode(_file.readAsStringSync());
      if (j['day'] == _today()) counts.addAll(Map<String, int>.from(j['counts']));
    } catch (_) {
      // pas encore de fichier, ou fichier d'un autre jour
    }
  }

  final File _file;
  final Map<String, int> counts = {};
  String _day = _today();

  static String _today() => DateTime.now().toIso8601String().substring(0, 10);

  int of(String kind) {
    _rollover();
    return counts[kind] ?? 0;
  }

  void _rollover() {
    if (_day != _today()) {
      _day = _today();
      counts.clear();
    }
  }

  void count(String kind) {
    _rollover();
    if ((counts[kind] ?? 0) >= primDailyLimit[kind]!) {
      throw PrimException('limite de ${primDailyLimit[kind]} requêtes « $kind » atteinte aujourd\'hui');
    }
    counts[kind] = (counts[kind] ?? 0) + 1;
    _file.writeAsStringSync(jsonEncode({'day': _day, 'counts': counts}));
  }
}

class PrimClient {
  PrimClient({required this.token, required this.usage, http.Client? client}) : _client = client ?? http.Client();

  final String Function() token;
  final RequestUsage usage;
  final http.Client _client;
  static const cacheTtl = Duration(seconds: 25);
  final Map<String, (DateTime, Map<String, dynamic>)> _cache = {};

  Future<Map<String, dynamic>> _get(String kind, String path, Map<String, dynamic> params) async {
    final uri = Uri.parse('$primBase/$path').replace(queryParameters: params.isEmpty ? null : params);
    final cached = _cache[uri.toString()];
    if (cached != null && DateTime.now().difference(cached.$1) < cacheTtl) return cached.$2;
    if (token().isEmpty) throw PrimException('saisissez votre jeton PRIM (Configuration › Jeton PRIM)');
    usage.count(kind);
    final http.Response r;
    try {
      r = await _client.get(uri, headers: {'apikey': token(), 'Accept': 'application/json'}).timeout(
            const Duration(seconds: 15),
          );
    } on SocketException {
      throw PrimException('pas de connexion internet');
    } catch (e) {
      throw PrimException('PRIM ne répond pas ($e)');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw PrimException('jeton refusé par PRIM (HTTP ${r.statusCode}) : vérifiez-le et vos abonnements');
    }
    if (r.statusCode == 429) throw PrimException('quota PRIM dépassé (HTTP 429)');
    if (r.statusCode != 200) throw PrimException('PRIM : HTTP ${r.statusCode}');
    final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    _cache[uri.toString()] = (DateTime.now(), data);
    return data;
  }

  /// Requête « ligne » : chaque course en circulation et ses arrêts restants (SIRI EstimatedTimetable).
  Future<Map<String, dynamic>> lineTimetable(String lineCode) =>
      _get('ligne', 'estimated-timetable', {'LineRef': 'STIF:Line::$lineCode:'});

  /// Requête « arrêt » : prochains passages, toutes lignes, à une zone d'arrêt (SIRI StopMonitoring).
  Future<Map<String, dynamic>> stopMonitoring(String areaId) =>
      _get('arrêt', 'stop-monitoring', {'MonitoringRef': 'STIF:StopArea:SP:${areaId.split(':').last}:'});

  /// Perturbations d'une ligne (Info Trafic v2).
  Future<Map<String, dynamic>> lineReports(String lineCode) =>
      _get('trafic', 'v2/navitia/lines/line:IDFM:$lineCode/line_reports', {});

  /// Recherche d'adresses et d'arrêts (calculateur).
  Future<Map<String, dynamic>> places(String query) => _get('calculateur', 'v2/navitia/places', {
        'q': query,
        'type[]': ['address', 'stop_area'],
        'count': '8',
      });

  /// Itinéraires entre deux lieux (identifiants Navitia ou « lon;lat ») ; [arrival] : arriver avant [when].
  Future<Map<String, dynamic>> journeys(String from, String to, DateTime when, {bool arrival = false}) {
    String two(int n) => n.toString().padLeft(2, '0');
    return _get('calculateur', 'v2/navitia/journeys', {
      'from': from,
      'to': to,
      'datetime': '${when.year}${two(when.month)}${two(when.day)}T${two(when.hour)}${two(when.minute)}00',
      'datetime_represents': arrival ? 'arrival' : 'departure',
      'count': '5',
      'data_freshness': 'realtime',
    });
  }
}
