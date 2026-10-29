// Bouton d'état du trafic d'une ligne (⚠ s'il y a des perturbations en cours) et fiche détaillée.
import 'package:flutter/material.dart';

import '../data/traffic.dart';
import '../poc/app_state.dart';
import 'line_badge.dart';

String _when(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

IconData _icon(DisruptionKind k) => switch (k) {
      DisruptionKind.works => Icons.construction,
      DisruptionKind.accessibility => Icons.elevator_outlined,
      DisruptionKind.incident => Icons.warning_amber,
    };

class TrafficButton extends StatelessWidget {
  const TrafficButton({super.key, required this.app, required this.lineId, this.compact = false});
  final AppState app;
  final String lineId;
  final bool compact; // pastille de ligne + icône (liste du cas 2)

  @override
  Widget build(BuildContext context) {
    final list = app.traffic(lineId);
    if (list == null) return const SizedBox.shrink();
    final now = app.now();
    final active = list.where((d) => d.kind != DisruptionKind.accessibility && d.activeAt(now)).length;
    final other = list.length - active;
    if (compact && active == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final icon = Icon(active > 0 ? Icons.warning_amber : (other > 0 ? Icons.info_outline : Icons.check_circle_outline),
        color: active > 0 ? Colors.orange.shade700 : (other > 0 ? scheme.tertiary : Colors.green));
    final line = app.line(lineId);
    if (compact && line != null) {
      return ActionChip(
        avatar: icon,
        label: LineBadge(name: line.name, color: line.color, textColor: line.textColor, small: true),
        onPressed: () => _open(context),
      );
    }
    return IconButton(
      tooltip: active > 0 ? '$active perturbation(s) en cours' : 'Info trafic',
      onPressed: () => _open(context),
      icon: active > 0 ? Badge(label: Text('$active'), child: icon) : icon,
    );
  }

  void _open(BuildContext context) {
    final list = app.traffic(lineId) ?? const [];
    final now = app.now();
    final active = list.where((d) => d.kind != DisruptionKind.accessibility && d.activeAt(now)).toList();
    final upcoming = list.where((d) => d.kind != DisruptionKind.accessibility && !d.activeAt(now)).toList()
      ..sort((a, b) => (a.firstStart ?? now).compareTo(b.firstStart ?? now));
    final lifts = list.where((d) => d.kind == DisruptionKind.accessibility).toList();
    final line = app.line(lineId);

    Widget section(String title, List<Disruption> items) => items.isEmpty
        ? const SizedBox.shrink()
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('$title (${items.length})', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final d in items)
              ExpansionTile(
                leading: Icon(_icon(d.kind)),
                title: Text(d.title),
                subtitle: Text(d.activeAt(now)
                    ? 'En cours'
                    : d.firstStart != null && d.firstStart!.isAfter(now)
                        ? 'À partir du ${_when(d.firstStart!)}'
                        : ''),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedAlignment: Alignment.centerLeft,
                children: [Text(d.text.isEmpty ? d.title : d.text)],
              ),
          ]);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, scroll) => ListView(controller: scroll, children: [
          ListTile(
            leading: line == null ? null : LineBadge(name: line.name, color: line.color, textColor: line.textColor),
            title: const Text('Info trafic'),
            subtitle: Text(list.isEmpty ? 'Aucune perturbation signalée' : 'Source : Île-de-France Mobilités'),
          ),
          section('En cours', active),
          section('Travaux et perturbations à venir', upcoming),
          section('Ascenseurs et accessibilité', lifts),
        ]),
      ),
    );
  }
}
