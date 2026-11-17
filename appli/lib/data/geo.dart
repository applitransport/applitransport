// Position du téléphone par la localisation standard d'Android (GPS, et réseau si le téléphone en
// fournit un), sans les services Google : remplace la bibliothèque geolocator, dont il reprend les noms
// (Geolocator, Position, LocationPermission…) pour que le reste de l'appli ne change pas.
// Côté Android : MainActivity.kt (canaux « fr.applitransport/location »).
import 'dart:async';
import 'dart:math' show cos, sqrt;

import 'package:flutter/services.dart';

enum LocationPermission { denied, deniedForever, whileInUse, always, unableToDetermine }

enum LocationAccuracy { lowest, low, medium, high, best, bestForNavigation }

enum LocationAccuracyStatus { reduced, precise, unknown }

class LocationSettings {
  const LocationSettings({this.accuracy = LocationAccuracy.best, this.distanceFilter = 0, this.timeLimit});
  final LocationAccuracy accuracy;

  /// Déplacement minimal (m) entre deux positions du flux.
  final int distanceFilter;
  final Duration? timeLimit;
}

class Position {
  const Position({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.timestamp,
  });

  factory Position._fromMap(Map m) => Position(
    latitude: (m['lat'] as num).toDouble(),
    longitude: (m['lon'] as num).toDouble(),
    accuracy: (m['accuracy'] as num?)?.toDouble() ?? 0,
    speed: (m['speed'] as num?)?.toDouble() ?? 0,
    heading: (m['heading'] as num?)?.toDouble() ?? -1,
    timestamp: DateTime.fromMillisecondsSinceEpoch((m['time'] as num?)?.toInt() ?? 0),
  );

  final double latitude, longitude;

  /// Précision horizontale (m).
  final double accuracy;

  /// Vitesse (m/s), 0 si inconnue.
  final double speed;

  /// Direction de déplacement (degrés, 0 = nord), -1 si inconnue.
  final double heading;
  final DateTime timestamp;
}

class LocationException implements Exception {
  LocationException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract final class Geolocator {
  static const _channel = MethodChannel('fr.applitransport/location');
  static const _updates = EventChannel('fr.applitransport/location/updates');

  static LocationPermission _perm(String? s) => switch (s) {
    'whileInUse' => LocationPermission.whileInUse,
    'always' => LocationPermission.always,
    'deniedForever' => LocationPermission.deniedForever,
    'denied' => LocationPermission.denied,
    _ => LocationPermission.unableToDetermine,
  };

  static Future<LocationPermission> checkPermission() async =>
      _perm(await _channel.invokeMethod<String>('checkPermission'));

  static Future<LocationPermission> requestPermission() async =>
      _perm(await _channel.invokeMethod<String>('requestPermission'));

  static Future<bool> isLocationServiceEnabled() async =>
      await _channel.invokeMethod<bool>('isServiceEnabled') ?? false;

  /// Position précise accordée, ou seulement approximative (Android 12+).
  static Future<LocationAccuracyStatus> getLocationAccuracy() async =>
      await _channel.invokeMethod<String>('accuracyStatus') == 'precise'
      ? LocationAccuracyStatus.precise
      : LocationAccuracyStatus.reduced;

  /// Dernière position connue du téléphone (sans nouvelle mesure), ou null.
  static Future<Position?> getLastKnownPosition() async {
    final m = await _channel.invokeMethod<Map>('lastKnown');
    return m == null ? null : Position._fromMap(m);
  }

  /// Position actuelle (nouvelle mesure). Délai : [LocationSettings.timeLimit], sinon 30 s.
  static Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async {
    try {
      final m = await _channel
          .invokeMethod<Map>('current')
          .timeout(locationSettings?.timeLimit ?? const Duration(seconds: 30));
      return Position._fromMap(m!);
    } on PlatformException catch (e) {
      throw LocationException(e.message ?? e.code);
    }
  }

  /// Flux unique partagé par tous les écrans (Android n'en tient qu'un par canal) : une position par
  /// seconde au plus ; il s'arrête quand plus personne ne l'écoute.
  static final Stream<Position> _shared = _updates
      .receiveBroadcastStream({'distance': 0, 'interval': 1000})
      .map((m) => Position._fromMap(m as Map));

  /// Positions successives, tant que le flux est écouté ; [LocationSettings.distanceFilter] : seulement
  /// après un déplacement d'au moins tant de mètres.
  static Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    final min = locationSettings?.distanceFilter ?? 0;
    if (min <= 0) return _shared;
    Position? last;
    return _shared.where((p) {
      final l = last;
      if (l != null && _meters(l, p) < min) return false;
      last = p;
      return true;
    });
  }

  static double _meters(Position a, Position b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * 0.017453292519943295;
    final dLon = (b.longitude - a.longitude) * 0.017453292519943295 * cos(a.latitude * 0.017453292519943295);
    return r * sqrt(dLat * dLat + dLon * dLon);
  }
}
