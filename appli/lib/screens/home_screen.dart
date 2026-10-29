// Accueil : choix du cas d'usage.
import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    Widget useCase(IconData icon, String title, String text, Widget screen) => Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(context, screen),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Icon(icon, size: 44, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(text),
                  ]),
                ),
                const Icon(Icons.chevron_right),
              ]),
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
      body: ListView(padding: const EdgeInsets.all(16), children: [
        useCase(Icons.timeline, 'Suivi d\'une ligne',
            'Horaires à un arrêt et position des bus sur la ligne.', LineScreen(app: app)),
        const SizedBox(height: 12),
        useCase(Icons.alt_route, 'Arrêt → destination',
            'Tous les bus directs vers votre arrêt d\'arrivée.', TripScreen(app: app)),
        const SizedBox(height: 12),
        useCase(Icons.directions, 'Itinéraire',
            'Depuis ma position, une adresse ou un arrêt, avec correspondances (internet).', ItineraryScreen(app: app)),
        const SizedBox(height: 24),
        Text('POC IHM : données de démonstration, temps réel simulé.',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
