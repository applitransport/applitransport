// Configuration : lignes (disponibles / téléchargées / préférées), jeton PRIM, réglages généraux.
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/prim.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../widgets/line_badge.dart';
import '../widgets/locked_field.dart';

String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
String _dateTime(DateTime d) =>
    '${_date(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String _size(int bytes) =>
    bytes >= 1e6 ? '${(bytes / 1e6).toStringAsFixed(1).replaceAll('.', ',')} Mo' : '${(bytes / 1e3).ceil()} Ko';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Configuration'),
        bottom: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.route), text: 'Lignes'),
            Tab(icon: Icon(Icons.key), text: 'Jeton PRIM'),
            Tab(icon: Icon(Icons.tune), text: 'Général'),
          ],
        ),
      ),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => TabBarView(
          children: [
            _LinesTab(app: app),
            _TokenTab(app: app),
            _GeneralTab(app: app),
          ],
        ),
      ),
    ),
  );
}

// --- Lignes ------------------------------------------------------------------------

class _LinesTab extends StatefulWidget {
  const _LinesTab({required this.app});
  final AppState app;

  @override
  State<_LinesTab> createState() => _LinesTabState();
}

class _LinesTabState extends State<_LinesTab> {
  int _view = 0; // 0 disponibles, 1 téléchargées, 2 préférées
  final Set<String> _types = {};
  String? _network;
  String _query = '';

  AppState get app => widget.app;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _status(context),
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 0, label: _count('Dispo.', app.catalog.length)),
            ButtonSegment(value: 1, label: _count('Téléch.', app.downloaded.length)),
            ButtonSegment(value: 2, label: _count('Préf.', app.preferred.length)),
          ],
          selected: {_view},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _view = s.first),
        ),
      ),
      Expanded(child: [_available, _downloaded, _preferred][_view](context)),
    ],
  );

  /// Catalogue absent, téléchargement groupé en cours, erreur réseau.
  Widget _status(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bulk = app.bulk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (app.catalog.isEmpty)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('Catalogue des lignes non téléchargé'),
              subtitle: const Text('0,5 Mo : toutes les lignes et tous les arrêts d\'Île-de-France'),
              trailing: app.checking
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
                  : FilledButton(onPressed: app.checkUpdates, child: const Text('Télécharger')),
            ),
          ),
        if (bulk != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                Text('Téléchargement : ${bulk.done} / ${bulk.total} lignes'),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: bulk.total == 0 ? null : bulk.done / bulk.total),
              ],
            ),
          ),
        if (app.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(app.lastError!, style: TextStyle(color: scheme.error)),
          ),
      ],
    );
  }

  Widget _count(String label, int n) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label),
      const SizedBox(width: 4),
      Badge(label: Text('$n'), backgroundColor: Theme.of(context).colorScheme.primary),
    ],
  );

  Widget _lineTitle(CatalogLine l) => Row(
    children: [
      LineBadge(name: l.name, color: l.color, textColor: l.textColor),
      const SizedBox(width: 8),
      Flexible(child: Text(l.typeLabel, overflow: TextOverflow.ellipsis)),
    ],
  );

  // Disponibles : catalogue filtré par type, réseau, numéro/nom ou arrêt
  Widget _available(BuildContext context) {
    final q = _query.toLowerCase().trim();
    final byStop = <String, String>{}; // ligne -> nom de l'arrêt trouvé
    if (q.length >= 3) {
      for (final a in app.stopAreas.values) {
        final hit = [a.name, ...a.aliases].where((n) => n.toLowerCase().contains(q)).firstOrNull;
        if (hit != null) {
          for (final id in a.lines) {
            byStop.putIfAbsent(id, () => a.town.isEmpty ? hit : '$hit (${a.town})');
          }
        }
      }
    }
    final lines = app.catalog.where((l) {
      if (_types.isNotEmpty && !_types.contains(l.type)) return false;
      if (_network != null && l.network != _network) return false;
      if (q.isEmpty) return true;
      return l.name.toLowerCase().contains(q) || l.longName.toLowerCase().contains(q) || byStop.containsKey(l.id);
    }).toList();
    final types = {for (final l in app.catalog) l.type}.toList()..sort();
    final missing = app.catalog.where((l) => !app.hasSchedules(l.id)).toList();
    final missingBytes = missing.fold<int>(0, (a, l) => a + l.size);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Numéro, nom de ligne ou arrêt (ex. « Trappes Gare »)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              for (final t in types)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(typeLabels[t] ?? t),
                    selected: _types.contains(t),
                    onSelected: (on) => setState(() => on ? _types.add(t) : _types.remove(t)),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DropdownButton<String?>(
            value: _network,
            isExpanded: true,
            hint: const Text('Tous réseaux'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Tous réseaux')),
              for (final e in app.networks.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _network = v),
          ),
        ),
        if (missing.isNotEmpty && app.bulk == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OutlinedButton.icon(
              onPressed: app.downloadAll,
              icon: const Icon(Icons.download_for_offline_outlined),
              label: Text('Tout télécharger (${missing.length} lignes, ${_size(missingBytes)})'),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final l = lines[i];
              final progress = app.downloading[l.id];
              final Widget trailing;
              if (app.downloaded.contains(l.id)) {
                // téléchargée : ✓, et l'étoile pour l'ajouter aux préférées sans changer d'onglet
                trailing = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green),
                    IconButton(
                      tooltip: app.preferred.contains(l.id) ? 'Retirer des préférées' : 'Ajouter aux préférées',
                      icon: Icon(
                        app.preferred.contains(l.id) ? Icons.star : Icons.star_border,
                        color: Colors.amber.shade700,
                      ),
                      onPressed: () => app.togglePreferred(l.id),
                    ),
                  ],
                );
              } else if (progress != null) {
                trailing = SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(value: progress == 0 ? null : progress),
                );
              } else {
                trailing = IconButton(
                  tooltip: 'Télécharger',
                  icon: const Icon(Icons.download),
                  onPressed: () => app.download(l.id),
                );
              }
              return ListTile(
                title: _lineTitle(l),
                subtitle: Text(
                  [
                    app.networks[l.network] ?? l.network,
                    _size(l.size),
                    if (byStop.containsKey(l.id)) 'passe à ${byStop[l.id]}',
                  ].join(' · '),
                ),
                trailing: trailing,
              );
            },
          ),
        ),
      ],
    );
  }

  // Téléchargées : stockées sur l'appareil, utilisables hors ligne
  Widget _downloaded(BuildContext context) {
    final lines = app.catalog.where((l) => app.downloaded.contains(l.id)).toList();
    final outdated = app.updateAvailable;
    final last = app.repo.lastCheck;
    final scheme = Theme.of(context).colorScheme;
    // en-têtes puis une tuile par ligne, construites seulement quand elles sont visibles
    final header = <Widget>[
      ListTile(
        title: Text('${lines.length} ligne(s) sur l\'appareil · ${_size(app.repo.localBytes)}'),
        subtitle: Text(last == null ? 'Jamais vérifié' : 'Dernière vérification : ${_dateTime(last)}'),
        trailing: app.checking
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
            : TextButton.icon(onPressed: app.checkUpdates, icon: const Icon(Icons.sync), label: const Text('Vérifier')),
      ),
      if (outdated.isNotEmpty && app.bulk == null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: FilledButton.tonalIcon(
            onPressed: app.updateAll,
            icon: const Icon(Icons.system_update_alt),
            label: Text('Tout mettre à jour (${outdated.length})'),
          ),
        ),
      if (lines.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('Aucune ligne téléchargée.')),
        ),
    ];
    return ListView.builder(
      itemCount: header.length + lines.length,
      itemBuilder: (context, i) {
        if (i < header.length) return header[i];
        final l = lines[i - header.length];
        return ListTile(
          title: _lineTitle(l),
          subtitle: Text(
            outdated.contains(l.id)
                ? 'Nouveaux horaires disponibles'
                : app.isExpired(l.id)
                ? 'Horaires périmés : à mettre à jour'
                : 'Horaires jusqu\'au ${app.repo.local[l.id]?.until == null ? '?' : _date(app.repo.local[l.id]!.until!)}',
            style: TextStyle(color: outdated.contains(l.id) || app.isExpired(l.id) ? scheme.error : null),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (outdated.contains(l.id))
                IconButton(
                  tooltip: 'Mettre à jour',
                  icon: const Icon(Icons.system_update_alt, color: Colors.orange),
                  onPressed: () => app.update(l.id),
                ),
              IconButton(
                tooltip: app.preferred.contains(l.id) ? 'Retirer des préférées' : 'Ajouter aux préférées',
                icon: Icon(app.preferred.contains(l.id) ? Icons.star : Icons.star_border, color: Colors.amber.shade700),
                onPressed: () => app.togglePreferred(l.id),
              ),
              IconButton(
                tooltip: 'Supprimer',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => app.remove(l.id),
              ),
            ],
          ),
        );
      },
    );
  }

  // Préférées : l'ordre est celui du menu Ligne du suivi
  Widget _preferred(BuildContext context) {
    if (app.preferred.isEmpty) {
      return const Center(
        child: Text('Aucune ligne préférée.\nAjoutez-en avec ☆ dans Téléchargées.', textAlign: TextAlign.center),
      );
    }
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Ces lignes apparaissent dans le menu du suivi de ligne, dans cet ordre (glisser pour réordonner).',
          ),
        ),
        Expanded(
          child: ReorderableListView(
            onReorderItem: app.reorderPreferred,
            children: [
              for (final id in app.preferred)
                ListTile(
                  key: ValueKey(id),
                  title: app.line(id) == null ? Text(id) : _lineTitle(app.line(id)!),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.star, color: Colors.amber),
                        onPressed: () => app.togglePreferred(id),
                      ),
                      const Icon(Icons.drag_handle),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// --- Jeton PRIM --------------------------------------------------------------------

class _TokenTab extends StatelessWidget {
  const _TokenTab({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Chaque appareil utilise son propre jeton PRIM (compte gratuit sur prim.iledefrance-mobilites.fr, '
        'abonnements « Prochains passages » requête ligne et requête unitaire, « Messages Info Trafic », '
        '« Calculateur »). Il reste enregistré sur l\'appareil uniquement.',
      ),
      const SizedBox(height: 16),
      LockedField(label: 'Jeton PRIM', value: app.token, onSave: (v) async => app.setToken(v), onTest: app.testToken),
      const SizedBox(height: 24),
      Text('Requêtes PRIM aujourd\'hui depuis cet appareil', style: Theme.of(context).textTheme.titleSmall),
      const Text('(la page de votre compte PRIM fait foi : elle compte aussi les autres usages du jeton)'),
      const SizedBox(height: 8),
      for (final e in app.requests.entries) ...[
        Text('Requête ${e.key} : ${e.value} / ${primQuota[e.key]} · ${primKinds[e.key]}'),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: e.value / primQuota[e.key]!),
        const SizedBox(height: 12),
      ],
    ],
  );
}

// --- Général -----------------------------------------------------------------------

class _GeneralTab extends StatelessWidget {
  const _GeneralTab({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Actualisation automatique', style: Theme.of(context).textTheme.titleMedium),
        Text(
          'Durée : ${app.autoMinutes} min · une requête toutes les 30 s '
          '(≈ ${app.autoMinutes * 2} requêtes par session)',
        ),
        Slider(
          value: app.autoMinutes.toDouble(),
          min: 1,
          max: 10,
          divisions: 9,
          label: '${app.autoMinutes} min',
          onChanged: (v) => app.setAutoMinutes(v.round()),
        ),
        const Divider(),
        Text('Apparence', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('Système')),
            ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Clair')),
            ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Sombre')),
          ],
          selected: {app.themeMode},
          onSelectionChanged: (s) => app.setThemeMode(s.first),
        ),
        const SizedBox(height: 8),
        const Divider(),
        Text('Serveur de données', style: Theme.of(context).textTheme.titleMedium),
        const Text(
          'Par défaut : la publication quotidienne sur GitHub. Pour tester une usine locale : '
          'http://<adresse du PC>:8080/.',
        ),
        const SizedBox(height: 8),
        LockedField(
          label: 'Adresse du serveur',
          value: app.dataUrl,
          onSave: (v) async {
            app.setDataUrl(v);
            await app.checkUpdates(); // nouveau serveur : on relit son catalogue
          },
          onTest: app.testDataUrl,
        ),
        const SizedBox(height: 8),
        const Divider(),
        Text('À propos', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        FutureBuilder(
          future: PackageInfo.fromPlatform(),
          builder: (context, info) => Text(
            info.hasData
                ? 'AppliTransport version ${info.data!.version} (${info.data!.buildNumber})'
                : 'AppliTransport',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Licence PolyForm Strict 1.0.0 : utilisation gratuite à des fins non '
          'commerciales, sans modification ni redistribution. Copyright © 2026 Sébastien N.\n\n'
          '${app.catalog.length} lignes au catalogue, ${app.downloaded.length} téléchargée(s).\n'
          'Données : © Île-de-France Mobilités, licence ODbL.\n'
          'Fond de carte : © contributeurs OpenStreetMap.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.description_outlined),
            label: const Text('Licences des bibliothèques et des données'),
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'AppliTransport',
              applicationLegalese: 'PolyForm Strict 1.0.0 · données Île-de-France Mobilités (ODbL)',
            ),
          ),
        ),
      ],
    );
  }
}
