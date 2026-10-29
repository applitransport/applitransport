import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/prim.dart';
import 'data/repository.dart';
import 'data/settings_store.dart';
import 'poc/app_state.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // données et carte, en plus des bibliothèques que Flutter liste d'office (écran « Licences »)
  LicenseRegistry.addLicense(() => Stream.fromIterable([
        const LicenseEntryWithLineBreaks(['Données Île-de-France Mobilités'],
            'Horaires, arrêts, temps réel, perturbations et itinéraires © Île-de-France Mobilités, '
            'Open Database License (ODbL) 1.0 : https://opendatacommons.org/licenses/odbl/1-0/'),
        const LicenseEntryWithLineBreaks(['Carte OpenStreetMap'],
            '© contributeurs OpenStreetMap, ODbL : https://www.openstreetmap.org/copyright'),
      ]));
  // données conservées sur l'appareil (Linux : ~/.local/share/fr.applitransport.app)
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/donnees');
  await dir.create(recursive: true);
  final settings = await SettingsStore.open(File('${dir.path}/settings.json'));
  final repo = await Repository.open(dir: dir, baseUrl: settings.dataUrl);
  final usage = RequestUsage(File('${dir.path}/requests.json'));
  final app = AppState(repo, settings, usage);
  runApp(BusApp(app: app));
  app.dailyCheck();
}

const _seed = Color(0xFF1B5E7A);

class BusApp extends StatelessWidget {
  const BusApp({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) => MaterialApp(
          title: 'AppliTransport',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
          darkTheme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.dark, useMaterial3: true),
          themeMode: app.themeMode,
          home: HomeScreen(app: app),
        ),
      );
}
