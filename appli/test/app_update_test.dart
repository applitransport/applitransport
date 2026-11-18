import 'package:applitransport/data/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const split = [('applitransport-1.4.0-arm64.apk', 'u64'), ('applitransport-1.4.0-arm32.apk', 'u32')];

  test('téléphone 64 bits : APK arm64', () {
    expect(pickApk(split, ['arm64-v8a', 'armeabi-v7a', 'armeabi']), 'u64');
  });

  test('téléphone 32 bits : APK arm32', () {
    expect(pickApk(split, ['armeabi-v7a', 'armeabi']), 'u32');
  });

  test('64 bits sans APK arm64 publié : arm32 en repli', () {
    expect(pickApk([split[1]], ['arm64-v8a', 'armeabi-v7a']), 'u32');
  });

  test('x86 ou processeur inconnu : page de la Release', () {
    expect(pickApk(split, ['x86_64']), isNull);
    expect(pickApk(split, []), isNull);
  });

  test('ancienne Release, APK universel unique', () {
    expect(pickApk([('applitransport-1.3.0.apk', 'u')], ['arm64-v8a']), 'u');
    expect(pickApk([('applitransport-1.3.0.apk', 'u')], ['x86_64']), 'u');
  });
}
