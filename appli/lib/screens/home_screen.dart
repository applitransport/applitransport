// Accueil : recherche d'une destination, mes lignes (prochains passages à mon arrêt) et les quatre
// fonctions. Rien n'est demandé à PRIM à l'ouverture : seul le bouton ↻ interroge le serveur
// communautaire et PRIM (une requête par arrêt), pour ménager le quota.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:url_launcher/url_launcher.dart';

import '../data/traffic.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/line_vehicles.dart';
import '../poc/position.dart';
import '../widgets/line_badge.dart';
import '../widgets/traffic_button.dart';
import 'itinerary_screen.dart';
import 'line_screen.dart';
import 'line_status_screen.dart';
import 'settings_screen.dart';
import 'trip_screen.dart';

/// Accent des favoris (Domicile, Travail, étoiles).
const favAccent = Color(0xFFF2A541);

/// Source d'un passage : vu par un voyageur, corrigé par PRIM, ou horaire théorique.
enum PassageSource { crowd, prim, theoretical }

/// Prochain passage d'une ligne à un arrêt.
class HomePassage {
  const HomePassage(this.time, this.source);
  final int time; // secondes du jour (heure de Paris)
  final PassageSource source;
}

/// Les [count] prochains passages de [l] (sens [dir]) à l'arrêt [stop], temps réel compris.
List<HomePassage> nextPassages(AppState app, DemoLine l, int dir, String stop, {int count = 3}) {
  if (dir >= l.directions.length) return const [];
  final d = l.directions[dir];
  final now = app.nowSec();
  final crowd = {
    for (final b in lineVehicles(app, l, d, dir, show: true))
      if (b.crowd) b.id,
  };
  final out = <HomePassage>[];
  for (var v = 0; v < d.variants.length; v++) {
    final i = d.variants[v].indexOf(stop);
    if (i < 0) continue;
    for (var t = 0; t < d.variants[v].trips.length; t++) {
      final r = app.rt(l.id, d.id, v, t);
      if (r != null && (r.cancelled || r.cancelledStops.contains(i))) continue;
      final time = tripTimes(d.variants[v], t, r)[i];
      if (time < now - 30) continue;
      out.add(
        HomePassage(
          time,
          crowd.contains('$v/$t')
              ? PassageSource.crowd
              : r != null
              ? PassageSource.prim
              : PassageSource.theoretical,
        ),
      );
    }
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out.take(count).toList();
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});
  final AppState app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppState get app => widget.app;
  Timer? _ticker;
  bool _refreshing = false;
  DateTime? _cooldownUntil;

  @override
  void initState() {
    super.initState();
    // temps restants recalculés chaque minute (et à chaque retour sur l'accueil)
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  /// ↻ : serveur communautaire et PRIM (10 s entre deux appuis).
  Future<void> _refresh() async {
    final until = _cooldownUntil;
    if (_refreshing || (until != null && DateTime.now().isBefore(until))) return;
    setState(() => _refreshing = true);
    await app.refreshHome();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _cooldownUntil = DateTime.now().add(const Duration(seconds: 10));
    });
    final msg = app.token.isEmpty
        ? 'Voyageurs actualisés (sans jeton PRIM : horaires théoriques).'
        : (app.realtimeError ?? 'Actualisé : voyageurs et temps réel PRIM.');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// Nouvelle version publiée sur GitHub : lien vers l'APK, installé par-dessus (même signature).
  Widget _updateBanner(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.primaryContainer,
    margin: const EdgeInsets.only(bottom: 16),
    child: ListTile(
      leading: const Icon(Icons.system_update),
      title: Text('Nouvelle version ${app.appUpdate!.version} disponible'),
      subtitle: const Text('Téléchargez-la puis ouvrez le fichier pour mettre à jour l\'appli.'),
      trailing: FilledButton(
        onPressed: () => launchUrl(Uri.parse(app.appUpdate!.url), mode: LaunchMode.externalApplication),
        child: const Text('Télécharger'),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // icônes de la barre d'état : claires sur le bandeau, foncées sur le reste quand on fait défiler
          AnnotatedRegion<SystemUiOverlayStyle>(value: SystemUiOverlayStyle.light, child: _header(context)),
          AnnotatedRegion<SystemUiOverlayStyle>(
            value: Theme.of(context).brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (app.appUpdate != null) _updateBanner(context),
                  _myLines(context),
                  const SizedBox(height: 20),
                  Text('Explorer', style: _sectionStyle(context)),
                  const SizedBox(height: 10),
                  _tiles(context),
                  const SizedBox(height: 24),
                  Text(
                    'Données © Île-de-France Mobilités · carte © OpenStreetMap · lieux et adresses © IGN · '
                    'entreprises © INSEE (Sirene)',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  TextStyle? _sectionStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700);

  // --- bandeau : titre, ↻, réglages, « Où allez-vous ? », raccourcis -----------------------
  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = scheme.onPrimary;
    Widget round(String tip, Widget icon, VoidCallback? onTap) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      style: IconButton.styleFrom(backgroundColor: on.withValues(alpha: 0.15), foregroundColor: on),
      icon: icon,
    );
    Widget chip(IconData icon, Color iconColor, String label, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: on.withValues(alpha: 0.15),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(color: on, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final favs = {for (final f in app.favPlaces) f['role'] as String: f};
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 12, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'AppliTransport',
                  style: Theme.of(
                    context,
                  ).textTheme.headlineSmall?.copyWith(color: on, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                ),
              ),
              round(
                'Actualiser (voyageurs et temps réel)',
                _refreshing
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: on))
                    : const Icon(Icons.refresh),
                _refreshing ? null : _refresh,
              ),
              const SizedBox(width: 8),
              round('Configuration', const Icon(Icons.settings), () => _open(SettingsScreen(app: app))),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Material(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => _open(ItineraryScreen(app: app, from: PlaceChoice.myPosition, toQuery: '')),
                child: SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      Icon(Icons.search, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Text('Où allez-vous ?', style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final role in ['domicile', 'travail'])
                  if (favs[role] case final f?)
                    chip(
                      role == 'domicile' ? Icons.home : Icons.work,
                      favAccent,
                      f['name'] as String,
                      () => _open(ItineraryScreen(app: app, from: PlaceChoice.myPosition, to: PlaceChoice.fromFav(f))),
                    ),
                chip(Icons.near_me, on, 'Près de moi', () => _open(TripScreen(app: app))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- mes lignes ------------------------------------------------------------------------
  Widget _myLines(BuildContext context) {
    final lines = app.preferred.where(app.hasSchedules).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Mes lignes', style: _sectionStyle(context))),
            TextButton(
              onPressed: () => _open(SettingsScreen(app: app)),
              child: const Text('Gérer'),
            ),
          ],
        ),
        if (lines.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Ajoutez vos lignes avec l\'étoile du Suivi de ligne : leurs prochains passages à votre arrêt '
                's\'afficheront ici.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        for (final id in lines) _lineCard(context, id),
      ],
    );
  }

  Widget _lineCard(BuildContext context, String id) {
    final scheme = Theme.of(context).colorScheme;
    final l = app.timetable(id)!;
    final info = app.line(id);
    final ls = app.lineStop(id);
    final dir = ls != null && ls.dir < l.directions.length ? ls.dir : 0;
    final d = l.directions.isEmpty ? null : l.directions[dir];
    final stop = ls?.stop;
    final passages = d == null || stop == null ? const <HomePassage>[] : nextPassages(app, l, dir, stop);
    final now = app.nowSec();
    final disruptions = (app.traffic(id) ?? const <Disruption>[])
        .where((x) => x.kind != DisruptionKind.accessibility && x.activeAt(app.now()))
        .isNotEmpty;
    Widget slot(HomePassage p) {
      final (bg, fg, label) = switch (p.source) {
        PassageSource.crowd => (const Color(0xFFE3F2E8), const Color(0xFF14532D), 'vu par un voyageur'),
        PassageSource.prim => (scheme.primaryContainer, scheme.onPrimaryContainer, 'PRIM'),
        PassageSource.theoretical => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, 'théorique'),
      };
      final left = p.time - now;
      return Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
              ),
              Text(
                left < 60 ? 'à l\'arrêt' : duration(left),
                maxLines: 1,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: fg),
              ),
              Text(hhmm(p.time), style: TextStyle(fontSize: 11, color: fg)),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          // le suivi de ligne s'ouvre sur cette ligne, ce sens et cet arrêt (sinon le premier arrêt)
          app.rememberSelection(id, dir, stop: stop);
          _open(LineScreen(app: app));
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  LineBadge(name: l.name, color: l.color, textColor: l.textColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stop == null
                              ? [
                                      info?.longLabel,
                                      info?.description,
                                    ].whereType<String>().where((x) => x.isNotEmpty).firstOrNull ??
                                    l.name
                              : '$stop → ${d!.label}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                        if (disruptions)
                          Text(
                            '⚠ Perturbation en cours',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.orange.shade800),
                          ),
                      ],
                    ),
                  ),
                  if (disruptions) TrafficButton(app: app, lineId: id, compact: true),
                  if (stop != null && l.directions.length > 1)
                    IconButton(
                      tooltip: 'Sens inverse',
                      icon: const Icon(Icons.swap_vert),
                      onPressed: () {
                        final other = 1 - dir;
                        // même arrêt dans l'autre sens s'il y passe, sinon son premier arrêt
                        final same = l.directions[other].stops.any((x) => x.name == stop);
                        app.rememberSelection(id, other, stop: same ? stop : l.directions[other].stops.first.name);
                        setState(() {});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (stop == null)
                Text(
                  'Choisir un arrêt',
                  style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
                )
              else if (passages.isEmpty)
                Text('Plus de passage aujourd\'hui.', style: TextStyle(color: scheme.onSurfaceVariant))
              else
                Row(children: [for (final p in passages) slot(p)]),
            ],
          ),
        ),
      ),
    );
  }

  // --- les quatre fonctions ----------------------------------------------------------------
  Widget _tiles(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile(IconData icon, String title, String text, Widget screen) => Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(screen),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28, color: scheme.primary),
              const SizedBox(height: 8),
              Text(title, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 2),
              Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.15,
      children: [
        tile(Icons.directions, 'Itinéraire', 'Porte à porte, avec correspondances', ItineraryScreen(app: app)),
        tile(Icons.alt_route, 'Quelle ligne prendre ?', 'Lignes directes, sans connexion', TripScreen(app: app)),
        tile(Icons.timeline, 'Suivi de ligne', 'Horaires et véhicules en direct', LineScreen(app: app)),
        tile(Icons.campaign_outlined, 'État de la ligne', 'Signalements des voyageurs', LineStatusScreen(app: app)),
      ],
    );
  }
}
