import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart';
import '../widgets.dart';

class MeasurePage extends StatefulWidget {
  const MeasurePage({super.key});

  @override
  State<MeasurePage> createState() => _MeasurePageState();
}

class _MeasurePageState extends State<MeasurePage> {
  final _resultKey = GlobalKey();
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final m = state.lastMeasurement;
    final connected = state.connection.isConnected;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          onPressed: connected && !state.busy ? state.measure : null,
          icon: const Icon(Icons.colorize),
          label: const Text('Scan'),
        ),
        const SizedBox(height: 4),
        Text(
          connected
              ? 'Or short-press the button on the colorimeter.'
              : 'Connect a device on the Device tab.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (state.simulator != null && connected)
          TextButton(
            onPressed: state.simulator!.pressButton,
            child: const Text('Simulate device button press'),
          ),
        if (m != null) ...[
          const SizedBox(height: 16),
          RepaintBoundary(
            key: _resultKey,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Swatch(m.rgb, size: 72),
                    const SizedBox(width: 16),
                    Expanded(child: MeasurementTable(m)),
                  ],
                ),
              ),
            ),
          ),
          Text(
            'Source: ${m.source.name} • D65/10° • ${m.timestamp.toLocal()}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text('Closest chart colors', style: Theme.of(context).textTheme.titleMedium),
          for (final match in state.matchesFor(m.lab))
            ListTile(
              leading: Swatch(ColorConversions.labToRgb(match.color.lab), size: 36),
              title: Text('${match.color.code}  ${match.color.name ?? ''}'),
              subtitle: Text('${match.chart.name} • ΔE*00 ${f2(match.deltaE)}'),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _save(m),
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _shareData(m),
                  icon: const Icon(Icons.share),
                  label: const Text('Data'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _shareImage,
                  icon: const Icon(Icons.image),
                  label: const Text('Image'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String get _colorName => _name.text.trim().isEmpty ? 'Color' : _name.text.trim();

  Future<void> _save(ColorMeasurement m) async {
    final state = AppScope.of(context);
    final folders = await state.myColors.getFolders();
    if (!mounted || folders.isEmpty) return;
    final folder = folders.length == 1
        ? folders.single
        : await showDialog<ColorFolder>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Save to folder'),
              children: [
                for (final f in folders)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, f),
                    child: Text(f.name),
                  ),
              ],
            ),
          );
    if (folder == null) return;
    await state.myColors.addColor(folder.id, name: _colorName, lab: m.lab, measurement: m);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to ${folder.name}')));
    }
  }

  Future<void> _shareData(ColorMeasurement m) async {
    final state = AppScope.of(context);
    final json = ColorDataCodec.encodeMyColors(
      model: state.model,
      folders: [ColorFolder(id: 'shared', name: 'Shared', createdAt: DateTime.now())],
      colors: [
        MyColor(
          id: 'shared-1',
          folderId: 'shared',
          name: _colorName,
          createdAt: m.timestamp,
          lab: m.lab,
          measurement: m,
        ),
      ],
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(utf8.encode(json), mimeType: 'application/json')],
        fileNameOverrides: ['import_mycolor.json'],
        text: '$_colorName  Lab ${f2(m.lab.l)}, ${f2(m.lab.a)}, ${f2(m.lab.b)}  ${m.hex}',
      ),
    );
  }

  Future<void> _shareImage() async {
    final boundary = _resultKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(data.buffer.asUint8List(), mimeType: 'image/png')],
        fileNameOverrides: ['$_colorName.png'],
      ),
    );
  }
}
