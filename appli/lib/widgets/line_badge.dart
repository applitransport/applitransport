import 'package:flutter/material.dart';

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
        child: Text(name,
            style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: small ? 12 : 14)),
      );
}
