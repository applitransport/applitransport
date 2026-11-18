// Choix de l'APK d'une nouvelle version selon le processeur du téléphone. Chaque Release publie un APK
// par type de processeur : « applitransport-1.4.0-arm64.apk » (64 bits) et « …-arm32.apk » (32 bits).

/// Suffixe du nom de fichier pour chaque type de processeur Android.
const apkSuffixes = {'arm64-v8a': '-arm64.apk', 'armeabi-v7a': '-arm32.apk'};

/// Lien de l'APK qui convient à [abis] (types de processeur du téléphone, du préféré au moins bon),
/// parmi [apks] (nom, lien). Ancienne Release avec un seul APK universel : celui-là. Sinon null
/// (l'appli ouvre alors la page de la Release).
String? pickApk(List<(String, String)> apks, List<String> abis) {
  for (final abi in abis) {
    final suffix = apkSuffixes[abi];
    if (suffix == null) continue;
    for (final (name, url) in apks) {
      if (name.endsWith(suffix)) return url;
    }
  }
  final universal = [
    for (final (name, url) in apks)
      if (!apkSuffixes.values.any(name.endsWith)) url,
  ];
  return universal.length == 1 ? universal.single : null;
}
