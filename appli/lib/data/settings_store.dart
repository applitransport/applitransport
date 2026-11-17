// Réglages de l'utilisateur, conservés sur l'appareil (settings.json).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Adresse de la publication de l'usine (GitHub Pages, mise à jour chaque jour). Pour tester une
/// usine locale : `http://<adresse du PC>:8080/` (usine/out/public servi en HTTP).
const defaultDataUrl = 'https://applitransport.github.io/donnees/';

/// Ancienne adresse par défaut (versions 1.1.x) : remplacée par [defaultDataUrl].
const _oldDataUrl = 'https://applitransport.github.io/applitransport/';

/// Aide à la création du jeton PRIM, sur le site de l'appli.
const primHelpUrl = 'https://applitransport.cypherlux.fr/prim.html';

/// Serveur communautaire (positions et signalements des voyageurs).
const defaultCommunityUrl = 'https://applitransport.cypherlux.fr/';

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
        final data = (j['data_url'] ?? defaultDataUrl) as String;
        s.dataUrl = data == _oldDataUrl ? defaultDataUrl : data;
        // adresse vide (versions précédentes) : celle par défaut
        final community = (j['community_url'] ?? '') as String;
        s.communityUrl = community.isEmpty ? defaultCommunityUrl : community;
        s.communityShow = j['community_show'] ?? true;
        s.communityShare = j['community_share'] ?? false;
        s.installKey = j['install_key'] ?? '';
        s.showMyPosition = j['show_my_position'] ?? false;
        s.lastLine = j['last_line'];
        s.lastDir = j['last_dir'] ?? 0;
        s.lastStop = j['last_stop'];
        s.favPlaces = [for (final f in (j['fav_places'] ?? const []) as List) Map<String, dynamic>.from(f)];
        s.favTrips = [for (final f in (j['fav_trips'] ?? const []) as List) Map<String, dynamic>.from(f)];
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

  /// Serveur communautaire.
  String communityUrl = defaultCommunityUrl;

  /// Afficher les véhicules vus par les voyageurs (lecture seule, rien n'est envoyé).
  bool communityShow = true;

  /// Participer : envoyer sa position pendant « Je suis dedans » (désactivé par défaut).
  bool communityShare = false;

  /// Clé d'installation (aléatoire, jamais envoyée) : sert à calculer l'empreinte du jour.
  String installKey = '';

  /// Afficher sa position sur les cartes (permission demandée une fois, dans les réglages).
  bool showMyPosition = false;

  /// Dernière ligne, sens et arrêt choisis (suivi de ligne, état de la ligne), retrouvés au retour.
  String? lastLine, lastStop;
  int lastDir = 0;

  /// Lieux favoris (Itinéraire) : {role: domicile|travail|autre, name, place: {label, detail, ref, kind}}.
  List<Map<String, dynamic>> favPlaces = [];

  /// Trajets favoris (Itinéraire, 3 au plus) : {from: lieu, to: lieu}.
  List<Map<String, dynamic>> favTrips = [];

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'token': token,
        'auto_minutes': autoMinutes,
        'theme': themeMode.name,
        'preferred': preferred,
        'data_url': dataUrl,
        'community_url': communityUrl,
        'community_show': communityShow,
        'community_share': communityShare,
        'install_key': installKey,
        'show_my_position': showMyPosition,
        'last_line': lastLine,
        'last_dir': lastDir,
        'last_stop': lastStop,
        'fav_places': favPlaces,
        'fav_trips': favTrips,
      }),
    );
    await tmp.rename(_file.path);
  }
}
