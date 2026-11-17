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
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: scheme.surfaceContainerLow,
        // une seule page : bandeau, deux lignes favorites, les quatre fonctions en bas (défile seulement
        // si l'écran est trop petit)
        body: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnnotatedRegion<SystemUiOverlayStyle>(value: SystemUiOverlayStyle.light, child: _header(context)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [if (app.appUpdate != null) _updateBanner(context), _myLines(context)],
                      ),
                    ),
                    const Spacer(),
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _tiles(context),
                          const SizedBox(height: 10),
                          Text(
                            'Données © Île-de-France Mobilités · carte © OpenStreetMap · lieux et adresses © IGN · '
                            'entreprises © INSEE (Sirene)',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  TextStyle? _sectionStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700);

  /// Carte blanche arrondie et ombrée (style de la maquette).
  BoxDecoration _card(BuildContext context, {double radius = 20}) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(color: Color(0x0F14212B), blurRadius: 2, offset: Offset(0, 1)),
        BoxShadow(color: Color(0x1214212B), blurRadius: 18, offset: Offset(0, 6)),
      ],
    );
  }

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

  // --- lignes favorites (les deux premières) ---------------------------------------------
  Widget _myLines(BuildContext context) {
    final all = app.preferred.where(app.hasSchedules).toList();
    final lines = all.take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Lignes favorites', style: _sectionStyle(context))),
            TextButton(
              onPressed: () => _open(LineScreen(app: app)),
              child: Text(all.length > 2 ? 'Toutes (${all.length})' : 'Suivi de ligne'),
            ),
          ],
        ),
        if (lines.isEmpty)
          Container(
            decoration: _card(context),
            padding: const EdgeInsets.all(16),
            child: const Text(
              'Ajoutez vos lignes avec l\'étoile du Suivi de ligne : les prochains passages à votre arrêt '
              's\'afficheront ici.',
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
        PassageSource.theoretical => (scheme.surfaceContainerHigh, scheme.onSurfaceVariant, 'théorique'),
      };
      final left = p.time - now;
      return Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
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
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: fg, letterSpacing: -0.3),
              ),
              Text(hhmm(p.time), style: TextStyle(fontSize: 11, color: fg)),
            ],
          ),
        ),
      );
    }

    final title = stop == null
        ? [info?.longLabel, info?.description].whereType<String>().where((x) => x.isNotEmpty).firstOrNull ?? l.name
        : '$stop → ${d!.label}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            // le suivi de ligne s'ouvre sur cette ligne, ce sens et cet arrêt (sinon le premier arrêt)
            app.rememberSelection(id, dir, stop: stop);
            _open(LineScreen(app: app));
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
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
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                          ),
                          if (disruptions)
                            Text(
                              '⚠ Perturbation en cours',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.orange.shade800,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (disruptions) TrafficButton(app: app, lineId: id, compact: true),
                    if (stop != null && l.directions.length > 1)
                      IconButton.outlined(
                        tooltip: 'Sens inverse',
                        icon: const Icon(Icons.swap_vert, size: 20),
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
      ),
    );
  }

  // --- les quatre fonctions, en bas ----------------------------------------------------------
  Widget _tiles(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile(IconData icon, String title, String text, Widget screen) => Expanded(
      child: Container(
        decoration: _card(context, radius: 18),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => _open(screen),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(icon, size: 26, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            tile(Icons.directions, 'Itinéraire', 'Porte à porte', ItineraryScreen(app: app)),
            const SizedBox(width: 10),
            tile(Icons.alt_route, 'Quelle ligne ?', 'Sans connexion', TripScreen(app: app)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            tile(Icons.timeline, 'Suivi de ligne', 'Bus en direct', LineScreen(app: app)),
            const SizedBox(width: 10),
            tile(Icons.campaign_outlined, 'État de la ligne', 'Signalements', LineStatusScreen(app: app)),
          ],
        ),
      ],
    );
  }
}
