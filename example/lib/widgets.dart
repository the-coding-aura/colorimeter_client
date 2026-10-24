import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter/material.dart';

String f2(double v) => v.toStringAsFixed(2);

/// A color swatch.
class Swatch extends StatelessWidget {
  const Swatch(this.rgb, {super.key, this.size = 48});

  final Rgb rgb;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Color(rgb.argb),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.black12),
    ),
  );
}

/// All color spaces of a measurement.
class MeasurementTable extends StatelessWidget {
  const MeasurementTable(this.m, {super.key});

  final ColorMeasurement m;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Lab', '${f2(m.lab.l)}  ${f2(m.lab.a)}  ${f2(m.lab.b)}'),
      ('Luv', '${f2(m.luv.l)}  ${f2(m.luv.u)}  ${f2(m.luv.v)}'),
      ('LCh', '${f2(m.lch.l)}  ${f2(m.lch.c)}  ${f2(m.lch.h)}'),
      (
        'Yxy',
        '${f2(m.yxy.luminance)}  ${m.yxy.x.toStringAsFixed(4)}  ${m.yxy.y.toStringAsFixed(4)}',
      ),
      ('RGB', '${m.rgb.r}  ${m.rgb.g}  ${m.rgb.b}'),
      ('Hex', m.hex),
      (
        'CMYK',
        [m.cmyk.c, m.cmyk.m, m.cmyk.y, m.cmyk.k].map((v) => v.toStringAsFixed(0)).join('  '),
      ),
    ];
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth()},
      children: [
        for (final (k, v) in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 4),
                child: Text(k, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              Text(v, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
      ],
    );
  }
}

/// Asks for a single line of text.
Future<String?> askText(BuildContext context, String title, {String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('OK'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}
