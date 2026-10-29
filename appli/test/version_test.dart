import 'package:applitransport/poc/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('comparaison des versions (Releases GitHub)', () {
    expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
    expect(isNewerVersion('1.10.0', '1.9.2'), isTrue); // numérique, pas alphabétique
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    expect(isNewerVersion('0.9.9', '1.0.0'), isFalse);
    expect(isNewerVersion('', '1.0.0'), isFalse);
  });
}
