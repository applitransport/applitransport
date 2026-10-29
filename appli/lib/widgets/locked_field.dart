// Champ de réglage protégé : affiché en lecture seule, « Modifier » le libère, « Enregistrer » le
// valide, « Tester » vérifie la valeur affichée (ou celle en cours de saisie, avant de l'enregistrer).
import 'package:flutter/material.dart';

/// Résultat d'un test : [ok] et un message court.
typedef TestResult = ({bool ok, String message});

class LockedField extends StatefulWidget {
  const LockedField({
    super.key,
    required this.label,
    required this.value,
    required this.onSave,
    required this.onTest,
    this.emptyText = 'Non renseigné',
  });

  final String label, value, emptyText;
  final Future<void> Function(String value) onSave;
  final Future<TestResult> Function(String value) onTest;

  @override
  State<LockedField> createState() => _LockedFieldState();
}

class _LockedFieldState extends State<LockedField> {
  late final _ctrl = TextEditingController(text: widget.value);
  bool _editing = false, _testing = false;
  TestResult? _result;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final r = await widget.onTest(_editing ? _ctrl.text.trim() : widget.value);
    if (mounted) {
      setState(() {
        _testing = false;
        _result = r;
      });
    }
  }

  Future<void> _save() async {
    await widget.onSave(_ctrl.text.trim());
    if (!mounted) return;
    setState(() => _editing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${widget.label} enregistré')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_editing) _ctrl.text = widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          enabled: _editing,
          autofocus: _editing,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.emptyText,
            border: const OutlineInputBorder(),
            suffixIcon: _editing ? null : const Icon(Icons.lock_outline, size: 18),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_editing) ...[
              FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Enregistrer')),
              OutlinedButton(
                onPressed: () => setState(() {
                  _editing = false;
                  _result = null;
                }),
                child: const Text('Annuler'),
              ),
            ] else
              FilledButton.tonalIcon(
                onPressed: () => setState(() {
                  _editing = true;
                  _result = null;
                }),
                icon: const Icon(Icons.edit),
                label: const Text('Modifier'),
              ),
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check),
              label: const Text('Tester'),
            ),
          ],
        ),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _result!.ok ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: _result!.ok ? Colors.green : scheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_result!.message, style: TextStyle(color: _result!.ok ? null : scheme.error)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
