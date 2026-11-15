import 'package:flutter/material.dart';

import '../poc/data.dart' show CatalogLine;

/// Pastille de ligne aux couleurs officielles (« 5104 » sur fond bordeaux…).
class LineBadge extends StatelessWidget {
  const LineBadge({super.key, required this.name, required this.color, required this.textColor, this.small = false});

  final String name;
  final Color color, textColor;
  final bool small;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: small ? 5 : 8, vertical: small ? 1 : 3),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
    child: Text(
      name,
      style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: small ? 12 : 14),
    ),
  );
}

/// Ligne dans les listes (Configuration › Lignes) : pastille, type, puis nom long et terminus sur deux
/// lignes au plus (« … » au-delà), pour distinguer les lignes au nom court identique.
class LineTitle extends StatelessWidget {
  const LineTitle({super.key, required this.line});
  final CatalogLine line;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      LineBadge(name: line.name, color: line.color, textColor: line.textColor),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.typeLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (line.description.isNotEmpty)
              Text(
                line.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    ],
  );
}
