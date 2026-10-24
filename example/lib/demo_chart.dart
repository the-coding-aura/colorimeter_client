import 'package:colorimeter_client/colorimeter_client.dart';

/// A small illustrative chart. Real charts (RAL, Pantone, NCS, ...) are
/// licensed data; load them from your own source with [ColorChart.fromJson].
final ColorChart demoChart = ColorChart(
  name: 'Demo chart',
  colors: [
    for (final (code, name, hex) in const [
      ('D-001', 'Pure white', '#F4F4F2'),
      ('D-002', 'Ivory', '#ECEAE7'),
      ('D-003', 'Cream', '#F3E5C0'),
      ('D-010', 'Light grey', '#C8C8C6'),
      ('D-011', 'Mid grey', '#8E8E8C'),
      ('D-012', 'Graphite', '#4A4B4D'),
      ('D-020', 'Signal red', '#A02128'),
      ('D-021', 'Coral', '#E8735A'),
      ('D-030', 'Ochre', '#C8932F'),
      ('D-031', 'Sun yellow', '#F2C14E'),
      ('D-040', 'Sage', '#9CAF88'),
      ('D-041', 'Forest', '#2E5E3E'),
      ('D-050', 'Sky', '#8CB8D8'),
      ('D-051', 'Navy', '#1F3A5F'),
      ('D-060', 'Lavender', '#B7A6CF'),
    ])
      ChartColor(code: code, name: name, lab: ColorConversions.rgbToLab(Rgb.fromHex(hex))),
  ],
);
