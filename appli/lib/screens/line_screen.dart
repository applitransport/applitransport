// Cas 1 : suivi d'une ligne. Ligne (parmi les préférées) → sens → arrêt → horaires ;
// Actualiser / Auto corrige les horaires et place les bus du sens choisi sur la carte.
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

/// Un passage à l'arrêt choisi : course [trip] de la variante [variant], qui y est le [index]-ième arrêt.
class _Passage {
  _Passage(this.variant, this.trip, this.index, this.time);
  final int variant, trip, index, time;
  String get id => '$variant/$trip';
}

class LineScreen extends StatefulWidget {
  const LineScreen({super.key, required this.app, this.lineId, this.fromArea, this.toArea});
  final AppState app;

  /// Ouverture directe (« Suivre ce bus » depuis un itinéraire) : ligne, zone de montée et zone
  /// de descente, qui déterminent le sens et l'arrêt.
  final String? lineId, fromArea, toArea;

  @override
  State<LineScreen> createState() => _LineScreenState();
}

class _LineScreenState extends State<LineScreen> {
  String? _lineId, _stop, _selected;
  int _dir = 0;
  bool _listHidden = false; // liste des horaires repliée : la carte prend toute la place
  Timer? _ticker;
  final _nextKey = GlobalKey();

  AppState get app => widget.app;
  DemoLine? get line => _lineId == null ? null : app.timetable(_lineId!);

  /// Ligne choisie et en service aujourd'hui.
  bool get _usable => line != null && line!.directions.isNotEmpty;
  Direction get direction => line!.directions[_dir];

  /// Arrêts où l'on peut monter (tous sauf les terminus d'arrivée).
  List<Stop> get _boardingStops => [
        for (final s in direction.stops)
          if (direction.variants.any((v) {
            final i = v.indexOf(s.name);
            return i >= 0 && i < v.stops.length - 1;
          }))
            s
      ];

  @override
  void initState() {
    super.initState();
    _lineId = app.preferred.where(app.hasSchedules).firstOrNull;
    if (_usable) _stop = _boardingStops.first.name;
    if (widget.lineId != null && app.hasSchedules(widget.lineId!)) _openAt(widget.lineId!);
    if (_lineId != null) app.loadTraffic(_lineId!);
    _scrollToNextSoon();
    // les bus avancent entre deux requêtes : on redessine chaque seconde
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _openAt(String lineId) {
    _lineId = lineId;
    if (!_usable) return;
    for (var d = 0; d < line!.directions.length; d++) {
      for (final v in line!.directions[d].variants) {
        final i = v.indexOfArea(widget.fromArea ?? '');
        if (i >= 0 && (widget.toArea == null || v.indexOfArea(widget.toArea!, i + 1) > i)) {
          _dir = d;
          _stop = v.stops[i].name;
          return;
        }
      }
    }
    _stop = _boardingStops.first.name;
  }

  void _scrollToNextSoon() => WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _nextKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 300));
      });

  void _select({String? lineId, int? dir, String? stop}) => setState(() {
        if (lineId != null) {
          _lineId = lineId;
          _dir = 0;
          app.loadTraffic(lineId);
        }
        if (dir != null) _dir = dir;
        if ((lineId != null || dir != null) && _usable) _stop = _boardingStops.first.name;
        if (stop != null) _stop = stop;
        _selected = null;
        _scrollToNextSoon();
      });

  List<_Passage> _passages() {
    final out = <_Passage>[];
    final d = direction;
    for (var v = 0; v < d.variants.length; v++) {
      final i = d.variants[v].indexOf(_stop!);
      if (i < 0 || i >= d.variants[v].stops.length - 1) continue;
      for (var t = 0; t < d.variants[v].trips.length; t++) {
        out.add(_Passage(v, t, i, d.variants[v].trips[t][i]));
      }
    }
    return out..sort((a, b) => a.time.compareTo(b.time));
  }

  TripRealtime? _rt(int v, int t) => app.rt(line!.id, direction.id, v, t);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Suivi de ligne')),
        // SafeArea : les boutons restent au-dessus de la barre de navigation Android
        body: SafeArea(
            top: false,
            child: line == null
                ? _noLine(context)
                : !_usable
                    ? Column(children: [
                        _selectors(context),
                        const Expanded(child: Center(child: Text("Cette ligne ne circule pas aujourd'hui."))),
                      ])
                    : _body(context)),
      ),
    );
  }

  Widget _noLine(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Aucune ligne préférée téléchargée.\n'
              'Ajoutez-en dans Configuration › Lignes.', textAlign: TextAlign.center),
        ),
      );

  Widget _body(BuildContext context) {
    final l = line!, d = direction, now = app.nowSec();
    final refreshed = app.refreshedAt[l.id];
    final passages = _passages();
    final selected = passages.where((p) => p.id == _selected).firstOrNull;

    // bus du sens choisi que PRIM annonce en circulation
    final buses = <MapBus>[];
    if (refreshed != null) {
      for (var v = 0; v < d.variants.length; v++) {
        for (var t = 0; t < d.variants[v].trips.length; t++) {
          final r = _rt(v, t);
          if (r == null) continue;
          final s = busStatus(d.variants[v], t, now, r);
          if (s != null) {
            buses.add(MapBus(id: '$v/$t', position: s.position, selected: '$v/$t' == _selected, realtime: true));
          }
        }
      }
    }

    return Column(children: [
      _selectors(context),
      Expanded(
        flex: 5,
        child: Stack(children: [
          LineMap(
            key: ValueKey('${l.id}/$_dir'),
            shapes: [for (final v in d.variants) v.shape],
            stops: d.stops,
            color: l.color,
            myStop: d.stops.firstWhere((s) => s.name == _stop),
            buses: buses,
            onBusTap: (id) => setState(() => _selected = id),
          ),
          // la fiche du bus choisi est posée sur la carte : les boutons ne bougent pas
          if (_selected != null) Positioned(left: 0, right: 0, bottom: 0, child: _tripCard(context, now, selected)),
        ]),
      ),
      RefreshControls(
        // une instance par ligne : changer de ligne arrête l'auto en cours
        key: ValueKey(l.id),
        onRefresh: () => app.refreshLine(l.id),
        autoMinutes: app.autoMinutes,
        lastRefresh: refreshed,
        now: app.now,
        error: app.realtimeError,
        middle: IconButton.filledTonal(
          tooltip: _listHidden ? 'Afficher les horaires' : 'Masquer les horaires',
          onPressed: () => setState(() {
            _listHidden = !_listHidden;
            if (!_listHidden) _scrollToNextSoon();
          }),
          icon: Icon(_listHidden ? Icons.expand_less : Icons.expand_more),
        ),
      ),
      if (!_listHidden) Expanded(flex: 4, child: _departures(context, now, passages, buses.length)),
    ]);
  }

  Widget _selectors(BuildContext context) {
    // la ligne ouverte depuis un itinéraire figure dans le menu même si elle n'est pas préférée
    final lines = {...app.preferred.where(app.hasSchedules), ?_lineId}.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(children: [
        Row(children: [
          DropdownButton<String>(
            value: _lineId,
            underline: const SizedBox(),
            items: [
              for (final id in lines)
                DropdownMenuItem(
                  value: id,
                  child: LineBadge(
                      name: app.timetable(id)!.name,
                      color: app.timetable(id)!.color,
                      textColor: app.timetable(id)!.textColor),
                ),
            ],
            onChanged: (v) => _select(lineId: v),
          ),
          const SizedBox(width: 12),
          if (_usable)
          Expanded(
            child: DropdownButton<int>(
              value: _dir,
              isExpanded: true,
              items: [
                for (var i = 0; i < line!.directions.length; i++)
                  DropdownMenuItem(value: i, child: Text('→ ${line!.directions[i].label}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => _select(dir: v),
            ),
          ),
          if (_lineId != null) TrafficButton(app: app, lineId: _lineId!),
        ]),
        if (_usable)
        Row(children: [
          const Icon(Icons.place_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
              value: _stop,
              isExpanded: true,
              items: [
                for (final s in _boardingStops)
                  DropdownMenuItem(value: s.name, child: Text(s.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => _select(stop: v),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _departures(BuildContext context, int now, List<_Passage> passages, int running) {
    final l = line!, d = direction;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lateColor = dark ? Colors.red.shade300 : Colors.red.shade700;
    final okColor = dark ? Colors.green.shade300 : Colors.green.shade700;
    var nextFound = false;
    final chips = <Widget>[];
    for (final p in passages) {
      final r = _rt(p.variant, p.trip);
      final delay = r?.delayAt(p.index);
      final cancelled = r != null && (r.cancelled || r.cancelledStops.contains(p.index));
      final expected = p.time + (delay ?? 0);
      // PRIM dit quels arrêts le bus a déjà desservis ; sinon on se fie à l'heure
      final passed = r?.nextIndex != null ? r!.passed(p.index) : expected < now - 30;
      final isNext = !passed && !nextFound;
      if (isNext) nextFound = true;
      final selected = p.id == _selected;
      final late = (delay ?? 0) >= 90;
      final headsign = d.variants[p.variant].headsign;
      final fg = selected ? l.textColor : null;
      chips.add(InkWell(
        key: isNext ? _nextKey : null,
        onTap: () => setState(() => _selected = p.id),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 76,
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: selected ? l.color : (passed || cancelled ? scheme.surfaceContainerHighest : null),
            border: Border.all(color: selected ? l.color : scheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(children: [
            Text(hhmm(p.time),
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: fg ?? (passed ? scheme.outline : null),
                    decoration: passed || cancelled ? TextDecoration.lineThrough : null)),
            Text(
              cancelled
                  ? 'supprimé'
                  : passed && r != null
                      ? 'passé'
                      : (delay == null ? 'théorique' : '${delayLabel(delay)} ${hhmm(expected)}'),
              style: TextStyle(
                fontSize: 10,
                fontWeight: cancelled ? FontWeight.bold : null,
                color: fg ??
                    (cancelled
                        ? lateColor
                        : passed
                        ? scheme.outline
                        : delay == null
                            ? scheme.outline
                            : late
                                ? lateColor
                                : okColor),
              ),
            ),
            // destination affichée seulement quand elle diffère du sens principal
            if (headsign != d.label)
              Text('→ $headsign',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: fg ?? scheme.secondary)),
          ]),
        ),
      ));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Horaires à $_stop'
          '${app.refreshedAt.containsKey(l.id) ? ' · $running bus en circulation dans ce sens' : ''}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: chips),
      ]),
    );
  }

  Widget _tripCard(BuildContext context, int now, _Passage? p) {
    if (p == null) return const SizedBox();
    final v = direction.variants[p.variant];
    final r = _rt(p.variant, p.trip);
    final delay = r?.delayAt(p.index);
    final times = tripTimes(v, p.trip, r);
    final s = busStatus(v, p.trip, now, r);
    final String where;
    if (r == null) {
      where = app.refreshedAt.containsKey(line!.id)
          ? 'PRIM ne donne pas d\'information sur ce bus : horaire théorique.'
          : 'Appuyez sur Actualiser pour savoir où est ce bus.';
    } else if (r.cancelled || r.cancelledStops.contains(p.index)) {
      where = 'Course supprimée${r.cancelled ? '' : ' à votre arrêt'}.';
    } else if (s != null) {
      where = 'A passé ${v.stops[s.lastStop].name} il y a ${duration(s.sinceSec)}.\n'
          'Prochain arrêt : ${v.stops[s.nextStop].name} dans ${duration(s.nextInSec)}.\n'
          '${s.lastStop >= p.index ? 'Déjà passé à votre arrêt.' : 'À votre arrêt dans ${duration(times[p.index] - now)} (${p.index - s.lastStop} arrêt(s)).'}';
    } else if (r.nextIndex == 0 || now < times.first) {
      where = 'Pas encore parti de ${v.stops.first.name} (départ dans ${duration(times.first - now)}).\n'
          'À votre arrêt dans ${duration(times[p.index] - now)}.';
    } else {
      where = 'Arrivé au terminus ${v.stops.last.name}.';
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Bus de ${hhmm(p.time)} → ${v.headsign} · ${delayLabel(delay)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(where),
            ]),
          ),
          IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.close)),
        ]),
      ),
    );
  }
}
