// Cas 3 : itinéraire avec correspondances (calculateur IDFM, internet nécessaire).
// Départ / arrivée : ma position (GPS), un arrêt (catalogue, sans requête) ou une adresse (calculateur).
// Rechercher = 1 requête « calculateur » ; Actualiser = 1 requête « arrêt » par arrêt de montée,
// qui corrige chaque étape en transport (le calculateur n'applique le temps réel qu'à certains trains).
import 'dart:async';

import 'package:flutter/cupertino.dart'
    show CupertinoDatePicker, CupertinoDatePickerMode, CupertinoTheme, CupertinoThemeData, CupertinoTextThemeData;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../data/geo.dart';
import 'package:latlong2/latlong.dart';

import '../data/geocoder.dart';
import '../data/places_store.dart' show normalizeWords;
import '../data/location.dart';
import '../data/realtime.dart';
import '../data/track.dart' show distanceMeters;
import '../data/traffic.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/itineraries.dart';
import '../poc/nearby.dart';
import '../poc/position.dart';
import '../widgets/line_badge.dart';
import '../widgets/place_preview.dart';
import '../widgets/refresh_controls.dart';
import 'line_screen.dart';
import 'walk_nav_screen.dart';

IconData modeIcon(String? mode) {
  final m = (mode ?? '').toLowerCase();
  if (m.contains('bus')) return Icons.directions_bus;
  if (m.contains('tram')) return Icons.tram;
  if (m.contains('métro') || m.contains('metro')) return Icons.subway;
  return Icons.train;
}

/// Lieu choisi : [ref] = identifiant pour le calculateur (null : ma position, résolue au moment de chercher).
/// Accent des favoris (comme l'accueil).
const _favAmber = Color(0xFFF2A541);

class PlaceChoice {
  const PlaceChoice(this.label, this.detail, this.ref, this.kind, {this.near, this.favRole});
  final String label, detail;
  final String? ref;
  final String kind; // position, arret, lieu, entreprise, adresse

  /// Lieu favori : domicile, travail ou autre (null : pas un favori).
  final String? favRole;

  Map<String, dynamic> toJson() => {'label': label, 'detail': detail, 'ref': ref, 'kind': kind, 'near': near};

  static PlaceChoice fromJson(Map j, {String? name, String? favRole}) => PlaceChoice(
    name ?? j['label'] as String,
    name == null
        ? j['detail'] as String? ?? ''
        : [j['label'], j['detail']].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
    j['ref'] as String?,
    j['kind'] as String? ?? 'lieu',
    near: j['near'] as String?,
    favRole: favRole,
  );

  /// Lieu favori enregistré → proposition (son nom, puis le lieu en détail).
  static PlaceChoice fromFav(Map<String, dynamic> f) =>
      fromJson(f['place'] as Map, name: f['name'] as String, favRole: f['role'] as String);

  /// Lieu ou adresse : « Arrêt le plus proche : Lycée Descartes (250 m) ».
  final String? near;
  static const myPosition = PlaceChoice('Ma position', 'GPS du téléphone', null, 'position');
}

/// Longueur d'un tracé à pied (m), 0 s'il n'y en a pas.
double walkLength(List<LatLng> shape) {
  var m = 0.0;
  for (var i = 1; i < shape.length; i++) {
    m += distanceMeters(shape[i - 1], shape[i]);
  }
  return m;
}

/// Heures d'un itinéraire corrigées du temps réel de chaque étape, et correspondances compromises.
class _Timed {
  _Timed(this.journey, this.index, Map<String, StepRealtime> rt) {
    final j = journey;
    var lastDelay = 0;
    for (var k = 0; k < j.sections.length; k++) {
      final s = j.sections[k];
      final r = s.isTransit ? rt['$index/$k'] : null;
      if (s.isTransit) {
        realtime[k] = r;
        lastDelay = r?.delay ?? 0;
      }
      final d = s.isTransit ? (r?.delay ?? 0) : 0;
      dep.add(s.dep + d);
      arr.add(s.arr + (s.isTransit ? d : lastDelay));
    }
    int? prevArr;
    var walk = 0;
    for (var k = 0; k < j.sections.length; k++) {
      final s = j.sections[k];
      if (s.type == 'transfer') walk += s.duration;
      if (!s.isTransit) continue;
      if (realtime[k]?.cancelled == true) brokenAt ??= k;
      if (prevArr != null && prevArr + walk > dep[k]) brokenAt ??= k;
      prevArr = arr[k];
      walk = 0;
    }
  }

  final Journey journey;
  final int index;
  final List<int> dep = [], arr = [];
  final Map<int, StepRealtime?> realtime = {};
  int? brokenAt; // étape supprimée, ou correspondance ratée à cause d'un retard

  int get start => dep.first;
  int get end => arr.last;
}

class ItineraryScreen extends StatefulWidget {
  const ItineraryScreen({super.key, required this.app, this.from, this.to, this.toQuery});
  final AppState app;

  /// Lieux préremplis (depuis « Quelle ligne prendre ? » quand il n'y a pas de ligne directe).
  final PlaceChoice? from, to;

  /// Texte d'arrivée à chercher (depuis « Quelle ligne prendre ? » quand ce n'est pas un arrêt) :
  /// saisi dans le champ, suggestions ouvertes.
  final String? toQuery;

  @override
  State<ItineraryScreen> createState() => _ItineraryScreenState();
}

class _ItineraryScreenState extends State<ItineraryScreen> {
  PlaceChoice? _from, _to;
  int _when = 0; // 0 maintenant, 1 partir à, 2 arriver avant
  TimeOfDay? _time;
  ItinerarySearch? _search;
  bool _searching = false;
  String? _error;
  final _realtime = ValueNotifier<Map<String, StepRealtime>>({});
  DateTime? _refreshedAt;
  Key _fieldsKey = UniqueKey();
  Timer? _ticker;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _from = widget.from;
    _to = widget.to;
    // dernière position connue du téléphone, si la localisation est déjà autorisée (pas de demande)
    Geolocator.checkPermission()
        .then((perm) async {
          if (perm == LocationPermission.always || perm == LocationPermission.whileInUse) {
            final p = await Geolocator.getLastKnownPosition();
            if (p != null) _lastKnown = LatLng(p.latitude, p.longitude);
          }
        })
        .catchError((_) {});
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _realtime.dispose();
    super.dispose();
  }

  Future<String> _resolve(PlaceChoice p) async {
    if (p.ref != null) return p.ref!;
    await ensureLocationPermission();
    final pos = await Geolocator.getCurrentPosition();
    return '${pos.longitude};${pos.latitude}';
  }

  Future<void> _run() async {
    if (_from == null || _to == null) {
      setState(() => _error = 'Choisissez un départ et une arrivée dans les propositions.');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    app.addRecentTrip(_from!.toJson(), _to!.toJson());
    try {
      final n = app.now();
      final t = _time ?? TimeOfDay.fromDateTime(n);
      final when = _when == 0 ? n : DateTime.utc(n.year, n.month, n.day, t.hour, t.minute); // heure de Paris
      final s = await app.searchJourneys(await _resolve(_from!), await _resolve(_to!), when, arrival: _when == 2);
      setState(() {
        _search = s;
        _realtime.value = {};
        _refreshedAt = null;
        if (s.journeys.isEmpty) _error = 'Aucun itinéraire trouvé.';
      });
    } catch (e) {
      setState(() => _error = 'Recherche impossible : $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _refresh() async {
    final s = _search;
    if (s == null) return;
    final rt = await app.itineraryRealtime(s);
    if (!mounted || s != _search) return;
    _realtime.value = rt;
    setState(() => _refreshedAt = app.now());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        appBar: AppBar(
          title: const Text('Itinéraire', style: TextStyle(fontWeight: FontWeight.w700)),
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              _form(context),
              if (_search != null && _search!.journeys.isNotEmpty)
                RefreshControls(
                  key: ValueKey(_search),
                  onRefresh: _refresh,
                  single: true, // Actualiser seul, comme sur les autres écrans
                  manualCooldown: const Duration(seconds: 10),
                  autoMinutes: app.autoMinutes,
                  lastRefresh: _refreshedAt,
                  now: app.now,
                  error: app.realtimeError,
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const Divider(height: 1),
              Expanded(child: _results(context)),
            ],
          ),
        ),
      ),
    );
  }

  /// Carte blanche arrondie et ombrée (style de l'accueil).
  BoxDecoration _cardDeco(BuildContext context, {double radius = 22}) => BoxDecoration(
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: const [
      BoxShadow(color: Color(0x0F14212B), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x1214212B), blurRadius: 18, offset: Offset(0, 6)),
    ],
  );

  Widget _form(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = _time ?? TimeOfDay.fromDateTime(app.now());
    Future<void> pickWhen(int w) async {
      if (w != 0) {
        final t = await _pickTime(context, time, w == 2 ? 'Arriver à' : 'Partir à');
        if (t == null) return;
        _time = t;
      }
      setState(() => _when = w);
    }

    Widget whenChip(int w, String label) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(_when == w && w != 0 ? '$label ${time.format(context)}' : label),
        selected: _when == w,
        showCheckmark: false,
        shape: const StadiumBorder(),
        onSelected: (_) => pickWhen(w),
      ),
    );
    return Padding(
      key: _fieldsKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        children: [
          // départ et arrivée dans une seule carte, reliés par un pointillé
          Container(
            decoration: _cardDeco(context),
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: Column(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.primary, width: 3),
                        ),
                      ),
                      for (var i = 0; i < 6; i++)
                        Container(
                          width: 2,
                          height: 4,
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          color: scheme.outlineVariant,
                        ),
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: _favAmber, borderRadius: BorderRadius.circular(3)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    children: [
                      _PlaceField(
                        app: app,
                        near: () => _quickPos(_to),
                        label: 'Départ',
                        icon: Icons.trip_origin,
                        value: _from,
                        onSet: (p) => setState(() {
                          _from = p;
                          _search = null; // lieu changé : l'aperçu remplace les anciens résultats
                        }),
                      ),
                      const SizedBox(height: 8),
                      _PlaceField(
                        app: app,
                        near: () => _quickPos(_from),
                        label: 'Arrivée',
                        icon: Icons.flag,
                        value: _to,
                        onSet: (p) => setState(() {
                          _to = p;
                          _search = null; // lieu changé : l'aperçu remplace les anciens résultats
                        }),
                        initialText: _to == null ? widget.toQuery : null,
                      ),
                    ],
                  ),
                ),
                IconButton.outlined(
                  tooltip: 'Inverser départ et arrivée',
                  icon: const Icon(Icons.swap_vert),
                  onPressed: () => setState(() {
                    final f = _from;
                    _from = _to;
                    _to = f;
                    _fieldsKey = UniqueKey();
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [whenChip(0, 'Maintenant'), whenChip(1, 'Partir à'), whenChip(2, 'Arriver à')]),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _searching ? null : _run,
                  icon: _searching
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text('Rechercher'),
                ),
              ),
              // trajet favori : départ et arrivée choisis
              if (_from != null && _to != null)
                IconButton(
                  tooltip: _favTrip == null ? 'Ajouter aux trajets favoris' : 'Retirer des trajets favoris',
                  icon: Icon(
                    _favTrip == null ? Icons.star_border : Icons.star,
                    color: _favTrip == null ? null : _favAmber,
                  ),
                  onPressed: () {
                    final f = _favTrip;
                    if (f != null) {
                      app.removeFavTrip(f);
                    } else {
                      app.saveFavTrip(_from!.toJson(), _to!.toJson());
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Trajet ajouté aux favoris (3 au plus)')));
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  // --- trajets favoris et arrêts proches (page vide) ----------------------------------
  static bool _same(Map a, PlaceChoice? b) => b != null && a['ref'] == b.ref && a['kind'] == b.kind;

  Map<String, dynamic>? get _favTrip =>
      app.favTrips.where((t) => _same(t['from'] as Map, _from) && _same(t['to'] as Map, _to)).firstOrNull;

  /// Nom affiché d'un lieu d'un trajet favori : son nom de favori s'il en a un (« Domicile »).
  PlaceChoice _favOrPlace(Map p) {
    final f = app.favPlaces.where((f) => (f['place'] as Map)['ref'] == p['ref'] && p['ref'] != null).firstOrNull;
    return f != null ? PlaceChoice.fromFav(f) : PlaceChoice.fromJson(p);
  }

  void _useTrip(Map<String, dynamic> t, {bool reverse = false}) {
    final a = _favOrPlace(t['from'] as Map), b = _favOrPlace(t['to'] as Map);
    setState(() {
      _from = reverse ? b : a;
      _to = reverse ? a : b;
      _search = null;
      _fieldsKey = UniqueKey(); // recrée les champs avec les nouvelles valeurs
    });
  }

  bool _allRecent = false;

  /// « il y a 5 min », « il y a 2 h », « hier », « le 12/11 ».
  static String _ago(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'à l\'instant';
    if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
    if (d.inHours < 24) return 'il y a ${d.inHours} h';
    if (d.inDays == 1) return 'hier';
    return 'le ${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}';
  }

  bool _isFavTrip(Map t) => app.favTrips.any(
    (f) =>
        (f['from'] as Map)['ref'] == (t['from'] as Map)['ref'] &&
        (f['to'] as Map)['ref'] == (t['to'] as Map)['ref'] &&
        (f['from'] as Map)['kind'] == (t['from'] as Map)['kind'] &&
        (f['to'] as Map)['kind'] == (t['to'] as Map)['kind'],
  );

  List<(StopArea, double)>? _nearby;
  bool _locating = false;
  String? _nearbyError;

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _nearbyError = null;
    });
    final me = await currentPosition(ask: true);
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (me == null) {
        _nearbyError = 'Position introuvable : localisation désactivée ou refusée, ou pas de signal GPS.';
      } else {
        _lastKnown = me;
        _nearby = nearbyAreas(app.stopAreas.values, me);
      }
    });
  }

  /// Page vide : trajets favoris, puis arrêts près de moi (toucher un arrêt le met en départ).
  Widget _home(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final nearby = _nearby;
    PlaceChoice icon(Map p) => _favOrPlace(p);
    Widget label(PlaceChoice p) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p.favRole != null) Icon(_PlaceFieldState.favIcon(p.favRole), size: 16, color: Colors.amber.shade700),
        const SizedBox(width: 2),
        Flexible(child: Text(p.label, overflow: TextOverflow.ellipsis)),
      ],
    );
    final scheme = Theme.of(context).colorScheme;
    final section = t.titleMedium?.copyWith(fontWeight: FontWeight.w700);
    final recent = [
      for (final r in app.recentTrips)
        if (!_isFavTrip(r)) r,
    ];
    final trips = app.favTrips.reversed.toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        if (trips.isNotEmpty) ...[
          Text('Trajets favoris', style: section),
          const SizedBox(height: 8),
          // en tuiles : la première aux couleurs de l'appli ; ⇅ pour le sens inverse, appui long pour retirer
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: trips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final trip = trips[i];
                final first = i == 0;
                final fg = first ? scheme.onPrimary : scheme.onSurface;
                final a = icon(trip['from'] as Map), b = icon(trip['to'] as Map);
                return SizedBox(
                  width: 220,
                  child: Material(
                    color: first ? scheme.primary : scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _useTrip(trip),
                      onLongPress: () => app.removeFavTrip(trip),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    a.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15),
                                  ),
                                  Text(
                                    '→ ${b.label}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: fg),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Sens inverse',
                              color: fg,
                              icon: const Icon(Icons.swap_vert),
                              onPressed: () => _useTrip(trip, reverse: true),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 18),
        ],
        // recherches récentes (hors trajets favoris), les 3 dernières puis toutes sur demande
        if (recent.isNotEmpty) ...[
          Row(
            children: [
              Expanded(child: Text('Recherches récentes', style: section)),
              TextButton(onPressed: app.clearRecentTrips, child: const Text('Tout effacer')),
            ],
          ),
          Container(
            decoration: _cardDeco(context, radius: 18),
            child: Column(
              children: [
                for (final r in _allRecent ? recent : recent.take(3))
                  ListTile(
                    leading: Icon(Icons.history, color: scheme.onSurfaceVariant),
                    title: Row(
                      children: [
                        Flexible(child: label(icon(r['from'] as Map))),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.arrow_forward, size: 16),
                        ),
                        Flexible(child: label(icon(r['to'] as Map))),
                      ],
                    ),
                    subtitle: Text(_ago(r['at'] as String?)),
                    onTap: () => _useTrip(r),
                    onLongPress: () => app.removeRecentTrip(r),
                    trailing: IconButton(
                      tooltip: 'Ajouter aux trajets favoris',
                      icon: const Icon(Icons.star_border),
                      onPressed: () => app.saveFavTrip(
                        Map<String, dynamic>.from(r['from'] as Map),
                        Map<String, dynamic>.from(r['to'] as Map),
                      ),
                    ),
                  ),
                if (recent.length > 3)
                  TextButton(
                    onPressed: () => setState(() => _allRecent = !_allRecent),
                    child: Text(_allRecent ? 'Voir moins' : 'Voir les ${recent.length}'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
        ],
        Row(
          children: [
            Expanded(child: Text('Arrêts près de moi', style: section)),
            TextButton.icon(
              onPressed: _locating ? null : _locate,
              icon: _locating
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location),
              label: Text(nearby == null ? 'Me localiser' : 'Actualiser'),
            ),
          ],
        ),
        if (_nearbyError != null)
          Text(_nearbyError!, style: TextStyle(color: scheme.error))
        else if (nearby == null)
          const Text('Touchez « Me localiser » pour voir les arrêts autour de vous.')
        else if (nearby.isEmpty)
          const Text('Aucun arrêt à moins de 800 m.')
        else
          // vignettes : toucher un arrêt le met en départ
          SizedBox(
            height: 70,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: nearby.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final (a, d) = nearby[i];
                return Container(
                  width: 150,
                  decoration: _cardDeco(context, radius: 16),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => setState(() {
                        _from = PlaceChoice(a.label, a.town.isEmpty ? 'Arrêt' : a.town, 'stop_area:${a.id}', 'arret');
                        _search = null;
                        _fieldsKey = UniqueKey();
                      }),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              a.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(distanceLabel(d), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 20),
        Text(
          'Itinéraires porte à porte, avec correspondances, calculés par Île-de-France Mobilités. '
          'Nécessite internet et le jeton PRIM. Appui long sur un trajet ou une recherche pour le retirer.',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// Choix de l'heure par roulettes (heures, minutes), sans le cadran qui fait vibrer le téléphone.
  Future<TimeOfDay?> _pickTime(BuildContext context, TimeOfDay initial, String title) {
    var picked = initial;
    return showModalBottomSheet<TimeOfDay>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text(title, style: Theme.of(ctx).textTheme.titleMedium)),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, picked), child: const Text('OK')),
                ],
              ),
            ),
            SizedBox(
              height: 200,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: Theme.of(ctx).brightness,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: TextStyle(fontSize: 22, color: Theme.of(ctx).colorScheme.onSurface),
                  ),
                ),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: true,
                  minuteInterval: 1,
                  initialDateTime: DateTime(2000, 1, 1, initial.hour, initial.minute),
                  onDateTimeChanged: (d) => picked = TimeOfDay(hour: d.hour, minute: d.minute),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Dernière position connue (sans demander de nouvelle mesure), pour classer les lieux.
  LatLng? _lastKnown;

  /// Coordonnées d'un lieu choisi sans attendre (arrêt, coordonnées), sinon ma dernière position.
  LatLng? _quickPos(PlaceChoice? p) {
    final ref = p?.ref ?? '';
    if (ref.startsWith('stop_area:')) return app.stopAreas[ref.substring(10)]?.pos;
    final parts = ref.split(';');
    if (parts.length == 2) {
      final lon = double.tryParse(parts[0]), lat = double.tryParse(parts[1]);
      if (lon != null && lat != null) return LatLng(lat, lon);
    }
    return _lastKnown;
  }

  // --- aperçu avant recherche ---------------------------------------------------------
  String? _previewKey;
  Future<(LatLng?, LatLng?, LatLng?)>? _previewFuture;

  /// Coordonnées d'un lieu choisi : arrêt du catalogue, coordonnées « lon;lat », ma position.
  Future<LatLng?> _posOf(PlaceChoice p) async {
    if (p.kind == 'position') return currentPosition();
    final ref = p.ref ?? '';
    if (ref.startsWith('stop_area:')) return app.stopAreas[ref.substring(10)]?.pos;
    final parts = ref.split(';');
    if (parts.length == 2) {
      final lon = double.tryParse(parts[0]), lat = double.tryParse(parts[1]);
      if (lon != null && lat != null) return LatLng(lat, lon);
    }
    return null;
  }

  Widget _preview() {
    final key = '${_from!.label}|${_from!.ref}>${_to!.label}|${_to!.ref}';
    if (key != _previewKey) {
      _previewKey = key;
      _previewFuture = () async {
        final a = await _posOf(_from!), b = await _posOf(_to!);
        // point bleu : position déjà connue (ma position choisie) ou affichage activé dans les réglages
        final me = _from!.kind == 'position'
            ? a
            : _to!.kind == 'position'
            ? b
            : (app.showMyPosition ? _lastKnown : null); // dernière position connue : pas d'attente du GPS
        return (a, b, me);
      }();
    }
    return FutureBuilder(
      future: _previewFuture,
      builder: (context, snap) {
        final r = snap.data;
        if (r == null || r.$1 == null || r.$2 == null) {
          return Center(
            child: snap.connectionState == ConnectionState.done
                ? const Text('Appuyez sur Rechercher.')
                : const CircularProgressIndicator(),
          );
        }
        return PlacePreview(from: r.$1!, to: r.$2!, me: r.$3);
      },
    );
  }

  Widget _results(BuildContext context) {
    final s = _search;
    if (s == null && _from != null && _to != null) return _preview();
    if (s == null) return _home(context);
    final now = app.nowSec();
    return ValueListenableBuilder(
      valueListenable: _realtime,
      builder: (context, rt, _) => ListView(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        children: [
          for (var i = 0; i < s.journeys.length; i++)
            _JourneyCard(
              search: s,
              timed: _Timed(s.journeys[i], i, rt),
              now: now,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _DetailScreen(app: app, search: s, index: i, realtime: _realtime),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Champ de lieu : ma position, arrêts du catalogue (sur l'appareil), adresses (calculateur).
class _PlaceField extends StatefulWidget {
  const _PlaceField({
    required this.app,
    required this.label,
    required this.icon,
    required this.value,
    required this.onSet,
    this.initialText,
    this.near,
  });
  final AppState app;
  final String label;
  final IconData icon;
  final PlaceChoice? value;
  final void Function(PlaceChoice?) onSet;

  /// Texte à chercher dès l'ouverture (saisi, champ actif, suggestions ouvertes).
  final String? initialText;

  /// Point autour duquel classer les lieux trouvés (l'autre champ, ou ma dernière position).
  final LatLng? Function()? near;

  @override
  State<_PlaceField> createState() => _PlaceFieldState();
}

class _PlaceFieldState extends State<_PlaceField> {
  bool _prefilled = false;

  AppState get app => widget.app;
  String get label => widget.label;
  IconData get icon => widget.icon;
  PlaceChoice? get value => widget.value;
  void Function(PlaceChoice?) get onSet => widget.onSet;

  static String _latest = '';

  String _networks(StopArea a) {
    final n = {for (final id in a.lines) app.networks[app.line(id)?.network] ?? ''}.where((x) => x.isNotEmpty).take(2);
    return n.isEmpty ? '' : ' · ${n.join(' · ')}';
  }

  static final _geocoder = Geocoder();

  static int _roleOrder(String? r) => switch (r) {
    'domicile' => 0,
    'travail' => 1,
    _ => 2,
  };

  static IconData favIcon(String? role) => switch (role) {
    'domicile' => Icons.home,
    'travail' => Icons.work,
    _ => Icons.star,
  };

  bool get _isFav => value != null && app.favPlaces.any((f) => (f['place'] as Map)['ref'] == value!.ref);

  /// Étoile du champ : enregistrer le lieu choisi comme Domicile, Travail ou autre favori.
  Future<void> _favSheet(BuildContext context) async {
    final v = value;
    if (v == null) return;
    final place = v.favRole != null
        ? (app.favPlaces.firstWhere((f) => (f['place'] as Map)['ref'] == v.ref)['place'] as Map<String, dynamic>)
        : v.toJson();
    final existing = app.favPlaces.where((f) => (f['place'] as Map)['ref'] == v.ref).toList();
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Enregistrer « ${place['label']} »'),
              subtitle: const Text('Sur ce téléphone seulement'),
            ),
            ListTile(
              leading: const Icon(Icons.home),
              title: const Text('Domicile'),
              onTap: () {
                app.saveFavPlace('domicile', 'Domicile', place);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.work),
              title: const Text('Travail'),
              onTap: () {
                app.saveFavPlace('travail', 'Travail', place);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: const Text('Autre favori…'),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await _askName(context, '${place['label']}');
                if (name != null) app.saveFavPlace('autre', name, place);
              },
            ),
            for (final f in existing)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text('Retirer « ${f['name']} » des favoris'),
                onTap: () {
                  app.removeFavPlace(f);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  static Future<String?> _askName(BuildContext context, String initial, {String title = 'Nom du favori'}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.sentences),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  /// Appui long sur un favori proposé : le renommer ou le retirer.
  Future<void> _editFav(BuildContext context, PlaceChoice p) async {
    final f = app.favPlaces.where((f) => (f['place'] as Map)['ref'] == p.ref && f['name'] == p.label).firstOrNull;
    if (f == null) return;
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text('${f['name']}'), subtitle: Text('${(f['place'] as Map)['label']}')),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Renommer'),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await _askName(context, '${f['name']}');
                if (name != null) app.renameFavPlace(f, name);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Retirer des favoris'),
              onTap: () {
                app.removeFavPlace(f);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// « Arrêt le plus proche : Lycée Descartes (250 m) », calculé sur le téléphone.
  String? _nearLabel(LatLng pos) {
    final n = nearbyAreas(app.stopAreas.values, pos, radius: 2000, limit: 1).firstOrNull;
    return n == null ? null : 'Arrêt le plus proche : ${n.$1.label} (${distanceLabel(n.$2)})';
  }

  Future<List<PlaceChoice>> _options(String text) async {
    final q = searchKey(text);
    final stops = q.length >= 2 ? searchStopAreas(app.stopAreas.values, q, limit: 6) : const <StopArea>[];
    // lieux favoris : tous avant de taper, sinon ceux dont le nom ou le lieu correspond
    final favs = [
      for (final f in app.favPlaces)
        if (q.isEmpty || searchKey('${f['name']} ${(f['place'] as Map)['label']}').contains(q)) PlaceChoice.fromFav(f),
    ]..sort((a, b) => _roleOrder(a.favRole) - _roleOrder(b.favRole));
    final local = <PlaceChoice>[
      if (q.isEmpty || 'ma position'.contains(q)) PlaceChoice.myPosition,
      ...favs,
      for (final a in stops)
        PlaceChoice(
          a.label,
          '${a.town.isEmpty ? 'Arrêt' : a.town} · ${a.lines.length} ligne(s)${_networks(a)}',
          'stop_area:${a.id}',
          'arret',
        ),
    ];
    if (q.length < 3) return local;
    // lieux et adresses (IGN), seulement quand la frappe s'arrête
    _latest = q;
    await Future.delayed(const Duration(milliseconds: 450));
    if (_latest != q) return local;
    // lieux OSM de l'appareil (sans connexion), puis IGN (lieux publics, adresses) et entreprises (Sirene)
    // en parallèle ; sans réseau, on n'attend pas plus de 4 s
    final osm = app.places.search(text, near: widget.near?.call(), limit: 4);
    const none = <GeoPlace>[];
    final (ign, companies) = await (
      _geocoder.search(text.trim()).timeout(const Duration(seconds: 4), onTimeout: () => none),
      _geocoder.searchCompanies(text.trim()).timeout(const Duration(seconds: 4), onTimeout: () => none),
    ).wait;
    if (_latest != q) return local;
    // une adresse (« 12 rue… ») : l'IGN d'abord ; sinon les lieux de l'appareil d'abord
    final addressFirst = RegExp(r'^\s*\d').hasMatch(text);
    final merged = <GeoPlace>[];
    bool dup(GeoPlace g) => merged.any(
      (m) =>
          normalizeWords(m.name) == normalizeWords(g.name) && const Distance().as(LengthUnit.Meter, m.pos, g.pos) < 150,
    );
    final fromOsm = [for (final p in osm) GeoPlace(name: p.name, detail: p.detail, pos: p.pos, isPoi: true)];
    for (final g in [
      ...(addressFirst ? [...ign, ...fromOsm] : [...fromOsm, ...ign]),
      ...companies,
    ]) {
      if (!dup(g)) merged.add(g);
    }
    final places = merged;
    if (places.isEmpty && RegExp(r'\d').hasMatch(q)) {
      // géocodeur indisponible : adresses du calculateur PRIM (une requête)
      final addresses = await app.searchAddresses(text.trim());
      return [...local, for (final (name, id) in addresses) PlaceChoice(name, 'Adresse', id, 'adresse')];
    }
    return [
      ...local,
      for (final g in places)
        PlaceChoice(
          g.name,
          g.detail,
          '${g.pos.longitude};${g.pos.latitude}', // coordonnées, comprises par le calculateur
          g.isCompany
              ? 'entreprise'
              : g.isPoi
              ? 'lieu'
              : 'adresse',
          near: _nearLabel(g.pos),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Autocomplete<PlaceChoice>(
    initialValue: TextEditingValue(text: value?.label ?? ''),
    displayStringForOption: (p) => p.label,
    optionsBuilder: (v) => _options(v.text),
    onSelected: onSet,
    optionsViewBuilder: (context, onSelected, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300, maxWidth: 360),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final p in options)
                ListTile(
                  dense: true,
                  leading: Icon(
                    p.favRole != null
                        ? favIcon(p.favRole)
                        : switch (p.kind) {
                            'position' => Icons.my_location,
                            'arret' => Icons.directions_bus_outlined,
                            'lieu' => Icons.place_outlined,
                            'entreprise' => Icons.business_outlined,
                            _ => Icons.home_outlined,
                          },
                    color: p.favRole != null ? Colors.amber.shade700 : null,
                  ),
                  title: Text(p.label),
                  subtitle: Text([p.detail, ?p.near].join('\n')),
                  onTap: () => onSelected(p),
                  onLongPress: p.favRole == null ? null : () => _editFav(context, p),
                ),
            ],
          ),
        ),
      ),
    ),
    fieldViewBuilder: (context, ctrl, focus, onSubmit) {
      // texte venu d'un autre écran : saisi après le premier affichage, ce qui ouvre les suggestions
      if (!_prefilled && widget.initialText != null) {
        _prefilled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          focus.requestFocus();
          ctrl.text = widget.initialText!;
        });
      }
      return TextField(
        controller: ctrl,
        focusNode: focus,
        onChanged: (_) => onSet(null), // texte modifié : il faut rechoisir une proposition
        decoration: InputDecoration(
          labelText: label,
          hintText: 'Ma position, arrêt, lieu ou adresse',
          // lieu ou adresse choisi : l'arrêt le plus proche
          helperText: value?.near,
          helperMaxLines: 2,
          // fond gris, sans cadre (la carte et le pointillé font le lien)
          filled: true,
          // pas de libellé au-dessus d'un champ rempli : le pointillé distingue départ et arrivée
          floatingLabelBehavior: FloatingLabelBehavior.never,
          fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          // lieu choisi : étoile pour l'enregistrer en favori (pas « ma position », qui change)
          suffixIcon: value == null || value!.kind == 'position'
              ? null
              : IconButton(
                  tooltip: 'Favori',
                  icon: Icon(_isFav ? Icons.star : Icons.star_border, color: _isFav ? Colors.amber.shade700 : null),
                  onPressed: () => _favSheet(context),
                ),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
      );
    },
  );
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({required this.search, required this.timed, required this.now, required this.onTap});
  final ItinerarySearch search;
  final _Timed timed;
  final int now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final j = timed.journey;
    final scheme = Theme.of(context).colorScheme;
    final disruptions = {for (final s in j.transit) ...s.disruptions}
        .map((id) => search.disruptions[id])
        .whereType<Disruption>()
        .where((d) => d.kind != DisruptionKind.accessibility)
        .length;
    final steps = <Widget>[];
    for (var k = 0; k < j.sections.length; k++) {
      final s = j.sections[k];
      if (s.type == 'wait' || (s.type == 'transfer' && s.duration < 60)) continue;
      if (steps.isNotEmpty) steps.add(Icon(Icons.chevron_right, size: 16, color: scheme.outline));
      if (s.isTransit) {
        final r = timed.realtime[k];
        steps.add(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(modeIcon(s.mode), size: 16),
                  const SizedBox(width: 2),
                  LineBadge(name: s.lineCode ?? '?', color: s.color, textColor: s.textColor, small: true),
                  // heure de départ de ce transport (corrigée du temps réel)
                  Text(' (${hhmm(timed.dep[k])})', style: const TextStyle(fontSize: 12)),
                ],
              ),
              if (r != null)
                Text(
                  r.cancelled ? 'supprimé' : delayLabel(r.delay),
                  style: TextStyle(fontSize: 10, color: _delayColor(context, r.cancelled ? 999 : r.delay)),
                ),
            ],
          ),
        );
      } else {
        steps.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.directions_walk, size: 16),
              Text(
                [
                  '${(s.duration / 60).ceil()} min',
                  if (walkLength(s.shape) case final m when m > 0) distanceLabel(m),
                ].join(' · '),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      }
    }
    final broken = timed.brokenAt;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ligne 1 : heures et départ ; ligne 2 : durée et correspondances (sans coupure au milieu)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${hhmm(timed.start)} → ${hhmm(timed.end)}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    timed.start <= now ? 'partez maintenant' : 'dans ${duration(timed.start - now)}',
                    style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary),
                  ),
                ],
              ),
              Text(
                '${duration(timed.end - timed.start)} · '
                '${j.transit.isEmpty
                    ? 'à pied'
                    : j.transfers == 0
                    ? 'direct'
                    : '${j.transfers} correspondance${j.transfers > 1 ? 's' : ''}'}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 2, runSpacing: 4, children: steps),
              if (broken != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    timed.realtime[broken]?.cancelled == true
                        ? '⚠ ${j.sections[broken].lineCode} supprimé : relancez la recherche'
                        : '⚠ Correspondance compromise à ${j.sections[broken].from?.name} : relancez la recherche',
                    style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold),
                  ),
                ),
              if (disruptions > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'ⓘ $disruptions perturbation(s) sur le parcours',
                    style: TextStyle(fontSize: 12, color: scheme.tertiary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _delayColor(BuildContext context, int delay) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return delay >= 90
      ? (dark ? Colors.red.shade300 : Colors.red.shade700)
      : (dark ? Colors.green.shade300 : Colors.green.shade700);
}

// --- détail d'un itinéraire -------------------------------------------------------------

class _DetailScreen extends StatelessWidget {
  const _DetailScreen({required this.app, required this.search, required this.index, required this.realtime});
  final AppState app;
  final ItinerarySearch search;
  final int index;
  final ValueNotifier<Map<String, StepRealtime>> realtime;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: realtime,
    builder: (context, rt, _) {
      final t = _Timed(search.journeys[index], index, rt);
      final j = t.journey;
      return Scaffold(
        appBar: AppBar(title: Text('${hhmm(t.start)} → ${hhmm(t.end)} · ${duration(t.end - t.start)}')),
        body: Column(
          children: [
            Expanded(flex: 4, child: _map(context, j)),
            Expanded(
              flex: 5,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (t.brokenAt != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.warning_amber),
                        title: Text(
                          t.realtime[t.brokenAt!]?.cancelled == true
                              ? '${j.sections[t.brokenAt!].lineCode} supprimé'
                              : 'Correspondance compromise à ${j.sections[t.brokenAt!].from?.name}',
                        ),
                        subtitle: const Text('Relancez la recherche pour un autre itinéraire.'),
                      ),
                    ),
                  _goButton(context, t),
                  for (var k = 0; k < j.sections.length; k++) _step(context, t, k),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  /// « Partir » : navigation à pied jusqu'au premier transport (ou jusqu'à l'arrivée).
  Widget _goButton(BuildContext context, _Timed t) {
    final j = t.journey;
    final k = j.sections.indexWhere((s) => s.isTransit);
    final walk = [
      for (final s in k < 0 ? j.sections : j.sections.sublist(0, k))
        if (!s.isTransit) ...s.shape,
    ];
    final bus = k < 0 ? null : j.sections[k];
    final target = bus?.from ?? j.sections.last.to;
    final path = walk.isNotEmpty ? walk : [?target?.pos];
    if (path.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FilledButton.icon(
        icon: const Icon(Icons.directions_walk),
        label: Text(bus == null ? 'Partir' : 'Partir vers ${bus.from?.name ?? 'l\'arrêt'}'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => WalkNavScreen(
              app: app,
              path: path,
              target: target?.name ?? 'Arrivée',
              lineCode: bus?.lineCode,
              lineId: bus?.lineId,
              departure: bus == null ? null : t.dep[k],
              fromArea: bus?.from?.area,
              toArea: bus?.to?.area,
            ),
          ),
        ),
      ),
    );
  }

  Widget _map(BuildContext context, Journey j) {
    final all = [for (final s in j.sections) ...s.shape];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final first = j.sections.first.from, last = j.sections.last.to;
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: all.length >= 2
            ? CameraFit.bounds(bounds: LatLngBounds.fromPoints(all), padding: const EdgeInsets.all(28))
            : null,
        initialCenter: all.isNotEmpty ? all.first : const LatLng(48.85, 2.35),
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'fr.applitransport.app',
          tileBuilder: dark ? darkModeTileBuilder : null,
        ),
        PolylineLayer(
          polylines: [
            for (final s in j.sections)
              if (s.shape.length >= 2)
                s.isTransit
                    ? Polyline(points: s.shape, color: s.color, strokeWidth: 5)
                    // marche : pointillés bleus cerclés de blanc, lisibles sur le fond de carte
                    : Polyline(
                        points: s.shape,
                        color: Colors.blue.shade700,
                        strokeWidth: 5,
                        borderColor: Colors.white,
                        borderStrokeWidth: 1.5,
                        pattern: const StrokePattern.dotted(spacingFactor: 1.6),
                      ),
          ],
        ),
        CircleLayer(
          circles: [
            for (final s in j.transit) ...[
              if (s.from != null)
                CircleMarker(
                  point: s.from!.pos,
                  radius: 6,
                  color: Colors.white,
                  borderColor: s.color,
                  borderStrokeWidth: 3,
                ),
              if (s.to != null)
                CircleMarker(
                  point: s.to!.pos,
                  radius: 6,
                  color: Colors.white,
                  borderColor: s.color,
                  borderStrokeWidth: 3,
                ),
            ],
          ],
        ),
        MarkerLayer(
          markers: [
            if (first != null)
              Marker(
                point: first.pos,
                child: const Icon(Icons.trip_origin, color: Colors.green, size: 22),
              ),
            if (last != null)
              Marker(
                point: last.pos,
                alignment: Alignment.topCenter,
                child: const Icon(Icons.flag, color: Colors.red, size: 28),
              ),
          ],
        ),
        const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
      ],
    );
  }

  Widget _step(BuildContext context, _Timed t, int k) {
    final s = t.journey.sections[k];
    final scheme = Theme.of(context).colorScheme;
    switch (s.type) {
      case 'wait':
        return ListTile(
          dense: true,
          leading: const Icon(Icons.hourglass_empty),
          title: Text('Attente ${duration(s.duration)}'),
        );
      case 'walk':
      case 'transfer':
        return ListTile(
          dense: true,
          leading: const Icon(Icons.directions_walk),
          title: Text('${s.type == 'transfer' ? 'Correspondance à pied' : 'À pied'} ${duration(s.duration)}'),
          subtitle: Text("jusqu'à ${s.to?.name ?? ''}"),
        );
    }
    final r = t.realtime[k];
    final lineId = s.lineId != null && app.line(s.lineId!) != null ? s.lineId : null;
    final texts = {
      for (final id in s.disruptions)
        if (search.disruptions[id] != null) search.disruptions[id]!.title,
    }.where((x) => x.isNotEmpty).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(modeIcon(s.mode)),
                const SizedBox(width: 6),
                LineBadge(name: s.lineCode ?? '?', color: s.color, textColor: s.textColor),
                const SizedBox(width: 6),
                Expanded(child: Text('${s.mode} → ${s.direction}', overflow: TextOverflow.ellipsis)),
                if (r != null)
                  Text(
                    r.cancelled ? 'supprimé' : delayLabel(r.delay),
                    style: TextStyle(
                      color: _delayColor(context, r.cancelled ? 999 : r.delay),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Montée ${hhmm(t.dep[k])} · ${s.from?.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Descente ${hhmm(t.arr[k])} · ${s.to?.name}'),
            Text('${s.stops.length - 1} arrêt(s) · ${duration(s.duration)}', style: TextStyle(color: scheme.outline)),
            if (texts.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.info_outline, color: scheme.tertiary),
                title: Text('${texts.length} perturbation(s)', style: TextStyle(color: scheme.tertiary)),
                children: [
                  for (final x in texts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('• $x', style: const TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            if (lineId != null)
              Align(
                alignment: Alignment.centerRight,
                child: ListenableBuilder(
                  listenable: app,
                  builder: (context, _) => app.downloading.containsKey(lineId)
                      ? const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : TextButton.icon(
                          icon: Icon(app.hasSchedules(lineId) ? Icons.timeline : Icons.download),
                          label: Text(
                            '${app.hasSchedules(lineId) ? 'Suivre' : 'Télécharger et suivre'} ce '
                            '${vehicleWord(app.line(lineId)?.type ?? typeOfMode(s.mode))}',
                          ),
                          onPressed: () async {
                            // ligne absente de l'appareil : on la télécharge d'abord (quelques Ko)
                            if (!app.hasSchedules(lineId)) await app.download(lineId);
                            if (!context.mounted || !app.hasSchedules(lineId)) return;
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    LineScreen(app: app, lineId: lineId, fromArea: s.from?.area, toArea: s.to?.area),
                              ),
                            );
                          },
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
