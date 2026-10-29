// Accueil : choix du cas d'usage.
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import '../poc/app_state.dart';
import 'itinerary_screen.dart';
import 'line_screen.dart';
import 'settings_screen.dart';
import 'trip_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.app});
  final AppState app;

  void _open(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

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
  Widget build(BuildContext context) {
    Widget useCase(IconData icon, String title, String text, Widget screen) => Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context, screen),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 44, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(text),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('AppliTransport'),
        actions: [
          IconButton(
            tooltip: 'Configuration',
            icon: const Icon(Icons.settings),
            onPressed: () => _open(context, SettingsScreen(app: app)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (app.appUpdate != null) _updateBanner(context),
          useCase(
            Icons.timeline,
            'Suivi d\'une ligne',
            'Horaires à un arrêt et position des bus sur la ligne.',
            LineScreen(app: app),
          ),
          const SizedBox(height: 12),
          useCase(
            Icons.alt_route,
            'Arrêt → destination',
            'Tous les bus directs vers votre arrêt d\'arrivée.',
            TripScreen(app: app),
          ),
          const SizedBox(height: 12),
          useCase(
            Icons.directions,
            'Itinéraire',
            'Depuis ma position, une adresse ou un arrêt, avec correspondances (internet).',
            ItineraryScreen(app: app),
          ),
          const SizedBox(height: 24),
          Text(
            'Données © Île-de-France Mobilités · carte © OpenStreetMap',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
