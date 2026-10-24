import 'package:flutter/foundation.dart';

import '../json_utils.dart';
import '../models/color_measurement.dart';
import '../models/color_spaces.dart';
import 'conversions.dart';
import 'delta_e.dart';

/// QC judgement.
enum QcVerdict {
  /// ΔE ≤ threshold.
  pass,

  /// ΔE > threshold ("no good").
  ng,
}

/// Color-difference and QC settings (formula + tolerance).
@immutable
final class QcSettings {
  /// Creates settings. Throws [RangeError] when [threshold] is outside
  /// [minThreshold]–[maxThreshold].
  QcSettings({
    this.formula = DeltaEFormula.ab,
    this.threshold = defaultThreshold,
    this.enabled = true,
  }) {
    if (!isValidThreshold(threshold)) {
      throw RangeError.value(
        threshold,
        'threshold',
        'must be between $minThreshold and $maxThreshold',
      );
    }
  }

  /// Like the constructor, but an out-of-range [threshold] falls back to
  /// [defaultThreshold] (the behavior described in the LS170 manual).
  factory QcSettings.lenient({
    DeltaEFormula formula = DeltaEFormula.ab,
    double threshold = defaultThreshold,
    bool enabled = true,
  }) => QcSettings(
    formula: formula,
    threshold: isValidThreshold(threshold) ? threshold : defaultThreshold,
    enabled: enabled,
  );

  /// Smallest allowed threshold.
  static const double minThreshold = 0.1;

  /// Largest allowed threshold.
  static const double maxThreshold = 50;

  /// Threshold used when none (or an invalid one) is given.
  static const double defaultThreshold = 1;

  /// Whether [value] is an allowed threshold.
  static bool isValidThreshold(double value) =>
      value.isFinite && value >= minThreshold && value <= maxThreshold;

  /// ΔE formula.
  final DeltaEFormula formula;

  /// Maximum ΔE that still passes.
  final double threshold;

  /// Whether QC judgement is enabled. When `false`, comparisons have no
  /// verdict.
  final bool enabled;

  /// Returns PASS when [deltaE] ≤ [threshold], else NG.
  QcVerdict judge(double deltaE) => deltaE <= threshold ? QcVerdict.pass : QcVerdict.ng;

  /// Copy with changes.
  QcSettings copyWith({DeltaEFormula? formula, double? threshold, bool? enabled}) => QcSettings(
    formula: formula ?? this.formula,
    threshold: threshold ?? this.threshold,
    enabled: enabled ?? this.enabled,
  );

  @override
  bool operator ==(Object other) =>
      other is QcSettings &&
      other.formula == formula &&
      other.threshold == threshold &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(formula, threshold, enabled);
}

/// A standard or sample color: measured, typed in (Lab or LCh), or picked
/// from a chart / My Colors.
@immutable
final class ColorReference {
  /// Creates a reference from Lab values.
  const ColorReference({required this.lab, this.name, this.measurement});

  /// Uses a device measurement.
  factory ColorReference.fromMeasurement(ColorMeasurement measurement, {String? name}) =>
      ColorReference(lab: measurement.lab, name: name, measurement: measurement);

  /// Uses typed-in LCh values.
  factory ColorReference.fromLch(LCh lch, {String? name}) =>
      ColorReference(lab: lch.toLab(), name: name);

  /// Restores a reference from [toJson] output.
  factory ColorReference.fromJson(JsonMap json) {
    final m = readOptionalMap(json, 'measurement');
    return ColorReference(
      lab: Lab.fromJson(readMap(json, 'lab')),
      name: readOptionalString(json, 'name'),
      measurement: m == null ? null : ColorMeasurement.fromJson(m),
    );
  }

  /// Lab values used for the comparison.
  final Lab lab;

  /// Optional display name.
  final String? name;

  /// The full measurement when the color came from the device.
  final ColorMeasurement? measurement;

  /// JSON form.
  JsonMap toJson() => {
    'lab': lab.toJson(),
    if (name != null) 'name': name,
    if (measurement != null) 'measurement': measurement!.toJson(),
  };
}

/// Result of comparing a sample against a standard.
@immutable
final class ColorComparison {
  const ColorComparison._({
    required this.standard,
    required this.sample,
    required this.difference,
    required this.settings,
    required this.verdict,
  });

  /// Compares [sample] against [standard] using [settings].
  factory ColorComparison.compare(
    ColorReference standard,
    ColorReference sample, {
    QcSettings? settings,
    WhitePoint whitePoint = WhitePoint.d65TenDegree,
  }) {
    final s = settings ?? QcSettings();
    final difference = DeltaE.difference(
      standard.lab,
      sample.lab,
      formula: s.formula,
      whitePoint: whitePoint,
    );
    return ColorComparison._(
      standard: standard,
      sample: sample,
      difference: difference,
      settings: s,
      verdict: s.enabled ? s.judge(difference.deltaE) : null,
    );
  }

  /// The reference color.
  final ColorReference standard;

  /// The color under test.
  final ColorReference sample;

  /// ΔL, Δa, Δb, ΔC, ΔH and ΔE (sample − standard).
  final ColorDifference difference;

  /// Settings used.
  final QcSettings settings;

  /// PASS / NG, or `null` when QC is disabled.
  final QcVerdict? verdict;

  /// ΔE for the selected formula.
  double get deltaE => difference.deltaE;
}
