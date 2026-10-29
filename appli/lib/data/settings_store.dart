// Réglages de l'utilisateur, conservés sur l'appareil (settings.json).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Adresse de la publication de l'usine (GitHub Pages, mise à jour chaque jour). Pour tester une
/// usine locale : `http://<adresse du PC>:8080/` (usine/out/public servi en HTTP).
const defaultDataUrl = 'https://applitransport.github.io/applitransport/';

class SettingsStore {
  SettingsStore._(this._file);

  static Future<SettingsStore> open(File file) async {
    final s = SettingsStore._(file);
    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString());
        s.token = j['token'] ?? '';
        s.autoMinutes = j['auto_minutes'] ?? 5;
        s.themeMode = ThemeMode.values.byName(j['theme'] ?? 'system');
        s.preferred = List<String>.from(j['preferred'] ?? const []);
        s.dataUrl = j['data_url'] ?? defaultDataUrl;
      } on FormatException {
        // fichier abîmé : on repart des réglages par défaut
      }
    }
    return s;
  }

  final File _file;
  String token = '';
  int autoMinutes = 5;
  ThemeMode themeMode = ThemeMode.system;
  List<String> preferred = [];
  String dataUrl = defaultDataUrl;

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'token': token,
      'auto_minutes': autoMinutes,
      'theme': themeMode.name,
      'preferred': preferred,
      'data_url': dataUrl,
    }));
    await tmp.rename(_file.path);
  }
}
