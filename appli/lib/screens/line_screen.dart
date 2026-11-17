// Cas 1 : suivi d'une ligne. Ligne (parmi les préférées) → sens → arrêt → horaires ;
// Actualiser / Auto corrige les horaires et place les bus du sens choisi sur la carte.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../data/community.dart';
import '../data/realtime.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/line_vehicles.dart';
import '../poc/nearby.dart';
import '../poc/position.dart';
import '../poc/ride_control.dart';
import '../widgets/line_badge.dart';
import '../widgets/line_map.dart';
import '../widgets/refresh_controls.dart';
import '../widgets/ride_widgets.dart';
import '../widgets/traffic_button.dart';
import 'line_status_screen.dart';

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

  /// Dernier appui sur Actualiser, par ligne : les véhicules sont alors affichés sur la carte.
  final Map<String, DateTime> _shownAt = {};

  AppState get app => widget.app;
  DemoLine? get line => _lineId == null ? null : app.timetable(_lineId!);

  /// Ligne choisie et en service aujourd'hui.
  bool get _usable => line != null && line!.directions.isNotEmpty;
  Direction get direction => line!.directions[_dir];

  /// Arrêts du sens choisi, terminus d'arrivée compris (pour suivre un train jusqu'à son arrivée).
  List<Stop> get _stops => direction.stops;

  @override
  void initState() {
    super.initState();
    _lineId = app.preferred.where(app.hasSchedules).firstOrNull;
    if (_usable) _stop = _stops.first.name;
    // dernière sélection (ce menu ou l'état de la ligne), conservée entre deux ouvertures
    final last = app.lastSelection;
    if (widget.lineId == null && last.line != null && app.hasSchedules(last.line!)) {
      _lineId = last.line;
      if (_usable) {
        _dir = last.dir < line!.directions.length ? last.dir : 0;
        _stop = _stops.any((s) => s.name == last.stop) ? last.stop : _stops.first.name;
      }
    }
    if (widget.lineId != null && app.hasSchedules(widget.lineId!)) _openAt(widget.lineId!);
    // localisation déjà autorisée : l'arrêt le plus proche de la ligne, s'il est à moins de 500 m
    if (widget.lineId == null && app.showMyPosition) _nearestStop(auto: true);
    if (_lineId != null) app.loadTraffic(_lineId!);
    // ligne, sens et arrêt affichés : retenus (« Mes lignes » de l'accueil)
    if (_usable) app.rememberSelection(_lineId, _dir, stop: _stop);
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
    _stop = _stops.first.name;
  }

  /// Arrêt le plus proche dans le sens choisi. [auto] (ouverture) : sans demander la permission, et
  /// seulement à moins de 500 m ; sinon (bouton 📍) : le plus proche, à toute distance.
  Future<void> _nearestStop({required bool auto}) async {
    final lineId = _lineId, dir = _dir;
    final me = await currentPosition(ask: !auto);
    if (!mounted || !_usable || _lineId != lineId || _dir != dir) return;
    void tell(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    if (me == null) {
      if (!auto) tell('Position indisponible : localisation désactivée ou refusée.');
      return;
    }
    final found = nearestStop(_stops, me);
    if (found == null) return;
    final (stop, d) = found;
    if (auto && d > autoStopRadius) return;
    if (stop.name != _stop) _select(stop: stop.name);
    tell('Arrêt le plus proche : ${stop.name} (${distanceLabel(d)})');
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
    if ((lineId != null || dir != null) && _usable) _stop = _stops.first.name;
    if (stop != null) _stop = stop;
    _selected = null;
    app.rememberSelection(_lineId, _dir, stop: _stop);
    _scrollToNextSoon();
  });

  List<_Passage> _passages() {
    final out = <_Passage>[];
    final d = direction;
    for (var v = 0; v < d.variants.length; v++) {
      final i = d.variants[v].indexOf(_stop!);
      if (i < 0) continue;
      for (var t = 0; t < d.variants[v].trips.length; t++) {
        // course de la veille passée à cet arrêt il y a plus d'une heure : pas dans la liste du jour
        // (moins d'une heure : gardée, un transport en retard peut ne pas être encore passé)
        if (d.variants[v].trips[t][i] < -3600) continue;
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
        appBar: AppBar(
          title: const Text('Suivi de ligne'),
          actions: [
            // « Mes lignes » de l'accueil : cette ligne, avec le sens et l'arrêt affichés
            if (_lineId != null)
              IconButton(
                tooltip: app.preferred.contains(_lineId) ? 'Retirer de Mes lignes' : 'Ajouter à Mes lignes',
                icon: Icon(
                  app.preferred.contains(_lineId) ? Icons.star : Icons.star_border,
                  color: app.preferred.contains(_lineId) ? const Color(0xFFF2A541) : null,
                ),
                onPressed: () {
                  app.rememberSelection(_lineId, _dir, stop: _stop);
                  app.togglePreferred(_lineId!);
                },
              ),
          ],
        ),
        // SafeArea : les boutons restent au-dessus de la barre de navigation Android
        body: SafeArea(
          top: false,
          child: line == null
              ? _noLine(context)
              : !_usable
              ? Column(
                  children: [
                    _selectors(context),
                    const Expanded(child: Center(child: Text("Cette ligne ne circule pas aujourd'hui."))),
                  ],
                )
              : _body(context),
        ),
      ),
    );
  }

  Widget _noLine(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'Aucune ligne préférée téléchargée.\n'
        'Ajoutez-en dans Configuration › Lignes.',
        textAlign: TextAlign.center,
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final l = line!, d = direction, now = app.nowSec();
    final refreshed = app.refreshedAt[l.id];
    final passages = _passages();
    final crowd = crowdEstimates(app, l, d);
    // signalements des voyageurs dans ce sens, et par course (« variante/course »)
    final reports = placedReports(app, l, d);
    final byTrip = <String, List<PlacedReport>>{};
    for (final p in reports) {
      if (p.place.variant != null) (byTrip['${p.place.variant}/${p.place.trip}'] ??= []).add(p);
    }
    final selected = passages.where((p) => p.id == _selected).firstOrNull;

    // après Actualiser : tous les véhicules du sens choisi (rouges : PRIM ou horaire ;
    // verts : vus par un voyageur, dont l'usager à bord)
    final buses = lineVehicles(
      app,
      l,
      d,
      _dir,
      show: _shownAt.containsKey(l.id) || refreshed != null,
      selected: _selected,
      ride: app.ride,
      alerts: alertTrips(reports),
    );

    return Column(
      children: [
        _selectors(context),
        // un appui ouvre l'état de la ligne du trajet (signaler, Sorti)
        if (app.ride != null)
          RideBanner(
            app: app,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LineStatusScreen(app: app, lineId: app.ride!.lineId, dirIndex: app.ride!.direction),
              ),
            ),
          ),
        Expanded(
          flex: 5,
          child: Stack(
            children: [
              LineMap(
                showMe: app.showMyPosition,
                vehicleIcon: vehicleIcon(l.type),
                confirmationColors: true,
                key: ValueKey('${l.id}/$_dir'),
                shapes: [for (final v in d.variants) v.shape],
                stops: d.stops,
                color: l.color,
                myStop: d.stops.firstWhere((s) => s.name == _stop),
                buses: buses,
                alertStops: alertStops(reports),
                onBusTap: (id) => setState(() => _selected = id),
              ),
              // la fiche du bus choisi est posée sur la carte : les boutons ne bougent pas
              if (_selected != null)
                Positioned(left: 0, right: 0, bottom: 0, child: _tripCard(context, now, selected, crowd, byTrip)),
            ],
          ),
        ),
        RefreshControls(
          // une instance par ligne : les décomptes repartent à zéro en changeant de ligne
          key: ValueKey(l.id),
          // Actualiser : PRIM + serveur communautaire, horaires recalculés ; 10 s d'attente
          // Actualiser : serveur communautaire à chaque appui, PRIM au plus toutes les 30 s ;
          // 10 s d'attente entre deux appuis
          onRefresh: () {
            setState(() => _shownAt[l.id] = DateTime.now());
            app.refreshLineAll(l.id);
          },
          manualCooldown: const Duration(seconds: 10),
          single: true,
          lastCommunity: app.communityAt[l.id],
          primNote: app.token.isEmpty ? 'pas de jeton' : null,
          autoMinutes: app.autoMinutes,
          lastRefresh: refreshed,
          now: app.now,
          error: app.token.isEmpty ? null : app.realtimeError,
          middle: IconButton.filledTonal(
            tooltip: _listHidden ? 'Afficher les horaires' : 'Masquer les horaires',
            onPressed: () => setState(() {
              _listHidden = !_listHidden;
              if (!_listHidden) _scrollToNextSoon();
            }),
            icon: Icon(_listHidden ? Icons.expand_less : Icons.expand_more),
          ),
        ),
        if (!_listHidden) Expanded(flex: 4, child: _departures(context, now, passages, buses.length, crowd, byTrip)),
      ],
    );
  }

  Widget _selectors(BuildContext context) {
    // la ligne ouverte depuis un itinéraire figure dans le menu même si elle n'est pas préférée
    final lines = {...app.preferred.where(app.hasSchedules), ?_lineId}.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
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
                        textColor: app.timetable(id)!.textColor,
                      ),
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
                        DropdownMenuItem(
                          value: i,
                          child: Text('→ ${line!.directions[i].label}', overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => _select(dir: v),
                  ),
                ),
              if (_lineId != null) TrafficButton(app: app, lineId: _lineId!),
            ],
          ),
          if (_usable)
            Row(
              children: [
                const Icon(Icons.place_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    value: _stop,
                    isExpanded: true,
                    items: [
                      for (final s in _stops)
                        DropdownMenuItem(
                          value: s.name,
                          child: Text(s.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => _select(stop: v),
                  ),
                ),
                IconButton(
                  tooltip: 'Arrêt le plus proche',
                  onPressed: () => _nearestStop(auto: false),
                  icon: const Icon(Icons.my_location),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _departures(
    BuildContext context,
    int now,
    List<_Passage> passages,
    int running,
    Map<String, CrowdEstimate> crowd,
    Map<String, List<PlacedReport>> byTrip,
  ) {
    final l = line!, d = direction;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lateColor = dark ? Colors.red.shade300 : Colors.red.shade700;
    final okColor = dark ? Colors.green.shade300 : Colors.green.shade700;
    var nextFound = false;
    final chips = <Widget>[];
    for (final p in passages) {
      final r = _rt(p.variant, p.trip);
      // vu par un voyageur : sa position prime sur PRIM (plus récente, mesurée à bord)
      final seen = crowd[p.id];
      final delay = seen?.delaySec ?? r?.delayAt(p.index);
      final cancelled = r != null && (r.cancelled || r.cancelledStops.contains(p.index));
      // signalements des voyageurs sur cette course (sauf ceux que l'on sait faux)
      final reported = [
        for (final x in byTrip[p.id] ?? const <PlacedReport>[])
          if (x.assessment.trust != ReportTrust.contradicted) x.report,
      ];
      final reportedCancelled = !cancelled && reported.any((x) => x.type == 'supprime');
      final alerting = reported.any((x) => x.type == 'incident' || x.detail == 'bloque');
      final expected = p.time + (delay ?? 0);
      // un voyageur ou PRIM disent quels arrêts le bus a déjà desservis ; sinon on se fie à l'heure
      final passed = seen != null
          ? seen.passed(p.index)
          : r?.nextIndex != null
          ? r!.passed(p.index)
          : expected < now - 30;
      final isNext = !passed && !nextFound;
      if (isNext) nextFound = true;
      final selected = p.id == _selected;
      final late = (delay ?? 0) >= 90;
      final headsign = d.variants[p.variant].headsign;
      // terminus de cette course : on y arrive, on n'en repart pas
      final terminus = p.index == d.variants[p.variant].stops.length - 1;
      final fg = selected ? l.textColor : null;
      chips.add(
        InkWell(
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
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      hhmm(p.time),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: fg ?? (passed ? scheme.outline : null),
                        decoration: passed || cancelled ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    // vu par un voyageur
                    if (seen != null) Icon(Icons.person_pin_circle, size: 13, color: fg ?? okColor),
                    // signalé bloqué ou en incident
                    if (alerting) Icon(Icons.priority_high, size: 13, color: fg ?? Colors.orange.shade700),
                  ],
                ),
                Text(
                  cancelled
                      ? 'supprimé'
                      : reportedCancelled
                      ? 'signalé supprimé'
                      : passed && (r != null || seen != null)
                      ? 'passé'
                      : (delay == null ? 'théorique' : '${delayLabel(delay)} ${hhmm(expected)}'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: cancelled || reportedCancelled ? FontWeight.bold : null,
                    color:
                        fg ??
                        (cancelled || reportedCancelled
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
                if (terminus)
                  Text('arrivée', style: TextStyle(fontSize: 9, color: fg ?? scheme.secondary))
                // destination affichée seulement quand elle diffère du sens principal
                else if (headsign != d.label)
                  Text(
                    '→ $headsign',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9, color: fg ?? scheme.secondary),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Horaires à $_stop'
            '${app.refreshedAt.containsKey(l.id) || _shownAt.containsKey(l.id) ? ' · $running ${vehicleWord(l.type, plural: running > 1)} en circulation dans ce sens' : ''}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
        ],
      ),
    );
  }

  /// « Je suis dedans » (GPS du téléphone) ou, en debug, simulation du même trajet.
  /// Le suivi part de l'arrêt choisi : on y monte (vrai trajet) ou le véhicule en part (simulation).
  Future<void> _startRide(_Passage p, {bool simulate = false}) async {
    final v = direction.variants[p.variant];
    try {
      await beginRide(
        app,
        line!,
        _dir,
        variant: p.variant,
        trip: p.trip,
        // simulation : le véhicule part de l'arrêt au moment de l'appui (l'écart avec l'horaire devient
        // le retard ou l'avance) ; vrai trajet : premier point à moins de 400 m de l'arrêt de montée
        startAlong: trackOf(v).stopAt[p.index],
        boardAt: simulate ? null : v.stops[p.index].pos,
        boardStop: v.stops[p.index].name,
        label: '${_capitalized(vehicleWord(line!.type))} de ${hhmm(p.time)} → ${v.headsign}',
        simulate: simulate,
      );
      // à bord : on passe à l'état de la ligne, même ligne et même sens, pour signaler
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LineStatusScreen(app: app, lineId: line!.id, dirIndex: _dir),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Position indisponible : $e')));
      }
    }
  }

  Widget _tripCard(
    BuildContext context,
    int now,
    _Passage? p,
    Map<String, CrowdEstimate> crowd,
    Map<String, List<PlacedReport>> byTrip,
  ) {
    if (p == null) return const SizedBox();
    final v = direction.variants[p.variant];
    final r = _rt(p.variant, p.trip);
    final seen = crowd[p.id];
    final delay = seen?.delaySec ?? r?.delayAt(p.index);
    final times = tripTimes(v, p.trip, r);
    final s = busStatus(v, p.trip, now, r);
    // ce qu'en dit un voyageur à bord : où il est et quand il passera à votre arrêt
    String? seenText;
    if (seen != null) {
      final n = seen.vehicle.sources;
      final who = 'Vu par ${n <= 1 ? 'un voyageur' : '$n voyageurs'} il y a ${duration(seen.ageSec)}';
      final at = seen.expectedAt(v.trips[p.trip], p.index);
      seenText = seen.passed(p.index)
          ? '$who, entre ${v.stops[seen.lastStop].name} et ${v.stops[seen.nextStop].name} : '
                'déjà passé à votre arrêt.'
          : '$who, entre ${v.stops[seen.lastStop].name} et ${v.stops[seen.nextStop].name}.\n'
                'À votre arrêt vers ${hhmm(at)} (dans ${duration(max(0, at - now))}), '
                '${p.index - seen.lastStop} arrêt(s).'
                '${seen.vehicle.concordant ? '' : '\nPositions contradictoires entre voyageurs.'}';
    }
    // en circulation, ou départ du terminus dans moins de 15 min (on monte avant le départ)
    final canBoard = s != null || (times.first > now && times.first - now <= 15 * 60);
    // simulation : passage à votre arrêt à 15 min près, avant (départ anticipé) ou après (retard)
    final canSimulate = kDebugMode && (now - p.time).abs() <= 15 * 60;
    final String where;
    if (r == null) {
      where = seen != null
          ? ''
          : app.refreshedAt.containsKey(line!.id)
          ? 'PRIM ne donne pas d\'information sur ce ${vehicleWord(line!.type)} : horaire théorique.'
          : 'Appuyez sur Actualiser pour savoir où est ce ${vehicleWord(line!.type)}.';
    } else if (r.cancelled || r.cancelledStops.contains(p.index)) {
      where = 'Course supprimée${r.cancelled ? '' : ' à votre arrêt'}.';
    } else if (s != null) {
      where =
          'A passé ${v.stops[s.lastStop].name} il y a ${duration(s.sinceSec)}.\n'
          'Prochain arrêt : ${v.stops[s.nextStop].name} dans ${duration(s.nextInSec)}.\n'
          '${s.lastStop >= p.index ? 'Déjà passé à votre arrêt.' : 'À votre arrêt dans ${duration(times[p.index] - now)} (${p.index - s.lastStop} arrêt(s)).'}';
    } else if (r.nextIndex == 0 || now < times.first) {
      where =
          'Pas encore parti de ${v.stops.first.name} (départ dans ${duration(times.first - now)}).\n'
          'À votre arrêt dans ${duration(times[p.index] - now)}.';
    } else {
      where = 'Arrivé au terminus ${v.stops.last.name}.';
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_capitalized(vehicleWord(line!.type))} de ${hhmm(p.time)} → ${v.headsign} · ${delayLabel(delay)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  if (seenText != null)
                    Text(
                      seenText,
                      style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w500),
                    ),
                  if (where.isNotEmpty) Text(seenText != null ? 'Selon PRIM : $where' : where),
                  // ce que signalent les voyageurs sur cette course
                  for (final (:report, :place, :assessment) in byTrip[p.id] ?? const <PlacedReport>[])
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(reportIcon(report.type), size: 16, color: Colors.orange.shade800),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${report.label}${place.stop == null ? '' : ' à ${place.stop!.name}'} · '
                              '${assessment.reason} · il y a '
                              '${duration(DateTime.now().millisecondsSinceEpoch ~/ 1000 - report.last)}',
                              style: TextStyle(
                                color: assessment.trust == ReportTrust.contradicted
                                    ? Theme.of(context).colorScheme.outline
                                    : Colors.orange.shade800,
                                decoration: assessment.trust == ReportTrust.contradicted
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (app.ride?.active == true && app.ride!.isTrip(line!.id, _dir, p.variant, p.trip))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => app.ride!.stop(),
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Arrêter le partage'),
                      ),
                    )
                  else if (app.ride?.active != true && !(r?.cancelled ?? false) && (canBoard || canSimulate))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          if (canBoard)
                            FilledButton.tonalIcon(
                              onPressed: () => _startRide(p),
                              icon: const Icon(Icons.person_pin_circle_outlined),
                              label: const Text('Je suis dedans'),
                            ),
                          // essais sans être dans le véhicule : compilations de debug seulement
                          if (canSimulate)
                            OutlinedButton.icon(
                              onPressed: () => _startRide(p, simulate: true),
                              icon: const Icon(Icons.science_outlined),
                              label: const Text('Simuler'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
