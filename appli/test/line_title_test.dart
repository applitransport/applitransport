import 'package:applitransport/poc/data.dart';
import 'package:applitransport/widgets/line_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Cas les plus longs du catalogue publié (15/11/2026).
CatalogLine _line(String short, String long, List<String> termini) => CatalogLine.fromCatalog({
  'route_id': 'IDFM:C00001',
  'short_name': short,
  'long_name': long,
  'type': 'bus',
  'network': 'IDFM:1',
  'color': '00643C',
  'text_color': 'FFFFFF',
  'size': 1000,
  'termini': termini,
});

final _cases = [
  _line('N', 'Remplacement Transilien N', [
    'Gare Routière de Mantes-la-Ville - Quai 21',
    'Gare de Plaisir Grignon - quai 3',
  ]),
  _line('TUVIM ISG', 'TUVIM ISG', ['Gare de Saint-Germain-en-Laye - Gare Routière', 'Gare de Saint-Germain-en-Laye']),
  _line('TER', 'TER Bourgogne - Franche-Comté', ['Laroche - Migennes', 'Paris-Bercy Bourgogne - Pays d\'Auvergne']),
];

void main() {
  // petit écran (320 px) et police système agrandie (×1,3, comme sur le S10e) : rien ne déborde,
  // la description tient sur deux lignes au plus
  for (final scale in [1.0, 1.3]) {
    testWidgets('liste des lignes à 320 px, police ×$scale', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: const Size(320, 800), textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: ListView(
                children: [for (final l in _cases) ListTile(title: LineTitle(line: l))],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (final l in _cases) {
        final text = tester.widget<Text>(find.text(l.description));
        expect(text.maxLines, 2);
        expect(text.overflow, TextOverflow.ellipsis);
      }
    });
  }
}
