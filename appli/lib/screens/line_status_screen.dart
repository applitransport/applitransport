// État de la ligne : ligne et sens → véhicules sur la carte (verts : vus par un voyageur, rouges :
// PRIM ou horaire) et signalements en cours des voyageurs (bloqué, incidents, affluence, supprimé…).
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/community.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/line_vehicles.dart';
import '../poc/position.dart';
import '../poc/ride_control.dart';
import '../widgets/line_badge.dart';
import '../widgets/line_map.dart';
import '../widgets/refresh_controls.dart';
import '../widgets/ride_widgets.dart';
import '../widgets/traffic_button.dart';

class LineStatusScreen extends StatefulWidget {
  const LineStatusScreen({super.key, required this.app, this.lineId, this.dirIndex = 0});
  final AppState app;

  /// Ouverture sur une ligne et un sens (montée à bord depuis le suivi de ligne).
  final String? lineId;
  final int dirIndex;

  @override
  State<LineStatusScreen> createState() => _LineStatusScreenState();
}

class _LineStatusScreenState extends State<LineStatusScreen> {
  String? _lineId;
  int _dir = 0;
  Timer? _ticker;

  /// Dernier appui sur Actualiser, par ligne : les véhicules sont alors affichés.
  final Map<String, DateTime> _shownAt = {};

  /// Lignes d'état et boutons masqués : la carte prend la place.
  bool _panelHidden = false;

  /// Bus touché sur la carte (« variante/course ») : sa fiche s'affiche, la liste ne montre que ses
  /// signalements.
  String? _selected;

  AppState get app => widget.app;
  DemoLine? get line => _lineId == null ? null : app.timetable(_lineId!);
  bool get _usable => line != null && line!.directions.isNotEmpty;
  Direction get direction => line!.directions[_dir];

  @override
  void initState() {
    super.initState();
    // ligne demandée (montée depuis le suivi), sinon dernière sélection, sinon première préférée
    final last = app.lastSelection;
    if (widget.lineId != null && app.hasSchedules(widget.lineId!)) {
      _lineId = widget.lineId;
      if (_usable && widget.dirIndex < line!.directions.length) _dir = widget.dirIndex;
    } else if (last.line != null && app.hasSchedules(last.line!)) {
      _lineId = last.line;
      if (_usable && last.dir < line!.directions.length) _dir = last.dir;
    } else {
      _lineId = app.preferred.where(app.hasSchedules).firstOrNull;
    }
    if (_lineId != null) app.loadTraffic(_lineId!);
    // les véhicules avancent entre deux requêtes : on redessine chaque seconde
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _select({String? lineId, int? dir}) => setState(() {
    if (lineId != null) {
      _lineId = lineId;
      _dir = 0;
      app.loadTraffic(lineId);
    }
    if (dir != null) _dir = dir;
    _selected = null;
    app.rememberSelection(_lineId, _dir);
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('État de la ligne')),
      body: SafeArea(
        top: false,
        child: line == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Aucune ligne préférée téléchargée.\nAjoutez-en dans Configuration › Lignes.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
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

  Widget _body(BuildContext context) {
    final l = line!, d = direction;
    final refreshed = app.refreshedAt[l.id];
    final reports = placedReports(app, l, d);
    final buses = lineVehicles(
      app,
      l,
      d,
      _dir,
      show: _shownAt.containsKey(l.id) || refreshed != null,
      ride: app.ride,
      alerts: alertTrips(reports),
      selected: _selected,
    );
    return Column(
      children: [
        _selectors(context),
        if (app.ride != null) RideBanner(app: app),
        Expanded(
          child: Stack(
            children: [
              LineMap(
                showMe: app.showMyPosition,
                key: ValueKey('${l.id}/$_dir'),
                vehicleIcon: vehicleIcon(l.type),
                confirmationColors: true,
                shapes: [for (final v in d.variants) v.shape],
                stops: d.stops,
                color: l.color,
                buses: buses,
                alertStops: alertStops(reports),
                // toucher un bus : sa fiche ; le retoucher : la referme
                onBusTap: (id) => setState(() => _selected = _selected == id ? null : id),
              ),
              if (_selected != null) Positioned(left: 0, right: 0, bottom: 0, child: _busCard(context)),
            ],
          ),
        ),
        // police système agrandie : les boutons restent sur une ligne
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.0,
          child: RefreshControls(
            key: ValueKey(l.id),
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
            showInfo: !_panelHidden,
            autoMinutes: app.autoMinutes,
            lastRefresh: refreshed,
            now: app.now,
            error: app.token.isEmpty ? null : app.realtimeError,
            middle: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                    onPressed: _openReports,
                    icon: Badge(
                      label: Text('${_shownReports().shown.length}'),
                      isLabelVisible: _shownReports().shown.isNotEmpty,
                      child: const Icon(Icons.campaign_outlined),
                    ),
                    label: const Text('Signalements'),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: _panelHidden ? 'Afficher les boutons' : 'Masquer les boutons',
                    onPressed: () => setState(() => _panelHidden = !_panelHidden),
                    icon: Icon(_panelHidden ? Icons.expand_less : Icons.expand_more),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!_panelHidden) _actions(context),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _selectors(BuildContext context) {
    final lines = {...app.preferred.where(app.hasSchedules), ?_lineId}.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
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
    );
  }

  /// Fiche du bus touché : son nom (même repère que les signalements), où il est et selon qui, et
  /// « À bord » si l'usager n'y est pas déjà.
  Widget _busCard(BuildContext context) {
    final l = line!, d = direction, now = app.nowSec();
    final (v, t) = _selectedTrip!;
    final variant = d.variants[v];
    final seen = crowdEstimates(app, l, d)['$v/$t'];
    final rt = app.rt(l.id, d.id, v, t);
    final s = busStatus(variant, t, now, rt);
    final String where;
    if (seen != null) {
      final n = seen.vehicle.sources;
      where =
          'Vu par ${n <= 1 ? 'un voyageur' : '$n voyageurs'} il y a ${duration(seen.ageSec)}, entre '
          '${variant.stops[seen.lastStop].name} et ${variant.stops[seen.nextStop].name} · ${delayLabel(seen.delaySec)}';
    } else if (s != null) {
      where =
          '${rt != null ? 'Selon PRIM' : 'Position théorique'} : entre ${variant.stops[s.lastStop].name} et '
          '${variant.stops[s.nextStop].name}${rt != null ? ' · ${delayLabel(rt.delayAt(s.nextStop))}' : ''}';
    } else {
      where = 'Pas en circulation selon l\'horaire.';
    }
    final aboard = app.ride?.active == true && app.ride!.isTrip(l.id, _dir, v, t);
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
                  Text(tripName(l, d, v, t), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(where, style: seen != null ? TextStyle(color: Colors.green.shade700) : null),
                  if (aboard)
                    const Padding(padding: EdgeInsets.only(top: 6), child: Text('Vous êtes à bord de ce bus.'))
                  else if (app.ride?.active != true && (seen != null || s != null))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FilledButton.tonalIcon(
                        onPressed: () => boardSelected(context, app, l, _dir, v, t),
                        icon: const Icon(Icons.person_pin_circle_outlined),
                        label: const Text('À bord'),
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

  /// Bus sélectionné (variante, course), ou null.
  (int, int)? get _selectedTrip {
    final parts = _selected?.split('/');
    return parts == null ? null : (int.parse(parts[0]), int.parse(parts[1]));
  }

  /// À bord (voyant allumé quand on l'est ; sinon monte si l'association est sûre), À l'arrêt, Sorti ;
  /// à bord de ce sens : Bloqué, Incident, Affluence.
  Widget _actions(BuildContext context) {
    final l = line!;
    final aboard = rideOn(app.ride, l.id, _dir);
    final busyElsewhere = !aboard && app.ride?.active == true; // à bord sur une autre ligne ou l'autre sens
    final scheme = Theme.of(context).colorScheme;
    Widget row(List<Widget> tiles) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(width: 6), Expanded(child: tiles[i])],
        ],
      ),
    );
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          children: [
            row([
              // voyant : à bord, un appui ne fait rien ; sinon montée si l'association est sûre
              _tile(
                aboard ? Icons.person_pin_circle : Icons.person_pin_circle_outlined,
                'À bord',
                aboard ? () {} : (busyElsewhere ? null : () => boardNearest(context, app, l, _dir)),
                filled: aboard,
              ),
              _tile(Icons.place_outlined, 'À l\'arrêt', _atStop),
              _tile(
                Icons.logout,
                'Sorti',
                app.ride?.active == true
                    ? () {
                        app.ride!.stop();
                        app.setRide(null);
                      }
                    : null,
                color: scheme.error,
              ),
            ]),
            if (aboard)
              row([
                _tile(Icons.front_hand_outlined, 'Bloqué', () => _report('retard', 'bloque')),
                _tile(Icons.warning_amber, 'Incident', () => _choose('incident', 'Quel incident ?')),
                _tile(Icons.groups, 'Affluence', () => _choose('affluence', 'Affluence à bord')),
              ]),
          ],
        ),
      ),
    );
  }

  /// Bouton compact : icône au-dessus d'un libellé court, sur une ligne.
  Widget _tile(IconData icon, String label, VoidCallback? onPressed, {bool filled = false, Color? color}) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      ],
    );
    const pad = EdgeInsets.symmetric(vertical: 6, horizontal: 4);
    return filled
        ? FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              padding: pad,
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: child,
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              padding: pad,
              foregroundColor: color,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: child,
          );
  }

  /// « Je suis à l'arrêt » : arrêt, puis passage concerné (30 min avant à 20 min après maintenant),
  /// puis « Pas encore passé » ou « Supprimé ».
  Future<void> _atStop() async {
    final l = line!, d = direction, now = app.nowSec(), word = vehicleWord(l.type);
    final stop = await _pick<String>('À quel arrêt êtes-vous ?', {for (final s in d.stops) s.name: s.name});
    if (stop == null || !mounted) return;
    final crowd = crowdEstimates(app, l, d);
    final passages = <(int, int, int, int)>[]; // variante, course, index de l'arrêt, heure théorique
    for (var v = 0; v < d.variants.length; v++) {
      final i = d.variants[v].indexOf(stop);
      if (i < 0) continue;
      for (var t = 0; t < d.variants[v].trips.length; t++) {
        final at = d.variants[v].trips[t][i];
        if (at >= now - 30 * 60 && at <= now + 20 * 60) passages.add((v, t, i, at));
      }
    }
    passages.sort((a, b) => a.$4.compareTo(b.$4));
    if (passages.isEmpty) return _tell('Aucun passage à $stop entre 30 min avant et 20 min après maintenant.');
    String describe((int, int, int, int) p) {
      final (v, t, i, at) = p;
      final seen = crowd['$v/$t'];
      final rt = app.rt(l.id, d.id, v, t);
      final delay = seen?.delaySec ?? rt?.delayAt(i);
      final source = seen != null ? 'selon un voyageur' : (rt != null ? 'selon PRIM' : 'théorique');
      return '${hhmm(at)} à $stop · ${vehicleWord(l.type)} de ${hhmm(d.variants[v].trips[t].first)} '
          '(départ ${d.variants[v].stops.first.name}) → ${d.variants[v].headsign}\n'
          '${delay == null ? source : '${delayLabel(delay)} $source'}';
    }

    final chosen = await _pick<(int, int, int, int)>('Quel passage ?', {for (final p in passages) describe(p): p});
    if (chosen == null || !mounted) return;
    final detail = await _pick<String>('${capitalized(word)} de ${hhmm(chosen.$4)} à $stop', {
      'Pas encore passé': 'pas_passe',
      'Supprimé': 'supprime',
    });
    if (detail == null || !mounted) return;
    final v = d.variants[chosen.$1];
    if (!await ensureParticipation(context, app)) return;
    try {
      await app.sendReport(
        l.id,
        detail == 'supprime' ? 'supprime' : 'retard',
        detail,
        course: courseId(v, chosen.$2),
        stop: stopId(v, chosen.$3),
      );
      if (mounted) _tell('Signalé : ${reportLabel(detail == 'supprime' ? 'supprime' : 'retard', detail)}');
    } catch (e) {
      if (mounted) _tell('Signalement non envoyé : $e');
    }
  }

  /// Liste de choix en bas de l'écran : libellé → valeur.
  Future<T?> _pick<T>(String title, Map<String, T> options) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            for (final e in options.entries) ListTile(title: Text(e.key), onTap: () => Navigator.pop(context, e.value)),
          ],
        ),
      ),
    ),
  );

  /// Choix d'une valeur (type d'incident, niveau d'affluence) puis envoi.
  Future<void> _choose(String type, String title) async {
    final detail = await _pick<String>(title, {for (final e in reportDetails[type]!.entries) e.value: e.key});
    if (detail != null) await _report(type, detail);
  }

  /// Signalement à bord : il porte sur la course où l'on est et, sauf l'affluence, sur le dernier
  /// arrêt passé.
  Future<void> _report(String type, String detail) async {
    final ride = app.ride!, l = line!;
    final v = l.directions[ride.direction].variants[ride.variant];
    if (!await ensureParticipation(context, app)) return;
    final at = ride.tracker.last?.prevStop;
    try {
      await app.sendReport(
        l.id,
        type,
        detail,
        course: courseId(v, ride.trip),
        stop: type == 'affluence' || at == null ? null : stopId(v, at),
      );
      if (mounted) _tell('Signalé : ${reportLabel(type, detail)}');
    } catch (e) {
      if (mounted) _tell('Signalement non envoyé : $e');
    }
  }

  void _tell(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// Signalements du sens affiché ; un bus touché ne garde que les siens.
  ({List<PlacedReport> all, List<PlacedReport> shown, (int, int)? sel}) _shownReports() {
    final all = placedReports(app, line!, direction);
    final sel = _selectedTrip;
    return (
      all: all,
      shown: sel == null
          ? all
          : [
              for (final p in all)
                if (p.place.variant == sel.$1 && p.place.trip == sel.$2) p,
            ],
      sel: sel,
    );
  }

  /// Fenêtre des signalements, presque plein écran, qui suit les mises à jour.
  void _openReports() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: StatefulBuilder(
        builder: (context, setSheet) => ListenableBuilder(
          listenable: app,
          builder: (context, _) => _reports(context, () {
            setState(() => _selected = null);
            setSheet(() {});
          }),
        ),
      ),
    ),
  );

  /// Contenu de la fenêtre ; [clearFilter] : revenir à tous les signalements de la ligne.
  Widget _reports(BuildContext context, VoidCallback clearFilter) {
    if (line == null || !_usable) return const SizedBox();
    final l = line!, d = direction;
    final cl = app.communityLines[l.id];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final (:all, :shown, :sel) = _shownReports();
    final others = all.length - shown.length;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Expanded(child: Text('Signalements des voyageurs', style: Theme.of(context).textTheme.titleMedium)),
              if (sel != null)
                InputChip(
                  label: Text('${capitalized(vehicleWord(l.type))} de ${hhmm(d.variants[sel.$1].trips[sel.$2].first)}'),
                  onDeleted: clearFilter,
                ),
              IconButton(tooltip: 'Fermer', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              if (!app.community.configured)
                const Text('Renseignez l\'adresse du serveur communautaire dans Configuration › Général.')
              else if (cl == null)
                const Text('Appuyez sur Actualiser pour lire les signalements.')
              else if (shown.isEmpty)
                Text(sel == null ? 'Aucun signalement en cours dans ce sens.' : 'Aucun signalement sur ce bus.'),
              for (final (:report, :place, :assessment) in shown)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    reportIcon(report.type),
                    color: assessment.trust == ReportTrust.confirmed
                        ? (report.type == 'affluence' ? scheme.primary : scheme.error)
                        : scheme.outline,
                  ),
                  title: Text(
                    report.label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: assessment.trust == ReportTrust.confirmed ? null : scheme.outline,
                      decoration: assessment.trust == ReportTrust.contradicted ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  subtitle: Text(
                    '${placeLabel(l, d, place)}\n${assessment.reason} · il y a ${duration(now - report.last)}',
                  ),
                ),
              if (sel != null && others > 0)
                TextButton(
                  onPressed: clearFilter,
                  child: Text('+ $others signalement${others > 1 ? 's' : ''} sur la ligne'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
