// Accès à la position du téléphone : service activé et permission accordée, sinon un message clair.
import 'geo.dart';

/// Position précise refusée (Android 12+ : l'usager n'a accordé que la position approximative, à
/// environ 2 km près).
Future<bool> preciseLocationDenied() async => await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced;

Future<void> ensureLocationPermission() async {
  if (!await Geolocator.isLocationServiceEnabled()) throw 'localisation désactivée sur l\'appareil';
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'permission refusée';
}
