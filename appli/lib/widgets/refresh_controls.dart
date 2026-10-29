// Boutons « Actualiser » (1 requête puis 30 s d'attente) et « Auto » (1 requête toutes les 30 s
// pendant la durée réglée dans la Configuration). Leur couleur indique leur état.
import 'dart:async';

import 'package:flutter/material.dart';

import '../poc/position.dart';

const refreshInterval = Duration(seconds: 30);

class RefreshControls extends StatefulWidget {
  const RefreshControls({
    super.key,
    required this.onRefresh,
    required this.autoMinutes,
    required this.lastRefresh,
    required this.now,
    this.middle,
    this.error,
  });

  final VoidCallback onRefresh;
  final int autoMinutes;
  final DateTime? lastRefresh;
  final DateTime Function() now;

  /// Bouton facultatif placé entre Actualiser et Auto (ex. replier la liste des horaires).
  final Widget? middle;

  /// Dernière erreur du temps réel (jeton absent, pas de réseau…), affichée sous les boutons.
  final String? error;

  @override
  State<RefreshControls> createState() => _RefreshControlsState();
}

class _RefreshControlsState extends State<RefreshControls> {
  DateTime? _cooldownUntil, _autoUntil, _nextAuto;
  Timer? _ticker, _autoTimer;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _autoTimer?.cancel();
    super.dispose();
  }

  bool get _autoOn => _autoUntil != null;

  int _remaining(DateTime? until) => until == null ? 0 : until.difference(DateTime.now()).inSeconds.clamp(0, 1 << 30);

  void _manual() {
    widget.onRefresh();
    setState(() => _cooldownUntil = DateTime.now().add(refreshInterval));
  }

  void _toggleAuto() {
    if (_autoOn) return _stopAuto();
    widget.onRefresh();
    setState(() {
      _autoUntil = DateTime.now().add(Duration(minutes: widget.autoMinutes));
      _nextAuto = DateTime.now().add(refreshInterval);
    });
    _autoTimer = Timer.periodic(refreshInterval, (_) {
      if (DateTime.now().isAfter(_autoUntil!)) return _stopAuto();
      widget.onRefresh();
      setState(() => _nextAuto = DateTime.now().add(refreshInterval));
    });
  }

  void _stopAuto() {
    _autoTimer?.cancel();
    setState(() {
      _autoUntil = null;
      _nextAuto = null;
      _cooldownUntil = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cooldown = _remaining(_cooldownUntil);
    final autoLeft = _remaining(_autoUntil);

    // Actualiser : vert = prêt, orange = attente de 30 s, gris = inutile pendant l'auto
    final manualColor = _autoOn ? Colors.grey : (cooldown > 0 ? Colors.orange.shade700 : Colors.green.shade700);
    final manualLabel = _autoOn ? 'Actualiser' : (cooldown > 0 ? 'Patienter $cooldown s' : 'Actualiser');
    final manual = FilledButton.icon(
      onPressed: _autoOn || cooldown > 0 ? null : _manual,
      icon: Icon(cooldown > 0 && !_autoOn ? Icons.hourglass_top : Icons.refresh),
      label: Text(manualLabel),
      style: FilledButton.styleFrom(
        backgroundColor: manualColor,
        disabledBackgroundColor: manualColor.withValues(alpha: _autoOn ? 0.35 : 0.85),
        disabledForegroundColor: Colors.white,
        foregroundColor: Colors.white,
      ),
    );

    // Auto : bleu plein = en cours, contour = arrêté
    final auto = _autoOn
        ? FilledButton.icon(
            onPressed: _toggleAuto,
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text('Auto ${autoLeft ~/ 60}:${(autoLeft % 60).toString().padLeft(2, '0')}'),
            style: FilledButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
          )
        : OutlinedButton.icon(
            onPressed: _toggleAuto,
            icon: const Icon(Icons.autorenew),
            label: Text('Auto ${widget.autoMinutes} min'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.blue.shade700),
          );

    final last = widget.lastRefresh;
    final info = last == null
        ? 'Horaires théoriques · appuyez sur Actualiser pour le temps réel'
        : 'Actualisé il y a ${duration(widget.now().difference(last).inSeconds)}'
            '${_autoOn ? ' · prochaine requête dans ${_remaining(_nextAuto)} s' : ''}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: manual),
          const SizedBox(width: 8),
          if (widget.middle != null) ...[widget.middle!, const SizedBox(width: 8)],
          Expanded(child: auto),
        ]),
        const SizedBox(height: 4),
        Text(info, style: Theme.of(context).textTheme.bodySmall),
        if (widget.error != null)
          Text(widget.error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
      ]),
    );
  }
}
