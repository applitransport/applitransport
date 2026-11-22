// État de l'appli : catalogue et lignes réels (dépôt local alimenté par l'usine), réglages
// conservés sur l'appareil, temps réel et perturbations PRIM.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/community.dart';
import '../data/package_decoder.dart';
import '../data/app_update.dart';
import '../data/track.dart' show distanceMeters, walkSpeed;
import '../data/walk_router.dart';
import '../data/places_store.dart';
import '../data/paris_time.dart';
import '../data/prim.dart';
import '../data/realtime.dart';
import '../data/repository.dart';
import '../data/ride_session.dart';
import '../data/settings_store.dart';
import '../data/traffic.dart';
import '../widgets/locked_field.dart' show TestResult;
import 'data.dart';
import 'itineraries.dart';

class AppState extends ChangeNotifier {
  AppState(this.repo, this.settings, this.usage) {
    _readCatalog();
    prim = PrimClient(token: () => settings.token, usage: usage);
    community = CommunityClient(baseUrl: () => settings.communityUrl, installKey: _installKey, usage: usage);
    places = PlacesStore(repo.dir, () => settings.dataUrl.endsWith('/') ? settings.dataUrl : '${settings.dataUrl}/');
  }

  // --- favoris d'Itinéraire (sur l'appareil seulement) ---------------------------------
  List<Map<String, dynamic>> get favPlaces => settings.favPlaces;
  List<Map<String, dynamic>> get favTrips => settings.favTrips;

  /// Enregistre [place] comme favori. Domicile et Travail sont uniques : ils remplacent le précédent.
  void saveFavPlace(String role, String name, Map<String, dynamic> place) {
    if (role != 'autre') settings.favPlaces.removeWhere((f) => f['role'] == role);
    settings.favPlaces.removeWhere((f) => (f['place'] as Map)['ref'] == place['ref'] && f['role'] == role);
    settings.favPlaces.add({'role': role, 'name': name, 'place': place});
    settings.save();
    notifyListeners();
  }

  void renameFavPlace(Map<String, dynamic> fav, String name) {
    fav['name'] = name;
    settings.save();
    notifyListeners();
  }

  void removeFavPlace(Map<String, dynamic> fav) {
    settings.favPlaces.remove(fav);
    settings.save();
    notifyListeners();
  }

  /// Trajet favori : 3 au plus (le plus ancien laisse sa place).
  void saveFavTrip(Map<String, dynamic> from, Map<String, dynamic> to) {
    settings.favTrips.removeWhere(
      (t) => (t['from'] as Map)['ref'] == from['ref'] && (t['to'] as Map)['ref'] == to['ref'],
    );
    settings.favTrips.add({'from': from, 'to': to});
    while (settings.favTrips.length > 3) {
      settings.favTrips.removeAt(0);
    }
    settings.save();
    notifyListeners();
  }

  List<Map<String, dynamic>> get recentTrips => settings.recentTrips;

  /// Recherche lancée : en tête des récentes (une seule fois par trajet, 15 au plus).
  void addRecentTrip(Map<String, dynamic> from, Map<String, dynamic> to) {
    bool same(Map a, Map b) => a['ref'] == b['ref'] && a['kind'] == b['kind'] && a['label'] == b['label'];
    settings.recentTrips.removeWhere((t) => same(t['from'] as Map, from) && same(t['to'] as Map, to));
    settings.recentTrips.insert(0, {'from': from, 'to': to, 'at': DateTime.now().toIso8601String()});
    if (settings.recentTrips.length > 15) settings.recentTrips.removeRange(15, settings.recentTrips.length);
    settings.save();
    notifyListeners();
  }

  void removeRecentTrip(Map<String, dynamic> trip) {
    settings.recentTrips.remove(trip);
    settings.save();
    notifyListeners();
  }

  void clearRecentTrips() {
    settings.recentTrips.clear();
    settings.save();
    notifyListeners();
  }

  void removeFavTrip(Map<String, dynamic> trip) {
    settings.favTrips.remove(trip);
    settings.save();
    notifyListeners();
  }

  /// Lieux d'Île-de-France (OpenStreetMap), téléchargés à la demande.
  late final PlacesStore places;

  /// Téléchargement des lieux en cours : progression de 0 à 1 (null : rien en cours).
  double? placesProgress;
  bool placesBusy = false;
  String? placesError;

  Future<void> downloadPlaces() async {
    if (placesBusy) return;
    placesBusy = true;
    placesProgress = 0;
    placesError = null;
    notifyListeners();
    try {
      await places.download(
        onProgress: (got, total) {
          placesProgress = total == null || total == 0 ? null : got / total;
          notifyListeners();
        },
      );
    } catch (e) {
      placesError = '$e';
    }
    placesProgress = null;
    placesBusy = false;
    notifyListeners();
  }

  Future<void> removePlaces() async {
    await places.remove();
    notifyListeners();
  }

  final Repository repo;
  final SettingsStore settings;
  final RequestUsage usage;
  late final PrimClient prim;
  late final CommunityClient community;

  String _installKey() {
    if (settings.installKey.isEmpty) {
      settings.installKey = newInstallKey();
      settings.save();
    }
    return settings.installKey;
  }

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
    return until != null && parisMidnight(until).isBefore(parisMidnight(n));
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

  /// Au démarrage : vérification des horaires une fois par jour au plus (silencieuse sans réseau)
  /// et mise à jour automatique des lignes téléchargées dont les horaires ont changé (quelques Ko
  /// chacune) ; puis recherche d'une nouvelle version de l'appli.
  Future<void> dailyCheck() async {
    final last = repo.lastCheck;
    if (repo.catalog == null || last == null || DateTime.now().difference(last).inHours >= 24) {
      await checkUpdates();
      if (lastError == null && repo.outdated.isNotEmpty) await updateAll();
    }
    await checkAppUpdate();
    // lieux installés : nouvelle base chaque semaine
    final d = places.date;
    if (places.installed && (d == null || DateTime.now().difference(d).inDays >= 7) && await places.outdated()) {
      await downloadPlaces();
    }
  }

  // --- nouvelle version de l'appli (Releases GitHub) -------------------------------------
  /// Dernière Release GitHub. Version de debug seulement : `--dart-define=UPDATE_API=…` pour tester la mise
  /// à jour avec une Release factice servie sur le PC (`adb reverse`).
  static const releasesApi = kDebugMode && String.fromEnvironment('UPDATE_API') != ''
      ? String.fromEnvironment('UPDATE_API')
      : 'https://api.github.com/repos/applitransport/applitransport/releases/latest';

  /// Dernière version publiée, si elle est plus récente que celle installée.
  ///  [url] : l'APK du processeur du téléphone (ou la page de la Release) ; [sha256] : son empreinte
  /// publiée par GitHub ; [page] : la page de la Release.
  ({String version, String url, String? sha256, bool apk, String page})? appUpdate;

  /// Installation en cours : avancement du téléchargement (0..1), ou null.
  double? updateProgress;

  /// Dernier échec de l'installation, ou message (« autorisez… »).
  String? updateMessage;

  static const _updateChannel = MethodChannel('fr.applitransport/update');
  bool _updateHandler = false;

  /// Télécharge, vérifie et installe la nouvelle version par l'appli elle-même (Android demande une
  /// confirmation). Sans APK : page de la Release.
  Future<bool> installUpdate() async {
    final u = appUpdate;
    if (u == null || !u.apk) return false;
    if (!_updateHandler) {
      _updateHandler = true;
      _updateChannel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'progress':
            updateProgress = (call.arguments as num).toDouble();
          case 'done':
            updateProgress = null;
            updateMessage = call.arguments == null ? null : 'Mise à jour impossible : ${call.arguments}';
        }
        notifyListeners();
      });
    }
    try {
      final r = await _updateChannel.invokeMethod<String>('install', {'url': u.url, 'sha256': u.sha256});
      if (r == 'permission') {
        updateMessage = 'Autorisez AppliTransport à installer des applications, puis revenez appuyer sur Installer.';
      } else {
        updateMessage = null;
        updateProgress = 0;
      }
      notifyListeners();
      return true;
    } catch (e) {
      updateMessage = 'Mise à jour impossible : $e';
      notifyListeners();
      return false;
    }
  }

  /// Lit la dernière Release : version (tag « v1.1.0 ») et lien de l'APK joint. Silencieux sans réseau.
  Future<void> checkAppUpdate() async {
    try {
      final r = await http
          .get(Uri.parse(releasesApi), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final latest = (j['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), '');
      final installed = (await PackageInfo.fromPlatform()).version;
      if (!isNewerVersion(latest, installed)) return;
      final apk = pickApk([
        for (final a in (j['assets'] ?? const []) as List)
          if ((a['name'] as String).endsWith('.apk'))
            (
              a['name'] as String,
              (
                url: a['browser_download_url'] as String,
                // « sha256:… » fourni par GitHub pour chaque fichier joint
                sha256: (a['digest'] as String?)?.replaceFirst('sha256:', ''),
              ),
            ),
      ], await deviceAbis());
      final page = j['html_url'] as String;
      appUpdate = (version: latest, url: apk?.url ?? page, sha256: apk?.sha256, apk: apk != null, page: page);
      notifyListeners();
    } catch (_) {
      // pas de réseau ou réponse inattendue : on réessaiera à la prochaine ouverture
    }
  }

  /// Types de processeur du téléphone (« arm64-v8a », « armeabi-v7a »…), du préféré au moins bon.
  static Future<List<String>> deviceAbis() async {
    try {
      return (await const MethodChannel('fr.applitransport/device').invokeListMethod<String>('abis')) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  // --- horaires du jour (paquets décodés à la demande, gardés en mémoire) -------------
  final Map<String, (String, DateTime, DemoLine)> _timetables = {};

  DemoLine? timetable(String id) {
    final local = repo.local[id];
    if (local == null) return null;
    final n = now();
    final day = parisMidnight(n);
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

  /// Les deux lignes de l'accueil : celles choisies (si toujours favorites et téléchargées), complétées
  /// par les premières favorites.
  List<String> get homeLines {
    final fav = preferred.where(hasSchedules).toList();
    final out = [
      for (final id in settings.homeLines)
        if (fav.contains(id)) id,
    ];
    for (final id in fav) {
      if (out.length >= 2) break;
      if (!out.contains(id)) out.add(id);
    }
    return out.take(2).toList();
  }

  /// Remplace la ligne [old] de l'accueil par [id].
  void setHomeLine(String old, String id) {
    final cur = homeLines;
    final i = cur.indexOf(old);
    if (i < 0) return;
    cur[i] = id;
    settings.homeLines = cur;
    settings.save();
    notifyListeners();
  }

  // Le sens est enregistré par son identifiant (0 ou 1 du GTFS), pas par sa place dans la liste du jour :
  // un jour où la ligne ne circule que dans un sens, la liste n'en a qu'un et les places changent.

  /// Identifiant du sens à la place [index] des horaires du jour de [line].
  int _dirId(String? line, int index) {
    final ds = line == null ? null : timetable(line)?.directions;
    return ds == null ? index : dirIdAt(ds, index);
  }

  /// Place du sens [id] dans les horaires du jour de [line], ou null s'il ne circule pas ce jour-là.
  int? _dirIndex(String line, int id) {
    final ds = timetable(line)?.directions;
    return ds == null ? null : dirIndexOf(ds, id);
  }

  /// Sens (place dans les horaires du jour, null s'il ne circule pas aujourd'hui) et arrêt retenus pour une
  /// ligne (null : jamais consultée).
  ({int? dir, String stop})? lineStop(String lineId) {
    // ligne jamais mémorisée : la dernière sélection du suivi de ligne, si c'est elle
    final m =
        settings.lineStops[lineId] ??
        (settings.lastLine == lineId && settings.lastStop != null
            ? {'dir': settings.lastDir, 'stop': settings.lastStop}
            : null);
    if (m == null || m['stop'] == null) return null;
    return (dir: _dirIndex(lineId, (m['dir'] as num?)?.toInt() ?? 0), stop: m['stop'] as String);
  }

  /// Actualiser de l'accueil : serveur communautaire pour chaque ligne préférée, PRIM « arrêt » une fois
  /// par zone d'arrêt (une requête donne toutes les lignes qui y passent), perturbations (15 min).
  Future<void> refreshHome() async {
    final byArea = <String, Set<String>>{};
    final jobs = <Future<void>>[];
    for (final id in preferred.where(hasSchedules)) {
      jobs.add(refreshCommunity(id));
      jobs.add(loadTraffic(id));
      final ls = lineStop(id), l = timetable(id), dir = ls?.dir;
      if (ls == null || l == null || dir == null) continue;
      final stop = l.directions[dir].stops.where((s) => s.name == ls.stop).firstOrNull;
      if (stop != null && stop.area.isNotEmpty) (byArea[stop.area] ??= {}).add(id);
    }
    if (token.isNotEmpty) {
      for (final e in byArea.entries) {
        jobs.add(refreshStop(e.key, e.value));
      }
    }
    await Future.wait(jobs);
  }

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

  String get communityUrl => settings.communityUrl;
  bool get communityShow => settings.communityShow;
  bool get communityShare => settings.communityShare;
  void setCommunityUrl(String url) => _set(() => settings.communityUrl = url.trim());
  void setCommunityShow(bool v) => _set(() => settings.communityShow = v);
  void setCommunityShare(bool v) => _set(() => settings.communityShare = v);
  bool get showMyPosition => settings.showMyPosition;

  /// Dernière sélection (ligne, sens, arrêt), partagée par le suivi de ligne et l'état de la ligne. [dir] :
  /// place du sens dans les horaires du jour (le premier s'il ne circule pas aujourd'hui).
  ({String? line, int dir, String? stop}) get lastSelection {
    final line = settings.lastLine;
    return (
      line: line,
      dir: line == null ? settings.lastDir : _dirIndex(line, settings.lastDir) ?? 0,
      stop: settings.lastStop,
    );
  }

  /// [dirIndex] : place du sens dans les horaires du jour (enregistré par son identifiant).
  void rememberSelection(String? line, int dirIndex, {String? stop}) {
    final dir = _dirId(line, dirIndex);
    // changer de ligne ou de sens oublie l'arrêt ; l'état de la ligne ne choisit pas d'arrêt
    final same = line == settings.lastLine && dir == settings.lastDir;
    if (same && stop == null && settings.lastStop != null) return;
    settings
      ..lastLine = line
      ..lastDir = dir
      ..lastStop = stop ?? (same ? settings.lastStop : null);
    // sens et arrêt retenus pour cette ligne (« Mes lignes » de l'accueil)
    if (line != null && settings.lastStop != null) settings.lineStops[line] = {'dir': dir, 'stop': settings.lastStop};
    settings.save();
  }

  void setShowMyPosition(bool v) => _set(() => settings.showMyPosition = v);

  /// Compteurs des requêtes communautaires du jour (envoi, lecture).
  Map<String, int> get communityRequests => {for (final k in communityKinds.keys) k: usage.of(k)};

  void setDataUrl(String url) => _set(() {
    settings.dataUrl = url.trim();
    repo.baseUrl = settings.dataUrl;
  });

  void _set(void Function() change) {
    change();
    settings.save();
    notifyListeners();
  }

  /// Heure de Paris, indépendante du fuseau de l'appareil (voir data/paris_time.dart).
  DateTime now() => parisNow();

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
      final generated = DateTime.tryParse(c['generated_at'] ?? '');
      final at = generated == null ? null : parisTime(generated);
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

  // --- données communautaires (véhicules vus par les voyageurs) ------------------------
  final Map<String, CommunityLine> communityLines = {};

  /// Trajet « à bord » en cours (ou terminé, tant que son bandeau n'est pas fermé) : il continue en
  /// changeant d'écran.
  RideSession? ride;

  void setRide(RideSession? r) {
    ride?.removeListener(notifyListeners);
    ride?.dispose();
    ride = r?..addListener(notifyListeners);
    notifyListeners();
  }

  /// Envoie un signalement (bloqué, incident, affluence, supprimé, pas encore passé) puis relit la
  /// ligne pour l'afficher. Lève une erreur lisible en cas de refus.
  Future<void> sendReport(String lineId, String type, String detail, {String? course, String? stop}) async {
    await community.sendReport({
      'v': 1,
      'session': newSessionId(),
      'ligne': lineId,
      'type': type,
      'detail': detail,
      'course': ?course,
      'arret': ?stop,
      't': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    await refreshCommunity(lineId);
  }

  /// Dernière lecture réussie du serveur communautaire, par ligne.
  final Map<String, DateTime> communityAt = {};

  /// Lit l'état communautaire d'une ligne. Serveur absent ou en panne : rien n'est affiché,
  /// l'appli continue avec PRIM seul.
  Future<void> refreshCommunity(String lineId) async {
    if (!settings.communityShow || !community.configured) return;
    try {
      communityLines[lineId] = await community.line(lineId);
      communityAt[lineId] = DateTime.now();
    } catch (_) {
      communityLines.remove(lineId);
    }
    notifyListeners();
  }

  /// Intervalle minimal entre deux requêtes PRIM « ligne » lancées par Actualiser.
  static const primLineInterval = Duration(seconds: 30);
  final Map<String, DateTime> _primTriedAt = {};

  /// Actualiser (suivi de ligne, état de la ligne) : serveur communautaire à chaque appui (gratuit),
  /// PRIM seulement si sa dernière tentative pour cette ligne a plus de 30 s (quota).
  Future<void> refreshLineAll(String lineId) {
    final last = _primTriedAt[lineId];
    final askPrim = last == null || DateTime.now().difference(last) >= primLineInterval;
    if (askPrim) _primTriedAt[lineId] = DateTime.now();
    return Future.wait([refreshCommunity(lineId), if (askPrim) refreshLine(lineId)]);
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
    return parisMidnight(n);
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

  /// Chemins à pied et adresses proches (IGN), quand le calculateur ne trouve pas de chemin.
  final walkRouter = WalkRouter();

  Future<ItinerarySearch> _journeys(String from, String to, DateTime when, bool arrival) async {
    final data = await prim.journeys(from, to, when, arrival: arrival);
    notifyListeners();
    if (data['error'] != null) {
      throw PrimException((data['error']['message'] ?? data['error']['id'] ?? 'erreur du calculateur').toString());
    }
    return ItinerarySearch.fromNavitia(data, parisMidnight(when));
  }

  /// « lon;lat » (lieu, position) → coordonnées ; null pour un identifiant d'arrêt ou d'adresse.
  static LatLng? _coordOf(String id) {
    final m = RegExp(r'^(-?[\d.]+);(-?[\d.]+)$').firstMatch(id);
    return m == null ? null : LatLng(double.parse(m[2]!), double.parse(m[1]!));
  }

  /// Itinéraires (1 requête « calculateur »). Si le calculateur ne rattache pas un point aux rues (lieu
  /// au milieu d'un grand terrain : il ne propose alors qu'un trait « à vol d'oiseau »), nouvelle
  /// requête depuis/vers l'adresse la plus proche, et derniers mètres ajoutés à pied. Les tronçons
  /// « à vol d'oiseau » restants reçoivent un vrai chemin à pied (IGN) quand c'est possible.
  Future<ItinerarySearch> searchJourneys(String from, String to, DateTime when, {bool arrival = false}) async {
    var search = await _journeys(from, to, when, arrival);
    final a = _coordOf(from), b = _coordOf(to);
    if ((a != null || b != null) && search.journeys.every((j) => j.onlyCrowFly)) {
      final first = search.journeys.firstOrNull;
      final a2 = a == null ? null : await walkRouter.nearestAddress(a);
      final b2 = b == null ? null : await walkRouter.nearestAddress(b);
      if (a2 != null || b2 != null) {
        try {
          final again = await _journeys(
            a2 == null ? from : '${a2.longitude};${a2.latitude}',
            b2 == null ? to : '${b2.longitude};${b2.latitude}',
            when,
            arrival,
          );
          if (again.journeys.any((j) => !j.onlyCrowFly)) {
            for (final j in again.journeys) {
              // raccord vers le vrai point, sauf s'il est tout proche (bruit dans la liste des étapes)
              if (a != null && a2 != null && j.sections.isNotEmpty && distanceMeters(a, a2) > 60) {
                final d = (distanceMeters(a, a2) / walkSpeed).round();
                final place = first?.sections.first.from ?? Place('Départ', a);
                j.sections.insert(
                  0,
                  Section.walk(
                    place,
                    j.sections.first.from ?? Place('', a2),
                    [a, a2],
                    dep: j.dep - d,
                    duration: d,
                    crowFly: true,
                  ),
                );
                j.dep -= d;
              }
              if (b != null && b2 != null && j.sections.isNotEmpty && distanceMeters(b2, b) > 60) {
                final d = (distanceMeters(b2, b) / walkSpeed).round();
                final place = first?.sections.last.to ?? Place('Arrivée', b);
                j.sections.add(
                  Section.walk(
                    j.sections.last.to ?? Place('', b2),
                    place,
                    [b2, b],
                    dep: j.arr,
                    duration: d,
                    crowFly: true,
                  ),
                );
                j.arr += d;
              }
            }
            search = again;
          }
        } catch (_) {
          // seconde requête impossible : on garde la première réponse
        }
      }
    }
    await _walkPaths(search);
    return search;
  }

  /// Tronçons « à vol d'oiseau » : chemin à pied de l'IGN à la place du trait direct, si disponible.
  Future<void> _walkPaths(ItinerarySearch search) async {
    final paths = <String, Future<WalkPath?>>{};
    final todo = [
      for (final j in search.journeys)
        for (final s in j.sections)
          if (s.crowFly && s.from != null && s.to != null && distanceMeters(s.from!.pos, s.to!.pos) > 15) s,
    ];
    for (final s in todo) {
      final key = '${s.from!.pos}>${s.to!.pos}';
      final p = await paths.putIfAbsent(key, () => walkRouter.path(s.from!.pos, s.to!.pos));
      if (p != null) {
        s.shape = p.shape;
        s.crowFly = false;
      }
    }
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

/// « 1.10.0 » est-elle plus récente que « 1.9.2 » ? (comparaison numérique, partie par partie)
bool isNewerVersion(String candidate, String installed) {
  List<int> parts(String v) => [for (final p in v.split('.')) int.tryParse(p.split(RegExp(r'[^0-9]')).first) ?? 0];
  final a = parts(candidate), b = parts(installed);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
