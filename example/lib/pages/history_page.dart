import 'dart:async';
import 'dart:convert';

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart';
import '../widgets.dart';

/// My Colors and Compare History. Works offline (no device needed).
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) => const DefaultTabController(
    length: 3,
    child: Column(
      children: [
        TabBar(
          tabs: [
            Tab(text: 'My Colors'),
            Tab(text: 'Compare History'),
            Tab(text: 'Charts'),
          ],
        ),
        Expanded(child: TabBarView(children: [_MyColorsTab(), _HistoryTab(), _ChartsTab()])),
      ],
    ),
  );
}

Future<void> _shareJson(String json, String fileName) => SharePlus.instance.share(
  ShareParams(
    files: [XFile.fromData(utf8.encode(json), mimeType: 'application/json')],
    fileNameOverrides: [fileName],
  ),
);

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class _MyColorsTab extends StatelessWidget {
  const _MyColorsTab();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return StreamBuilder<void>(
      stream: state.myColors.changes,
      builder: (context, _) => FutureBuilder<List<ColorFolder>>(
        future: state.myColors.getFolders(),
        builder: (context, snapshot) {
          final folders = snapshot.data ?? const [];
          return ListView(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final name = await askText(context, 'New folder');
                      if (name == null) return;
                      try {
                        await state.myColors.createFolder(name);
                      } on ColorStorageException catch (e) {
                        if (context.mounted) _snack(context, e.message);
                      }
                    },
                    icon: const Icon(Icons.create_new_folder),
                    label: const Text('Folder'),
                  ),
                  TextButton.icon(
                    onPressed: folders.isEmpty ? null : () => _import(context, folders),
                    icon: const Icon(Icons.download),
                    label: const Text('Import'),
                  ),
                ],
              ),
              for (final f in folders) _FolderTile(f),
            ],
          );
        },
      ),
    );
  }

  Future<void> _import(BuildContext context, List<ColorFolder> folders) async {
    final state = AppScope.of(context);
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    final json = await askText(context, 'Paste exported JSON', initial: clip?.text ?? '');
    if (json == null || !context.mounted) return;
    try {
      final n = await state.importMyColors(json, folders.first.id);
      if (context.mounted) _snack(context, 'Import successful: $n color(s)');
    } on ColorDataModelMismatchException {
      if (context.mounted) _snack(context, 'Unmatched device model');
    } on ColorDataFormatException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile(this.folder);

  final ColorFolder folder;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return FutureBuilder<List<MyColor>>(
      future: state.myColors.getColors(folder.id),
      builder: (context, snapshot) {
        final colors = snapshot.data ?? const [];
        return ExpansionTile(
          leading: const Icon(Icons.folder),
          title: Text('${folder.name} (${colors.length})'),
          trailing: PopupMenuButton<String>(
            onSelected: (action) async {
              switch (action) {
                case 'rename':
                  final name = await askText(context, 'Rename folder', initial: folder.name);
                  if (name != null) await state.myColors.renameFolder(folder.id, name);
                case 'share':
                  await _shareJson(
                    await state.exportMyColors(folderId: folder.id),
                    'import_mycolor.json',
                  );
                case 'copy':
                  await Clipboard.setData(
                    ClipboardData(text: await state.exportMyColors(folderId: folder.id)),
                  );
                case 'delete':
                  await state.myColors.deleteFolders([folder.id]);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'share', child: Text('Share data')),
              PopupMenuItem(value: 'copy', child: Text('Copy JSON')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
          children: [
            for (final c in colors)
              ListTile(
                leading: Swatch(c.previewRgb, size: 32),
                title: Text(c.name),
                subtitle: Text(
                  'L ${f2(c.lab.l)}  a ${f2(c.lab.a)}  b ${f2(c.lab.b)}  •  '
                  '${c.createdAt.toLocal().toString().substring(0, 16)}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => state.myColors.deleteColors([c.id]),
                ),
                onLongPress: () async {
                  final name = await askText(context, 'Rename color', initial: c.name);
                  if (name != null) await state.myColors.renameColor(c.id, name);
                },
              ),
          ],
        );
      },
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return StreamBuilder<void>(
      stream: state.history.changes,
      builder: (context, _) => FutureBuilder<List<CompareRecord>>(
        future: state.history.getRecords(),
        builder: (context, snapshot) {
          final records = snapshot.data ?? const [];
          return ListView(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: records.isEmpty
                        ? null
                        : () async =>
                              _shareJson(await state.exportHistory(), 'compare_history.json'),
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                  ),
                  TextButton.icon(
                    onPressed: records.isEmpty ? null : state.history.clear,
                    icon: const Icon(Icons.delete_sweep),
                    label: const Text('Delete all'),
                  ),
                ],
              ),
              for (final r in records) _recordTile(context, r),
            ],
          );
        },
      ),
    );
  }

  Widget _recordTile(BuildContext context, CompareRecord r) {
    final state = AppScope.of(context);
    // Re-evaluated with the current formula and threshold.
    final cmp = r.evaluate(state.qc);
    return ListTile(
      leading: Swatch(
        r.sample.measurement?.rgb ?? ColorConversions.labToRgb(r.sample.lab),
        size: 32,
      ),
      title: Text('${cmp.settings.formula.label} ${f2(cmp.deltaE)}'),
      subtitle: Text(
        '${r.standard.name ?? 'Standard'} • ${r.timestamp.toLocal().toString().substring(0, 19)}',
      ),
      trailing: cmp.verdict == null
          ? null
          : Text(
              cmp.verdict == QcVerdict.pass ? 'PASS' : 'NG',
              style: TextStyle(
                color: cmp.verdict == QcVerdict.pass ? Colors.green : Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
      onLongPress: () => unawaited(state.history.deleteRecords([r.id])),
    );
  }
}

class _ChartsTab extends StatefulWidget {
  const _ChartsTab();

  @override
  State<_ChartsTab> createState() => _ChartsTabState();
}

class _ChartsTabState extends State<_ChartsTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final results = ColorChartMatcher.search(state.charts, _query);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search code or name',
            ),
            onChanged: (q) => setState(() => _query = q),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final (chart, c) in results)
                ListTile(
                  leading: Swatch(ColorConversions.labToRgb(c.lab), size: 32),
                  title: Text('${c.code}  ${c.name ?? ''}'),
                  subtitle: Text(chart.name),
                  trailing: IconButton(
                    icon: const Icon(Icons.save_alt),
                    tooltip: 'Save to My Colors',
                    onPressed: () async {
                      final folders = await state.myColors.getFolders();
                      if (folders.isEmpty) return;
                      await state.myColors.addColor(
                        folders.first.id,
                        name: c.name ?? c.code,
                        lab: c.lab,
                        chartCode: c.code,
                      );
                      if (context.mounted) {
                        _snack(context, 'Saved ${c.code} to ${folders.first.name}');
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
