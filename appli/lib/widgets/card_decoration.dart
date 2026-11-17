// Carte blanche arrondie et ombrée : style commun de l'accueil, d'Itinéraire et de « Quelle ligne prendre ? ».
import 'package:flutter/material.dart';

BoxDecoration cardDecoration(BuildContext context, {double radius = 22}) => BoxDecoration(
  color: Theme.of(context).colorScheme.surfaceContainerLowest,
  borderRadius: BorderRadius.circular(radius),
  boxShadow: const [
    BoxShadow(color: Color(0x0F14212B), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x1214212B), blurRadius: 18, offset: Offset(0, 6)),
  ],
);

/// Sections d'une page de réglages : les widgets entre deux [Divider] forment une carte blanche.
List<Widget> cardSections(BuildContext context, List<Widget> children) {
  final groups = <List<Widget>>[[]];
  for (final w in children) {
    if (w is Divider) {
      groups.add([]);
    } else {
      groups.last.add(w);
    }
  }
  return [
    for (final g in groups)
      if (g.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: cardDecoration(context, radius: 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: g),
        ),
  ];
}
