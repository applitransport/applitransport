// Cas 3 : itinéraire avec correspondances (calculateur IDFM, internet nécessaire).
// Départ / arrivée : ma position (GPS), un arrêt (catalogue, sans requête) ou une adresse (calculateur).
// Rechercher = 1 requête « calculateur » ; Actualiser = 1 requête « arrêt » par arrêt de montée,
// qui corrige chaque étape en transport (le calculateur n'applique le temps réel qu'à certains trains).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../data/realtime.dart';
import '../data/traffic.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/itineraries.dart';
import '../poc/position.dart';
import '../widgets/line_badge.dart';
import '../widgets/refresh_controls.dart';
import 'line_screen.dart';

IconData modeIcon(String? mode) {
  final m = (mode ?? '').toLowerCase();
  if (m.contains('bus')) return Icons.directions_bus;
  if (m.contains('tram')) return Icons.tram;
  if (m.contains('métro') || m.contains('metro')) return Icons.subway;
  return Icons.train;
}

/// Lieu choisi : [ref] = identifiant pour le calculateur (null : ma position, résolue au moment de chercher).
class PlaceChoice {
  const PlaceChoice(this.label, this.detail, this.ref, this.kind);
  final String label, detail;
  final String? ref;
  final String kind; // position, arret, adresse
  static const myPosition = PlaceChoice('Ma position', 'GPS du téléphone', null, 'position');
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
  const ItineraryScreen({super.key, required this.app});
  final AppState app;

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
    if (!await Geolocator.isLocationServiceEnabled()) throw 'localisation désactivée sur l\'appareil';
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'position refusée';
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
    try {
      final n = app.now();
      final t = _time ?? TimeOfDay.fromDateTime(n);
      final when = _when == 0 ? n : DateTime(n.year, n.month, n.day, t.hour, t.minute);
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
        appBar: AppBar(title: const Text('Itinéraire')),
        body: SafeArea(
          top: false,
          child: Column(children: [
            _form(context),
            if (_search != null && _search!.journeys.isNotEmpty)
              RefreshControls(
                key: ValueKey(_search),
                onRefresh: _refresh,
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
          ]),
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final time = _time ?? TimeOfDay.fromDateTime(app.now());
    return Padding(
      key: _fieldsKey,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Column(children: [
              _PlaceField(app: app, label: 'Départ', icon: Icons.trip_origin, value: _from, onSet: (p) => _from = p),
              const SizedBox(height: 8),
              _PlaceField(app: app, label: 'Arrivée', icon: Icons.flag, value: _to, onSet: (p) => _to = p),
            ]),
          ),
          IconButton(
            tooltip: 'Inverser',
            icon: const Icon(Icons.swap_vert),
            onPressed: () => setState(() {
              final f = _from;
              _from = _to;
              _to = f;
              _fieldsKey = UniqueKey();
            }),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Maintenant')),
                ButtonSegment(value: 1, label: Text('Partir à')),
                ButtonSegment(value: 2, label: Text('Arriver')),
              ],
              selected: {_when},
              onSelectionChanged: (s) async {
                final w = s.first;
                if (w != 0) {
                  final t = await showTimePicker(context: context, initialTime: time);
                  if (t == null) return;
                  _time = t;
                }
                setState(() => _when = w);
              },
            ),
          ),
          if (_when != 0) Padding(padding: const EdgeInsets.only(left: 8), child: Text(time.format(context))),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _searching ? null : _run,
            icon: _searching
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: const Text('Rechercher'),
          ),
        ),
      ]),
    );
  }

  Widget _results(BuildContext context) {
    final s = _search;
    if (s == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Itinéraires porte à porte, avec correspondances, calculés par Île-de-France Mobilités.\n'
              'Nécessite internet et le jeton PRIM.', textAlign: TextAlign.center),
        ),
      );
    }
    final now = app.nowSec();
    return ValueListenableBuilder(
      valueListenable: _realtime,
      builder: (context, rt, _) => ListView(padding: const EdgeInsets.fromLTRB(8, 4, 8, 12), children: [
        for (var i = 0; i < s.journeys.length; i++)
          _JourneyCard(
            search: s,
            timed: _Timed(s.journeys[i], i, rt),
            now: now,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _DetailScreen(app: app, search: s, index: i, realtime: _realtime))),
          ),
      ]),
    );
  }
}

/// Champ de lieu : ma position, arrêts du catalogue (sur l'appareil), adresses (calculateur).
class _PlaceField extends StatelessWidget {
  const _PlaceField({required this.app, required this.label, required this.icon, required this.value, required this.onSet});
  final AppState app;
  final String label;
  final IconData icon;
  final PlaceChoice? value;
  final void Function(PlaceChoice?) onSet;

  static String _latest = '';

  String _networks(StopArea a) {
    final n = {for (final id in a.lines) app.networks[app.line(id)?.network] ?? ''}.where((x) => x.isNotEmpty).take(2);
    return n.isEmpty ? '' : ' · ${n.join(' · ')}';
  }

  Future<List<PlaceChoice>> _options(String text) async {
    final q = text.toLowerCase().trim();
    final stops = q.length >= 2 ? searchStopAreas(app.stopAreas.values, q, limit: 6) : const <StopArea>[];
    final local = <PlaceChoice>[
      if (q.isEmpty || 'ma position'.contains(q)) PlaceChoice.myPosition,
      for (final a in stops)
        PlaceChoice(a.label, '${a.town.isEmpty ? 'Arrêt' : a.town} · ${a.lines.length} ligne(s)${_networks(a)}',
            'stop_area:${a.id}', 'arret'),
    ];
    // adresses demandées au calculateur seulement si c'est probablement une adresse (numéro de rue)
    // ou si peu d'arrêts correspondent : chaque recherche d'adresse coûte une requête
    if (q.length < 4 || !(RegExp(r'\d').hasMatch(q) || stops.length < 3)) return local;
    // adresses : une requête « calculateur », seulement quand la frappe s'arrête
    _latest = q;
    await Future.delayed(const Duration(milliseconds: 700));
    if (_latest != q) return local;
    final addresses = await app.searchAddresses(text.trim());
    return [...local, for (final (name, id) in addresses) PlaceChoice(name, 'Adresse', id, 'adresse')];
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
              child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                for (final p in options)
                  ListTile(
                    dense: true,
                    leading: Icon(switch (p.kind) {
                      'position' => Icons.my_location,
                      'arret' => Icons.place_outlined,
                      _ => Icons.home_outlined,
                    }),
                    title: Text(p.label),
                    subtitle: Text(p.detail),
                    onTap: () => onSelected(p),
                  ),
              ]),
            ),
          ),
        ),
        fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
          controller: ctrl,
          focusNode: focus,
          onChanged: (_) => onSet(null), // texte modifié : il faut rechoisir une proposition
          decoration: InputDecoration(
            labelText: label,
            hintText: 'Ma position, adresse ou arrêt',
            prefixIcon: Icon(icon),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
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
        steps.add(Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(modeIcon(s.mode), size: 16),
            const SizedBox(width: 2),
            LineBadge(name: s.lineCode ?? '?', color: s.color, textColor: s.textColor, small: true),
          ]),
          if (r != null)
            Text(r.cancelled ? 'supprimé' : delayLabel(r.delay),
                style: TextStyle(fontSize: 10, color: _delayColor(context, r.cancelled ? 999 : r.delay))),
        ]));
      } else {
        steps.add(Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.directions_walk, size: 16),
          Text('${(s.duration / 60).ceil()}', style: const TextStyle(fontSize: 12)),
        ]));
      }
    }
    final broken = timed.brokenAt;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${hhmm(timed.start)} → ${hhmm(timed.end)}', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Flexible(
                child: Text('${duration(timed.end - timed.start)} · '
                    '${j.transit.isEmpty ? 'à pied' : j.transfers == 0 ? 'direct' : '${j.transfers} corresp.'}'),
              ),
              const Spacer(),
              Text(timed.start <= now ? 'en cours' : 'dans ${duration(timed.start - now)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 2, runSpacing: 4, children: steps),
            if (broken != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    timed.realtime[broken]?.cancelled == true
                        ? '⚠ ${j.sections[broken].lineCode} supprimé : relancez la recherche'
                        : '⚠ Correspondance compromise à ${j.sections[broken].from?.name} : relancez la recherche',
                    style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold)),
              ),
            if (disruptions > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('ⓘ $disruptions perturbation(s) sur le parcours',
                    style: TextStyle(fontSize: 12, color: scheme.tertiary)),
              ),
          ]),
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
            body: Column(children: [
              Expanded(flex: 4, child: _map(context, j)),
              Expanded(
                flex: 5,
                child: ListView(padding: const EdgeInsets.all(12), children: [
                  if (t.brokenAt != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.warning_amber),
                        title: Text(t.realtime[t.brokenAt!]?.cancelled == true
                            ? '${j.sections[t.brokenAt!].lineCode} supprimé'
                            : 'Correspondance compromise à ${j.sections[t.brokenAt!].from?.name}'),
                        subtitle: const Text('Relancez la recherche pour un autre itinéraire.'),
                      ),
                    ),
                  for (var k = 0; k < j.sections.length; k++) _step(context, t, k),
                ]),
              ),
            ]),
          );
        },
      );

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
        PolylineLayer(polylines: [
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
                      pattern: const StrokePattern.dotted(spacingFactor: 1.6)),
        ]),
        CircleLayer(circles: [
          for (final s in j.transit) ...[
            if (s.from != null)
              CircleMarker(point: s.from!.pos, radius: 6, color: Colors.white, borderColor: s.color, borderStrokeWidth: 3),
            if (s.to != null)
              CircleMarker(point: s.to!.pos, radius: 6, color: Colors.white, borderColor: s.color, borderStrokeWidth: 3),
          ],
        ]),
        MarkerLayer(markers: [
          if (first != null) Marker(point: first.pos, child: const Icon(Icons.trip_origin, color: Colors.green, size: 22)),
          if (last != null)
            Marker(point: last.pos, alignment: Alignment.topCenter, child: const Icon(Icons.flag, color: Colors.red, size: 28)),
        ]),
        const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
      ],
    );
  }

  Widget _step(BuildContext context, _Timed t, int k) {
    final s = t.journey.sections[k];
    final scheme = Theme.of(context).colorScheme;
    switch (s.type) {
      case 'wait':
        return ListTile(dense: true, leading: const Icon(Icons.hourglass_empty), title: Text('Attente ${duration(s.duration)}'));
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
        if (search.disruptions[id] != null) search.disruptions[id]!.title
    }.where((x) => x.isNotEmpty).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(modeIcon(s.mode)),
            const SizedBox(width: 6),
            LineBadge(name: s.lineCode ?? '?', color: s.color, textColor: s.textColor),
            const SizedBox(width: 6),
            Expanded(child: Text('${s.mode} → ${s.direction}', overflow: TextOverflow.ellipsis)),
            if (r != null)
              Text(r.cancelled ? 'supprimé' : delayLabel(r.delay),
                  style: TextStyle(color: _delayColor(context, r.cancelled ? 999 : r.delay), fontWeight: FontWeight.bold)),
          ]),
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
                  Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $x', style: const TextStyle(fontSize: 12))),
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
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                    : TextButton.icon(
                        icon: Icon(app.hasSchedules(lineId) ? Icons.timeline : Icons.download),
                        label: Text('${app.hasSchedules(lineId) ? '' : 'Télécharger et '}suivre ce '
                            '${(s.mode ?? '').toLowerCase().contains('bus') ? 'bus' : 'train'}'),
                        onPressed: () async {
                          // ligne absente de l'appareil : on la télécharge d'abord (quelques Ko)
                          if (!app.hasSchedules(lineId)) await app.download(lineId);
                          if (!context.mounted || !app.hasSchedules(lineId)) return;
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => LineScreen(app: app, lineId: lineId, fromArea: s.from?.area, toArea: s.to?.area)));
                        },
                      ),
              ),
            ),
        ]),
      ),
    );
  }
}
