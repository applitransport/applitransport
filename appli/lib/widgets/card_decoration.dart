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
