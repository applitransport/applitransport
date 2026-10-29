// État de l'appli : catalogue et lignes réels (dépôt local alimenté par l'usine), réglages
// conservés sur l'appareil, temps réel et perturbations PRIM.
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:http/http.dart' as http;

import '../data/package_decoder.dart';
import '../data/prim.dart';
import '../data/realtime.dart';
import '../data/repository.dart';
import '../data/traffic.dart';
import '../data/settings_store.dart';
import 'data.dart';
import 'itineraries.dart';
import '../widgets/locked_field.dart' show TestResult;

class AppState extends ChangeNotifier {
  AppState(this.repo, this.settings, this.usage) {
    _readCatalog();
    prim = PrimClient(token: () => settings.token, usage: usage);
  }

  final Repository repo;
  final SettingsStore settings;
  final RequestUsage usage;
  late final PrimClient prim;

  // --- catalogue -----------------------------------------------------------------
  List<CatalogLine> catalog = [];
  Map<String, String> networks = {};
  Map<String, StopArea> stopAreas = {};
  Map<String, CatalogLine> _byId = {};

  void _readCatalog() {
    final c = repo.catalog;
    catalog = [for (final l in repo.catalogLines) CatalogLine.fromCatalog(l)];
    _byId = {for (final l in catalog) l.id: l};
    networks = c == null ? {} : Map<String, String>.from(c['networks']);
    stopAreas = {for (final a in c?['stop_areas'] ?? const []) a['id'] as String: StopArea.fromJson(a)};
  }

  CatalogLine? line(String id) => _byId[id];

  // --- lignes téléchargées ----------------------------------------------------------
  Set<String> get downloaded => repo.local.keys.toSet();
  Set<String> get updateAvailable => repo.outdated.toSet();
  final Map<String, double> downloading = {}; // progression 0..1 (indéterminée : 0)
  ({int done, int total})? bulk; // « tout télécharger » / « tout mettre à jour » en cours
  String? lastError;
  bool checking = false;

  bool hasSchedules(String id) => repo.local.containsKey(id);

  /// Lignes dont les horaires ne couvrent plus aujourd'hui : à mettre à jour.
  bool isExpired(String id) {
    final until = repo.local[id]?.until;
    final n = now();
    return until != null && until.isBefore(DateTime(n.year, n.month, n.day));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      lastError = null;
      await action();
    } catch (e) {
      lastError = 'Téléchargement impossible : $e';
    }
    notifyListeners();
  }

  Future<void> download(String id) async {
    if (downloading.containsKey(id)) return;
    downloading[id] = 0;
    notifyListeners();
    await _guard(() => repo.download(id));
    downloading.remove(id);
    _timetables.remove(id);
    notifyListeners();
  }

  Future<void> update(String id) => download(id);

  Future<void> _downloadMany(List<String> ids) async {
    if (bulk != null || ids.isEmpty) return;
    bulk = (done: 0, total: ids.length);
    notifyListeners();
    await _guard(
      () => repo.downloadMany(
        ids,
        onProgress: (d, t) {
          bulk = (done: d, total: t);
          notifyListeners();
        },
      ),
    );
    bulk = null;
    _timetables.clear();
    notifyListeners();
  }

  Future<void> downloadAll() => _downloadMany([
    for (final l in catalog)
      if (!hasSchedules(l.id)) l.id,
  ]);

  Future<void> updateAll() => _downloadMany(repo.outdated);

  Future<void> remove(String id) async {
    await repo.remove(id);
    settings.preferred.remove(id);
    _timetables.remove(id);
    await settings.save();
    notifyListeners();
  }

  /// Vérifie le catalogue (requête conditionnelle : rien n'est téléchargé s'il n'a pas changé).
  Future<void> checkUpdates() async {
    if (checking) return;
    checking = true;
    notifyListeners();
    await _guard(() async {
      if (await repo.refreshCatalog()) _readCatalog();
    });
    if (lastError != null) lastError = 'Vérification impossible : ${lastError!.split(' : ').skip(1).join(' : ')}';
    checking = false;
    notifyListeners();
  }

  /// Au démarrage : une vérification par jour au plus (silencieuse si le serveur est injoignable).
  Future<void> dailyCheck() async {
    final last = repo.lastCheck;
    if (repo.catalog == null || last == null || DateTime.now().difference(last).inHours >= 24) {
      await checkUpdates();
    }
  }

  // --- horaires du jour (paquets décodés à la demande, gardés en mémoire) -------------
  final Map<String, (String, DateTime, DemoLine)> _timetables = {};

  DemoLine? timetable(String id) {
    final local = repo.local[id];
    if (local == null) return null;
    final n = now();
    final day = DateTime(n.year, n.month, n.day);
    final cached = _timetables[id];
    if (cached != null && cached.$1 == local.version && cached.$2 == day) return cached.$3;
    final t = timetableFor(repo.readLineSync(id), day);
    _timetables[id] = (local.version, day, t);
    return t;
  }

  /// Horaires du jour des lignes téléchargées parmi [ids].
  List<DemoLine> timetablesOf(Iterable<String> ids) => [
    for (final id in ids)
      if (hasSchedules(id)) timetable(id)!,
  ];

  // --- lignes préférées -------------------------------------------------------------
  List<String> get preferred => settings.preferred;

  void togglePreferred(String id) {
    if (preferred.contains(id)) {
      preferred.remove(id);
    } else if (downloaded.contains(id)) {
      preferred.add(id);
    }
    settings.save();
    notifyListeners();
  }

  /// newIndex est déjà ajusté par ReorderableListView.onReorderItem.
  void reorderPreferred(int oldIndex, int newIndex) {
    preferred.insert(newIndex, preferred.removeAt(oldIndex));
    settings.save();
    notifyListeners();
  }

  // --- réglages ------------------------------------------------------------------
  String get token => settings.token;
  int get autoMinutes => settings.autoMinutes;
  ThemeMode get themeMode => settings.themeMode;
  String get dataUrl => settings.dataUrl;

  void setThemeMode(ThemeMode m) => _set(() => settings.themeMode = m);
  void setToken(String t) => _set(() => settings.token = t.trim());
  void setAutoMinutes(int m) => _set(() => settings.autoMinutes = m);

  void setDataUrl(String url) => _set(() {
    settings.dataUrl = url.trim();
    repo.baseUrl = settings.dataUrl;
  });

  void _set(void Function() change) {
    change();
    settings.save();
    notifyListeners();
  }

  DateTime now() => DateTime.now();

  int nowSec() {
    final n = now();
    return n.hour * 3600 + n.minute * 60 + n.second;
  }

  // --- compteurs de requêtes PRIM (réelles, conservées sur l'appareil) ---------------
  Map<String, int> get requests => {for (final k in primKinds.keys) k: usage.of(k)};

  /// Vérifie un jeton (celui saisi, avant de l'enregistrer) avec la requête la moins coûteuse
  /// (Info Trafic, quota de 4000).
  Future<TestResult> testToken(String candidate) async {
    if (candidate.isEmpty) return (ok: false, message: 'Aucun jeton saisi');
    try {
      final r = await PrimClient(token: () => candidate, usage: usage).lineReports('C01527');
      return (
        ok: true,
        message: 'Jeton valide (${(r['disruptions'] as List? ?? const []).length} perturbation(s) sur la 5104)',
      );
    } catch (e) {
      return (ok: false, message: '$e');
    } finally {
      notifyListeners();
    }
  }

  /// Vérifie qu'une adresse de serveur publie bien un catalogue lisible, sans rien enregistrer.
  Future<TestResult> testDataUrl(String url) async {
    try {
      final base = Uri.parse(url.endsWith('/') ? url : '$url/');
      final r = await http.get(base.resolve('catalog.json.gz')).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        return (ok: false, message: 'Serveur joignable mais catalogue absent (HTTP ${r.statusCode})');
      }
      final c = readPackage(r.bodyBytes);
      final at = DateTime.tryParse(c['generated_at'] ?? '')?.toLocal();
      return (
        ok: true,
        message:
            'Catalogue de ${(c['lines'] as List).length} lignes'
            '${at == null ? '' : ', publié le ${at.day.toString().padLeft(2, '0')}/${at.month.toString().padLeft(2, '0')} '
                      'à ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'}',
      );
    } on FormatException {
      return (ok: false, message: 'Réponse illisible : ce n\'est pas un catalogue AppliTransport');
    } catch (e) {
      return (ok: false, message: 'Serveur injoignable ($e)');
    }
  }

  // --- temps réel PRIM des lignes ---------------------------------------------------
  final Map<String, DateTime> refreshedAt = {}; // dernière réponse reçue, par ligne
  final Map<String, Map<String, TripRealtime>> _realtime = {}; // ligne -> « sens/variante/course »
  String? realtimeError;

  /// Requête « ligne » (cas 1) : toutes les courses en circulation et leurs arrêts restants.
  Future<void> refreshLine(String lineId) async {
    final line = timetable(lineId);
    if (line == null) return;
    await _realtimeGuard(() async {
      final data = await prim.lineTimetable(lineId);
      _realtime[lineId] = matchToTimetable(line, parseEstimatedTimetable(data), _serviceDay(), now(), remaining: true);
      refreshedAt[lineId] = now();
    });
  }

  /// Requête « arrêt » (cas 2) : prochains passages de toutes les lignes à la zone de départ ;
  /// le retard au départ est reporté sur toute la course.
  Future<void> refreshStop(String areaId, Iterable<String> lineIds) async {
    await _realtimeGuard(() async {
      final journeys = parseStopMonitoring(await prim.stopMonitoring(areaId));
      for (final id in lineIds) {
        final line = timetable(id);
        if (line == null) continue;
        (_realtime[id] ??= {}).addAll(matchToTimetable(line, journeys, _serviceDay(), now(), remaining: false));
        refreshedAt[id] = now();
      }
    });
  }

  Future<void> _realtimeGuard(Future<void> Function() action) async {
    try {
      await action();
      realtimeError = null;
    } catch (e) {
      realtimeError = 'Temps réel indisponible : $e';
    }
    notifyListeners();
  }

  DateTime _serviceDay() {
    final n = now();
    return DateTime(n.year, n.month, n.day);
  }

  // --- Info Trafic (perturbations), gardée 15 min par ligne ----------------------------
  final Map<String, (DateTime, List<Disruption>)> _traffic = {};
  static const _trafficTtl = Duration(minutes: 15);

  /// Perturbations connues d'une ligne (null : pas encore chargées).
  List<Disruption>? traffic(String lineId) => _traffic[lineId]?.$2;

  /// Charge les perturbations si elles datent de plus de 15 min ; silencieux en cas d'échec.
  Future<void> loadTraffic(String lineId) async {
    final cached = _traffic[lineId];
    if (token.isEmpty || (cached != null && DateTime.now().difference(cached.$1) < _trafficTtl)) return;
    try {
      _traffic[lineId] = (DateTime.now(), parseLineReports(await prim.lineReports(lineId)));
      notifyListeners();
    } catch (_) {
      // sans réseau ou sans jeton : pas de perturbations affichées, le reste fonctionne
    }
  }

  // --- itinéraires (cas 3, calculateur) -------------------------------------------------
  final Map<String, List<(String, String)>> _addresses = {}; // recherche -> [(libellé, identifiant)]

  /// Adresses correspondant au texte saisi (1 requête « calculateur », mémorisée).
  Future<List<(String, String)>> searchAddresses(String query) async {
    final key = query.toLowerCase();
    if (_addresses.containsKey(key)) return _addresses[key]!;
    try {
      final data = await prim.places(query);
      final out = [
        for (final p in (data['places'] ?? const []) as List)
          if (p['embedded_type'] == 'address') (p['name'] as String, p['id'] as String),
      ];
      notifyListeners();
      return _addresses[key] = out;
    } catch (_) {
      return const [];
    }
  }

  /// Itinéraires (1 requête « calculateur »).
  Future<ItinerarySearch> searchJourneys(String from, String to, DateTime when, {bool arrival = false}) async {
    final data = await prim.journeys(from, to, when, arrival: arrival);
    notifyListeners();
    if (data['error'] != null) {
      throw PrimException((data['error']['message'] ?? data['error']['id'] ?? 'erreur du calculateur').toString());
    }
    return ItinerarySearch.fromNavitia(data, DateTime(when.year, when.month, when.day));
  }

  /// Temps réel des étapes : une requête « arrêt » par zone de montée, chaque étape y est retrouvée
  /// par sa ligne et son heure prévue. Clé : « itinéraire/étape ».
  Future<Map<String, StepRealtime>> itineraryRealtime(ItinerarySearch search) async {
    final byArea = <String, List<(String, Section)>>{};
    for (var j = 0; j < search.journeys.length; j++) {
      final sections = search.journeys[j].sections;
      for (var k = 0; k < sections.length; k++) {
        final s = sections[k];
        if (s.isTransit && s.lineId != null && (s.from?.area ?? '').isNotEmpty) {
          byArea.putIfAbsent(s.from!.area, () => []).add(('$j/$k', s));
        }
      }
    }
    final out = <String, StepRealtime>{};
    await _realtimeGuard(() async {
      for (final e in byArea.entries) {
        final journeys = parseStopMonitoring(await prim.stopMonitoring(e.key));
        for (final (key, s) in e.value) {
          final r = findStep(journeys, s.lineId!, s.baseDep, search.day);
          if (r != null) out[key] = r;
        }
      }
    });
    return out;
  }

  /// Temps réel d'une course, ou null si PRIM n'en a rien dit (horaire théorique).
  TripRealtime? rt(String lineId, int directionId, int variant, int trip) =>
      _realtime[lineId]?[tripKey(directionId, variant, trip)];
}
