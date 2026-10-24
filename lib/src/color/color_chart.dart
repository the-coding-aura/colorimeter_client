import 'package:flutter/foundation.dart';

import '../json_utils.dart';
import '../models/color_spaces.dart';
import 'conversions.dart';
import 'delta_e.dart';

/// One entry of a standard color chart.
@immutable
final class ChartColor {
  /// Creates a chart color.
  const ChartColor({required this.code, required this.lab, this.name});

  /// Restores a chart color from [toJson] output.
  factory ChartColor.fromJson(JsonMap json) => ChartColor(
    code: readString(json, 'code'),
    lab: Lab.fromJson(readMap(json, 'lab')),
    name: readOptionalString(json, 'name'),
  );

  /// Chart code, e.g. `RAL 3020`.
  final String code;

  /// Optional descriptive name.
  final String? name;

  /// Lab value (D65/10° to match the instrument).
  final Lab lab;

  /// JSON form.
  JsonMap toJson() => {'code': code, if (name != null) 'name': name, 'lab': lab.toJson()};

  @override
  String toString() => 'ChartColor($code)';
}

/// A named set of [ChartColor]s.
@immutable
final class ColorChart {
  /// Creates a chart.
  ColorChart({required this.name, required List<ChartColor> colors})
    : colors = List.unmodifiable(colors);

  /// Restores a chart from [toJson] output.
  factory ColorChart.fromJson(JsonMap json) => ColorChart(
    name: readString(json, 'name'),
    colors: [for (final c in readMapList(json, 'colors')) ChartColor.fromJson(c)],
  );

  /// Chart name.
  final String name;

  /// Chart entries.
  final List<ChartColor> colors;

  /// Case-insensitive "contains" search over code and name.
  List<ChartColor> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return colors;
    return [
      for (final c in colors)
        if (c.code.toLowerCase().contains(q) || (c.name?.toLowerCase().contains(q) ?? false)) c,
    ];
  }

  /// JSON form.
  JsonMap toJson() => {
    'name': name,
    'colors': [for (final c in colors) c.toJson()],
  };
}

/// A chart color matched to a sample.
@immutable
final class ChartMatch {
  /// Creates a match.
  const ChartMatch({required this.chart, required this.color, required this.deltaE});

  /// Chart the color belongs to.
  final ColorChart chart;

  /// The matched entry.
  final ChartColor color;

  /// ΔE between the sample and [color].
  final double deltaE;

  @override
  String toString() => 'ChartMatch(${color.code}, ΔE ${deltaE.toStringAsFixed(2)})';
}

/// Nearest-color matching across charts.
abstract final class ColorChartMatcher {
  /// Returns up to [count] chart colors closest to [sample], nearest first.
  ///
  /// The sample is treated as the standard for the asymmetric formulas, so
  /// all candidates are weighted the same way. Defaults to ΔE\*00.
  static List<ChartMatch> nearest(
    Lab sample,
    Iterable<ColorChart> charts, {
    int count = 3,
    DeltaEFormula formula = DeltaEFormula.cie2000,
    WhitePoint whitePoint = WhitePoint.d65TenDegree,
  }) {
    RangeError.checkNotNegative(count, 'count');
    final matches = <ChartMatch>[
      for (final chart in charts)
        for (final color in chart.colors)
          ChartMatch(
            chart: chart,
            color: color,
            deltaE: DeltaE.compute(sample, color.lab, formula: formula, whitePoint: whitePoint),
          ),
    ]..sort((x, y) => x.deltaE.compareTo(y.deltaE));
    return matches.take(count).toList(growable: false);
  }

  /// Searches all [charts] (see [ColorChart.search]).
  static List<(ColorChart, ChartColor)> search(Iterable<ColorChart> charts, String query) => [
    for (final chart in charts)
      for (final color in chart.search(query)) (chart, color),
  ];
}
