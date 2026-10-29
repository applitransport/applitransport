// Cas 2 : arrêt de départ → arrêt d'arrivée. Prochains bus directs de toutes les lignes qui relient
// les deux zones d'arrêt ; celles qui ne sont pas téléchargées sont proposées au téléchargement.
// Actualiser / Auto : une requête PRIM « arrêt » corrige les horaires au départ.
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/realtime.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/position.dart';
import '../widgets/line_badge.dart';
import '../widgets/line_map.dart';
import '../widgets/refresh_controls.dart';
import '../widgets/traffic_button.dart';

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
    return [for (final id in ids) if (app.stopAreas[id] != null) app.stopAreas[id]!]
      ..sort((a, b) => a.label.compareTo(b.label));
  }

  /// Lignes reliant directement les deux zones.
  List<DemoLine> get _connecting => [
        for (final l in _originTimetables)
          if (l.directions.any((d) => d.variants.any((v) {
                final i = v.indexOfArea(_origin!.id);
                return i >= 0 && v.indexOfArea(_destination!.id, i + 1) > i;
              })))
            l
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

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
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
              if (!app.hasSchedules(id) && _destination!.lines.contains(id) && app.line(id) != null) app.line(id)!
        ];
        final journeys = ready ? _journeys(downloaded, now) : <_Journey>[];
        final refreshed = downloaded.map((l) => app.refreshedAt[l.id]).whereType<DateTime>().fold<DateTime?>(
            null, (a, b) => a == null || b.isBefore(a) ? b : a);
        return Scaffold(
          appBar: AppBar(title: const Text('Arrêt → destination')),
          body: Column(children: [
            _fields(context),
            if (ready && missing.isNotEmpty) _missingBanner(context, missing),
            if (ready && downloaded.isNotEmpty)
              RefreshControls(
                key: ValueKey('${_origin!.id}>${_destination!.id}'),
                // une seule requête « arrêt » donne les passages de toutes les lignes au départ
                onRefresh: () => app.refreshStop(_origin!.id, downloaded.map((l) => l.id)),
                autoMinutes: app.autoMinutes,
                lastRefresh: refreshed,
                now: app.now,
                error: app.realtimeError,
              ),
            // perturbations en cours sur les lignes du trajet (chargées une fois par quart d'heure)
            if (ready && downloaded.isNotEmpty) _trafficRow(downloaded),
            const Divider(height: 1),
            Expanded(child: _results(context, ready, downloaded.isEmpty, journeys, now)),
          ]),
        );
      },
    );
  }

  Widget _fields(BuildContext context) {
    Widget field(String label, IconData icon, List<StopArea> options, StopArea? value, void Function(StopArea?) onSet) =>
        Autocomplete<StopArea>(
          initialValue: TextEditingValue(text: value?.label ?? ''),
          displayStringForOption: (a) => a.label,
          optionsBuilder: (v) {
            return searchStopAreas(options, v.text);
          },
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280, maxWidth: 360),
                child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                  for (final a in options)
                    ListTile(
                      dense: true,
                      title: Text(a.label),
                      // plusieurs zones portent le même nom (« Le Hameau ») : le réseau aide à choisir
                      subtitle: Text([
                        if (a.town.isNotEmpty) a.town,
                        '${a.lines.length} ligne(s)',
                        ...{for (final id in a.lines) app.networks[app.line(id)?.network] ?? ''}.where((n) => n.isNotEmpty).take(2),
                      ].join(' · ')),
                      onTap: () => onSelected(a),
                    ),
                ]),
              ),
            ),
          ),
          onSelected: onSet,
          fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
            controller: ctrl,
            focusNode: focus,
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: ctrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        ctrl.clear();
                        onSet(null);
                      }),
            ),
          ),
        );

    return Padding(
      key: _fieldsKey,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(children: [
        Expanded(
          child: Column(children: [
            field('Arrêt de départ', Icons.trip_origin, _boardingAreas, _origin, (v) => setState(() {
                  _origin = v;
                  if (!_destinations.contains(_destination)) _destination = null;
                })),
            const SizedBox(height: 8),
            field("Arrêt d'arrivée", Icons.place, _destinations, _destination,
                (v) => setState(() => _destination = v)),
          ]),
        ),
        IconButton(
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
      ]),
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
        child: Row(children: [
          Expanded(
            child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${missing.length} autre(s) ligne(s) directe(s) non téléchargée(s) :'),
              for (final l in missing) LineBadge(name: l.name, color: l.color, textColor: l.textColor, small: true),
            ]),
          ),
          busy
              ? const Padding(
                  padding: EdgeInsets.all(8), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator()))
              : TextButton.icon(
                  onPressed: () {
                    for (final l in missing) {
                      app.download(l.id);
                    }
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('Ajouter'),
                ),
        ]),
      ),
    );
  }

  Widget _results(BuildContext context, bool ready, bool nothingDownloaded, List<_Journey> journeys, int now) {
    String? message;
    if (!ready) {
      message = "Choisissez un arrêt de départ puis un arrêt d'arrivée.\n"
          'Seuls les trajets directs (sans correspondance) sont proposés.';
    } else if (nothingDownloaded) {
      message = 'Aucune ligne téléchargée ne fait ce trajet.\nAjoutez celles proposées ci-dessus.';
    } else if (journeys.isEmpty) {
      message = 'Aucun bus direct dans les 2 prochaines heures.';
    }
    if (message != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(message, textAlign: TextAlign.center)));
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
          title: Text('${hhmm(dep)} → ${hhmm(arr)}  (${duration(arr - dep)})',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          // le quai précis compte dans une grande zone comme une gare
          subtitle: Text('Direction ${j.variant.headsign}\nDépart : ${j.variant.stops[j.from].name}'
              '${delay != null && delay.abs() >= 60 ? ' · prévu ${hhmm(j.variant.trips[j.trip][j.from])}' : ''}'),
          isThreeLine: true,
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(dep <= now ? 'à quai' : 'dans ${duration(dep - now)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(cancelled ? 'supprimé' : delayLabel(delay),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: cancelled ? FontWeight.bold : null,
                    color: cancelled || late
                        ? Colors.red.shade400
                        : delay == null
                            ? scheme.outline
                            : Colors.green.shade500)),
          ]),
        );
      },
    );
  }

  void _showBus(BuildContext context, _Journey j) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final now = app.nowSec();
          final r = _rt(j);
          final delay = r?.delayAt(j.from);
          final s = busStatus(j.variant, j.trip, now, r);
          final text = r == null
              ? (app.refreshedAt.containsKey(j.line.id)
                  ? 'PRIM ne donne pas d\'information sur ce bus : horaire théorique.'
                  : 'Appuyez sur Actualiser pour savoir où est ce bus.')
              : r.cancelled
                  ? 'Course supprimée.'
                  : s == null
                  ? 'Pas encore parti de ${j.variant.stops.first.name}.'
                  : 'A passé ${j.variant.stops[s.lastStop].name} il y a ${duration(s.sinceSec)} · '
                      'prochain arrêt ${j.variant.stops[s.nextStop].name}.';
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(children: [
              ListTile(
                leading: LineBadge(name: j.line.name, color: j.line.color, textColor: j.line.textColor),
                title: Text('→ ${j.variant.headsign} · ${delayLabel(delay)}'),
                subtitle: Text(text),
              ),
              Expanded(
                child: LineMap(
                  shapes: [j.variant.shape],
                  stops: j.variant.stops,
                  color: j.line.color,
                  myStop: j.variant.stops[j.from],
                  buses: [
                    if (delay != null && s != null)
                      MapBus(id: '${j.trip}', position: s.position, selected: true, realtime: true),
                  ],
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}
