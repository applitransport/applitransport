// Cas 2, « Quelle ligne prendre ? » : arrêt de départ → arrêt d'arrivée. Prochains bus directs de toutes les lignes qui relient
// les deux zones d'arrêt ; celles qui ne sont pas téléchargées sont proposées au téléchargement.
// Actualiser / Auto : une requête PRIM « arrêt » corrige les horaires au départ.
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/realtime.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/line_vehicles.dart';
import '../poc/nearby.dart';
import '../poc/position.dart';
import '../widgets/card_decoration.dart';
import '../widgets/line_badge.dart';
import '../widgets/line_map.dart';
import '../widgets/refresh_controls.dart';
import '../widgets/traffic_button.dart';
import 'itinerary_screen.dart';
import 'lines_map_screen.dart';

const _horizonSec = 2 * 3600; // prochains départs seulement

class _Journey {
  _Journey(this.line, this.direction, this.variantIndex, this.trip, this.from, this.to);
  final DemoLine line;
  final Direction direction;
  final int variantIndex, trip, from, to;
  Variant get variant => direction.variants[variantIndex];
}

class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.app});
  final AppState app;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  StopArea? _origin, _destination;
  Timer? _ticker;
  Key _fieldsKey = UniqueKey();
  late final List<StopArea> _boardingAreas = _computeBoardingAreas();

  AppState get app => widget.app;

  /// Lignes qui passent par la zone de départ (d'après le catalogue), téléchargées ou non.
  List<String> get _originLines => _origin?.lines ?? const [];

  /// Horaires du jour de celles qui sont téléchargées.
  List<DemoLine> get _originTimetables => app.timetablesOf(_originLines);

  /// Toutes les zones d'arrêt du catalogue.
  List<StopArea> _computeBoardingAreas() =>
      app.stopAreas.values.where((a) => a.lines.isNotEmpty).toList()..sort((a, b) => a.label.compareTo(b.label));

  /// Zones atteignables sans correspondance depuis la zone de départ.
  List<StopArea> get _destinations {
    if (_origin == null) return const [];
    final ids = <String>{};
    // lignes téléchargées : arrêts réellement desservis après le départ, dans le bon sens
    for (final l in _originTimetables) {
      for (final d in l.directions) {
        for (final v in d.variants) {
          final i = v.indexOfArea(_origin!.id);
          if (i >= 0) ids.addAll(v.stops.skip(i + 1).map((s) => s.area));
        }
      }
    }
    // lignes non téléchargées : le catalogue dit seulement par où elles passent
    final notDownloaded = _originLines.where((id) => !app.hasSchedules(id)).toSet();
    if (notDownloaded.isNotEmpty) {
      for (final a in app.stopAreas.values) {
        if (a.lines.any(notDownloaded.contains)) ids.add(a.id);
      }
    }
    ids.remove(_origin!.id);
    return [
      for (final id in ids)
        if (app.stopAreas[id] != null) app.stopAreas[id]!,
    ]..sort((a, b) => a.label.compareTo(b.label));
  }

  /// Lignes reliant directement les deux zones.
  List<DemoLine> get _connecting => [
    for (final l in _originTimetables)
      if (l.directions.any(
        (d) => d.variants.any((v) {
          final i = v.indexOfArea(_origin!.id);
          return i >= 0 && v.indexOfArea(_destination!.id, i + 1) > i;
        }),
      ))
        l,
  ];

  TripRealtime? _rt(_Journey j) => app.rt(j.line.id, j.direction.id, j.variantIndex, j.trip);
  int? _knownDelay(_Journey j) => _rt(j)?.delayAt(j.from);
  int _delay(_Journey j) => _knownDelay(j) ?? 0;

  List<_Journey> _journeys(List<DemoLine> lines, int now) {
    final out = <_Journey>[];
    for (final l in lines) {
      for (final d in l.directions) {
        for (var vi = 0; vi < d.variants.length; vi++) {
          final v = d.variants[vi];
          final i = v.indexOfArea(_origin!.id);
          if (i < 0) continue;
          final j = v.indexOfArea(_destination!.id, i + 1);
          if (j < 0) continue;
          for (var t = 0; t < v.trips.length; t++) {
            final dep = v.trips[t][i] + (app.rt(l.id, d.id, vi, t)?.delayAt(i) ?? 0);
            if (dep >= now - 30 && dep <= now + _horizonSec) out.add(_Journey(l, d, vi, t, i, j));
          }
        }
      }
    }
    int dep(_Journey x) => x.variant.trips[x.trip][x.from] + _delay(x);
    return out..sort((a, b) => dep(a).compareTo(dep(b)));
  }

  /// Dernière saisie de chaque champ (« départ », « arrivée ») : nom de quai trouvé, destination sans
  /// ligne directe.
  final Map<String, String> _queries = {};

  /// Arrêts à proximité (zone, distance) ; null tant que la position n'est pas connue.
  List<(StopArea, double)>? _nearby;
  bool _locating = false;
  String? _nearbyError;

  /// Position obtenue dans cet écran (« Me localiser ») : le point bleu s'affiche sur les cartes.
  bool _located = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    // localisation déjà autorisée (« Ma position sur la carte ») : arrêts proches tout de suite
    if (app.showMyPosition) _locate(ask: false);
  }

  /// Cherche les arrêts à proximité ; [ask] : demande la permission (appui de l'usager).
  Future<void> _locate({required bool ask}) async {
    setState(() {
      _locating = true;
      _nearbyError = null;
    });
    final me = await currentPosition(ask: ask);
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (me == null) {
        if (ask) {
          _nearbyError =
              'Position introuvable : localisation désactivée ou refusée, ou pas de signal GPS (à l\'intérieur ?).';
        }
      } else {
        _located = true;
        _nearby = nearbyAreas(_boardingAreas, me);
      }
    });
  }

  /// Choisit une zone comme arrêt de départ (depuis la liste des arrêts proches).
  void _pickOrigin(StopArea a) => setState(() {
    _origin = a;
    if (!_destinations.contains(_destination)) _destination = null;
    _fieldsKey = UniqueKey(); // recrée les champs avec la nouvelle valeur
  });

  /// Pas de ligne directe vers [to] : Itinéraire, prérempli avec les deux arrêts.
  Widget _noDirect(BuildContext context, StopArea to) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Pas de ligne directe de ${_origin!.label} à ${to.label}.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text('Avec un changement, Itinéraire trouve le trajet (internet).', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              PlaceChoice place(StopArea a) =>
                  PlaceChoice(a.label, a.town.isEmpty ? 'Arrêt' : a.town, 'stop_area:${a.id}', 'arret');
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ItineraryScreen(app: app, from: place(_origin!), to: place(to)),
                ),
              );
            },
            icon: const Icon(Icons.directions),
            label: const Text('Chercher avec Itinéraire'),
          ),
        ],
      ),
    ),
  );

  /// Le texte tapé n'est pas un nom d'arrêt (un lieu, une adresse) : Itinéraire le cherche.
  Widget _notAStop(BuildContext context, String query) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '« $query » n\'est pas un nom d\'arrêt.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Pour un lieu ou une adresse, Itinéraire trouve le trajet et les arrêts à proximité (internet).',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ItineraryScreen(
                  app: app,
                  from: _origin == null
                      ? null
                      : PlaceChoice(
                          _origin!.label,
                          _origin!.town.isEmpty ? 'Arrêt' : _origin!.town,
                          'stop_area:${_origin!.id}',
                          'arret',
                        ),
                  toQuery: query,
                ),
              ),
            ),
            icon: const Icon(Icons.directions),
            label: const Text('Chercher ce lieu avec Itinéraire'),
          ),
        ],
      ),
    ),
  );

  /// Arrêts près de moi : dans l'espace libre tant que l'arrêt de départ n'est pas choisi.
  Widget _nearbyList(BuildContext context) {
    final theme = Theme.of(context);
    final list = _nearby;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Arrêts près de moi',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (_locating)
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            else
              TextButton.icon(
                onPressed: () => _locate(ask: true),
                icon: const Icon(Icons.my_location),
                label: Text(list == null ? 'Me localiser' : 'Actualiser'),
              ),
          ],
        ),
        if (_nearbyError != null)
          Text(_nearbyError!, style: TextStyle(color: theme.colorScheme.error))
        else if (list == null && !_locating)
          const Text('Touchez « Me localiser » pour voir les arrêts autour de vous.')
        else if (list != null && list.isEmpty)
          Text('Aucun arrêt à moins de ${distanceLabel(nearbyRadius)}.'),
        if (list != null && list.isNotEmpty)
          Container(
            decoration: cardDecoration(context, radius: 18),
            child: Column(
              children: [
                for (final (a, d) in list)
                  ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('${distanceLabel(d)}${a.town.isEmpty ? '' : ' · ${a.town}'}'),
                          for (final id in a.lines.take(8))
                            if (app.line(id) case final l?)
                              LineBadge(name: l.name, color: l.color, textColor: l.textColor, small: true),
                          if (a.lines.length > 8) Text('+${a.lines.length - 8}'),
                        ],
                      ),
                    ),
                    onTap: () => _pickOrigin(a),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Text(
          "Seuls les trajets directs (sans correspondance) sont proposés.",
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final now = app.nowSec();
        final ready = _origin != null && _destination != null;
        final downloaded = ready ? _connecting : <DemoLine>[];
        // lignes qui desservent les deux zones mais ne sont pas sur l'appareil
        final missing = <CatalogLine>[
          if (ready)
            for (final id in _origin!.lines)
              if (!app.hasSchedules(id) && _destination!.lines.contains(id) && app.line(id) != null) app.line(id)!,
        ];
        final journeys = ready ? _journeys(downloaded, now) : <_Journey>[];
        final refreshed = downloaded
            .map((l) => app.refreshedAt[l.id])
            .whereType<DateTime>()
            .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          appBar: AppBar(
            title: const Text('Quelle ligne prendre ?', style: TextStyle(fontWeight: FontWeight.w700)),
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          ),
          body: Column(
            children: [
              _fields(context),
              if (ready && missing.isNotEmpty) _missingBanner(context, missing),
              if (ready && downloaded.isNotEmpty)
                RefreshControls(
                  key: ValueKey('${_origin!.id}>${_destination!.id}'),
                  // une seule requête « arrêt » donne les passages de toutes les lignes au départ
                  onRefresh: () => app.refreshStop(_origin!.id, downloaded.map((l) => l.id)),
                  single: true, // Actualiser seul, comme sur les autres écrans
                  manualCooldown: const Duration(seconds: 10),
                  autoMinutes: app.autoMinutes,
                  lastRefresh: refreshed,
                  now: app.now,
                  error: app.realtimeError,
                ),
              // perturbations en cours sur les lignes du trajet (chargées une fois par quart d'heure)
              if (ready && downloaded.isNotEmpty) _trafficRow(downloaded),
              const Divider(height: 1),
              Expanded(child: _results(context, ready, downloaded.isEmpty, journeys, now)),
            ],
          ),
        );
      },
    );
  }

  Widget _fields(BuildContext context) {
    Widget field(
      String label,
      IconData icon,
      List<StopArea> options,
      StopArea? value,
      void Function(StopArea?) onSet,
    ) => Autocomplete<StopArea>(
      initialValue: TextEditingValue(text: value?.label ?? ''),
      displayStringForOption: (a) => a.label,
      optionsBuilder: (v) {
        if (_queries[label] != v.text) {
          _queries[label] = v.text;
          // la destination sans ligne directe s'affiche sous les champs : on redessine après la saisie
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        return searchStopAreas(options, v.text);
      },
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280, maxWidth: 360),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final a in options)
                  ListTile(
                    dense: true,
                    // trouvé par un nom de quai : affiché, sinon on ne reconnaît pas l'arrêt
                    title: Text.rich(
                      TextSpan(
                        text: a.label,
                        children: [
                          if (matchedQuay(a, _queries[label] ?? '') case final quay?)
                            TextSpan(
                              text: ' · $quay',
                              style: const TextStyle(fontStyle: FontStyle.italic),
                            ),
                        ],
                      ),
                    ),
                    // plusieurs zones portent le même nom (« Le Hameau ») : le réseau aide à choisir
                    subtitle: Text(
                      [
                        if (a.town.isNotEmpty) a.town,
                        '${a.lines.length} ligne(s)',
                        ...{
                          for (final id in a.lines) app.networks[app.line(id)?.network] ?? '',
                        }.where((n) => n.isNotEmpty).take(2),
                      ].join(' · '),
                    ),
                    onTap: () => onSelected(a),
                  ),
              ],
            ),
          ),
        ),
      ),
      onSelected: onSet,
      fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
        controller: ctrl,
        focusNode: focus,
        decoration: InputDecoration(
          labelText: label,
          // fond gris, sans cadre (la carte et le pointillé font le lien), comme Itinéraire
          filled: true,
          // pas de libellé au-dessus d'un champ rempli : le pointillé distingue départ et arrivée
          floatingLabelBehavior: FloatingLabelBehavior.never,
          fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          suffixIcon: ctrl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    ctrl.clear();
                    onSet(null);
                  },
                ),
        ),
      ),
    );

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: _fieldsKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // départ et arrivée dans une seule carte, reliés par un pointillé (comme Itinéraire)
          Container(
            decoration: cardDecoration(context),
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
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2A541),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    children: [
                      field(
                        'Arrêt de départ',
                        Icons.trip_origin,
                        _boardingAreas,
                        _origin,
                        (v) => setState(() {
                          _origin = v;
                          if (!_destinations.contains(_destination)) _destination = null;
                        }),
                      ),
                      const SizedBox(height: 8),
                      field(
                        "Arrêt d'arrivée",
                        Icons.place,
                        _destinations,
                        _destination,
                        (v) => setState(() => _destination = v),
                      ),
                    ],
                  ),
                ),
                IconButton.outlined(
                  tooltip: 'Inverser',
                  icon: const Icon(Icons.swap_vert),
                  onPressed: _origin == null || _destination == null
                      ? null
                      : () => setState(() {
                          final o = _origin;
                          _origin = _destination;
                          _destination = _destinations.contains(o) ? o : null;
                          _fieldsKey = UniqueKey(); // recrée les champs avec les nouvelles valeurs
                        }),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              'Toutes les lignes directes entre deux arrêts et leurs prochains départs, sans connexion. '
              'Avec un changement : Itinéraire.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          // carte de toutes les lignes de l'arrêt de départ, jusqu'à leurs terminus
          if (_origin != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.map_outlined),
                label: Text('Carte des lignes de ${_origin!.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () async {
                  final area = await Navigator.of(context).push<StopArea>(
                    MaterialPageRoute(
                      builder: (_) => LinesMapScreen(app: app, origin: _origin!),
                    ),
                  );
                  if (area == null || !mounted) return;
                  setState(() {
                    _destination = area;
                    _fieldsKey = UniqueKey(); // recrée les champs avec la nouvelle arrivée
                  });
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _trafficRow(List<DemoLine> lines) {
    for (final l in lines) {
      app.loadTraffic(l.id); // sans effet si déjà chargées il y a moins de 15 min
    }
    final chips = [for (final l in lines) TrafficButton(app: app, lineId: l.id, compact: true)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(spacing: 6, children: chips),
    );
  }

  /// Lignes qui font aussi le trajet mais ne sont pas sur l'appareil.
  Widget _missingBanner(BuildContext context, List<CatalogLine> missing) {
    final busy = missing.any((l) => app.downloading.containsKey(l.id));
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${missing.length} autre(s) ligne(s) directe(s) non téléchargée(s) :'),
                  for (final l in missing) LineBadge(name: l.name, color: l.color, textColor: l.textColor, small: true),
                ],
              ),
            ),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator()),
                  )
                : TextButton.icon(
                    onPressed: () {
                      for (final l in missing) {
                        app.download(l.id);
                      }
                    },
                    icon: const Icon(Icons.download),
                    label: const Text('Ajouter'),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, bool ready, bool nothingDownloaded, List<_Journey> journeys, int now) {
    if (_origin == null) return _nearbyList(context);
    if (_destination == null) {
      // destination tapée qui n'est atteignable qu'avec un changement : proposer Itinéraire
      final q = _queries["Arrêt d'arrivée"] ?? '';
      if (searchKey(q).length >= 2 && searchStopAreas(_destinations, q).isEmpty) {
        final elsewhere = searchStopAreas(_boardingAreas, q, limit: 1).firstOrNull;
        // un arrêt sans ligne directe, ou pas un arrêt du tout (lieu, adresse) : Itinéraire
        return elsewhere != null ? _noDirect(context, elsewhere) : _notAStop(context, q.trim());
      }
    }
    String? message;
    if (!ready) {
      message = _origin == null
          ? "Choisissez un arrêt de départ puis un arrêt d'arrivée.\n"
                'Seuls les trajets directs (sans correspondance) sont proposés.'
          : "Choisissez l'arrêt d'arrivée : seuls ceux desservis sans changement depuis ${_origin!.label} "
                'sont proposés.';
    } else if (nothingDownloaded) {
      message = 'Aucune ligne téléchargée ne fait ce trajet.\nAjoutez celles proposées ci-dessus.';
    } else if (journeys.isEmpty) {
      message = 'Aucun départ direct dans les 2 prochaines heures.';
    }
    if (message != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, textAlign: TextAlign.center),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      itemCount: journeys.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, k) {
        final j = journeys[k];
        final r = _rt(j);
        final delay = r?.delayAt(j.from);
        final cancelled = r != null && (r.cancelled || r.cancelledStops.contains(j.from));
        final times = tripTimes(j.variant, j.trip, r);
        final dep = times[j.from], arr = times[j.to];
        final late = (delay ?? 0) >= 90;
        return ListTile(
          onTap: () => _showBus(context, j),
          leading: LineBadge(name: j.line.name, color: j.line.color, textColor: j.line.textColor),
          title: Text(
            '${hhmm(dep)} → ${hhmm(arr)}  (${duration(arr - dep)})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          // le quai précis compte dans une grande zone comme une gare
          subtitle: Text(
            'Direction ${j.variant.headsign}\nDépart : ${j.variant.stops[j.from].name}'
            '${delay != null && delay.abs() >= 60 ? ' · prévu ${hhmm(j.variant.trips[j.trip][j.from])}' : ''}',
          ),
          isThreeLine: true,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                dep <= now ? 'à quai' : 'dans ${duration(dep - now)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                cancelled ? 'supprimé' : delayLabel(delay),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: cancelled ? FontWeight.bold : null,
                  color: cancelled || late
                      ? Colors.red.shade400
                      : delay == null
                      ? scheme.outline
                      : Colors.green.shade500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showBus(BuildContext context, _Journey j) {
    // sinon, à la fermeture, le champ d'arrivée reprend le curseur et rouvre le clavier
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // sans poignée : on ferme avec la croix ou en faisant glisser le panneau vers le bas
      builder: (context) => _Ticking(
        // recalcul chaque seconde : la position théorique avance
        builder: (context) => ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            final now = app.nowSec();
            final r = _rt(j);
            final times = tripTimes(j.variant, j.trip, r);
            final dirIndex = j.line.directions.indexOf(j.direction);
            final id = '${j.variantIndex}/${j.trip}';
            // ce véhicule, comme dans le suivi de ligne : vert s'il est vu par un voyageur, sinon rouge
            final bus = [
              for (final b in lineVehicles(
                app,
                j.line,
                j.direction,
                dirIndex,
                show: true,
                selected: id,
                ride: app.ride,
              ))
                if (b.id == id) b,
            ];
            final crowd = bus.any((b) => b.crowd);
            final cancelled = r?.cancelled ?? false;
            final (source, sourceColor) = cancelled
                ? ('supprimé', Colors.red.shade700)
                : crowd
                ? ('vu par un voyageur', Colors.green.shade700)
                : r != null
                ? ('PRIM', Colors.red.shade400)
                : ('théorique', Colors.grey);
            String eta(int t) {
              final left = t - now;
              if (left < -30) return 'passé à ${hhmm(t)}';
              if (left < 60) return 'maintenant (${hhmm(t)})';
              return 'dans ${duration(left)} (${hhmm(t)})';
            }

            final small = Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.25);
            return SizedBox(
              height: MediaQuery.of(context).size.height * 0.7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 4, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            LineBadge(name: j.line.name, color: j.line.color, textColor: j.line.textColor),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '→ ${j.variant.headsign}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            // Actualiser : serveur communautaire à chaque appui, PRIM au plus toutes les 30 s
                            IconButton(
                              tooltip: 'Actualiser',
                              onPressed: () => app.refreshLineAll(j.line.id),
                              icon: const Icon(Icons.refresh),
                            ),
                            IconButton(
                              tooltip: 'Fermer',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.cancel_outlined),
                            ),
                          ],
                        ),
                        Text('À votre arrêt : ${eta(times[j.from])}', style: small),
                        Text(
                          'À ${j.variant.stops[j.to].name} : ${eta(times[j.to])}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: small,
                        ),
                        Text(
                          source,
                          style: small?.copyWith(color: sourceColor, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LineMap(
                      showMe: app.showMyPosition || _located,
                      vehicleIcon: vehicleIcon(j.line.type),
                      confirmationColors: true,
                      shapes: [j.variant.shape],
                      stops: j.variant.stops,
                      color: j.line.color,
                      myStop: j.variant.stops[j.from],
                      toStop: j.variant.stops[j.to],
                      buses: bus,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Reconstruit son contenu chaque seconde (panneau ouvert par-dessus l'écran).
class _Ticking extends StatefulWidget {
  const _Ticking({required this.builder});
  final WidgetBuilder builder;

  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _timer;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
