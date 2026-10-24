import 'package:flutter/foundation.dart';

/// Coarse signal-strength buckets.
enum SignalQuality {
  /// At or above [RssiThresholds.excellent].
  excellent,

  /// At or above [RssiThresholds.good].
  good,

  /// At or above [RssiThresholds.fair].
  fair,

  /// Below [RssiThresholds.fair].
  weak,

  /// No valid RSSI sample yet.
  unknown,
}

/// RSSI helpers.
abstract final class Rssi {
  /// Lowest RSSI value Android reports (dBm).
  static const int minValid = -127;

  /// Highest RSSI value treated as valid (dBm). Android uses 127 for
  /// "not available" and some stacks report 0 for unknown.
  static const int maxValid = -1;

  /// Whether [value] is a usable RSSI sample.
  static bool isValid(int? value) => value != null && value >= minValid && value <= maxValid;

  /// Parses a platform value into a valid RSSI, or `null` when missing or
  /// invalid (non-integer, out of range, or a "not available" sentinel).
  static int? parse(Object? raw) {
    final value = switch (raw) {
      final int v => v,
      final double v when v.isFinite && v == v.roundToDouble() => v.toInt(),
      final String v => int.tryParse(v.trim()),
      _ => null,
    };
    return isValid(value) ? value : null;
  }
}

/// Thresholds (dBm) separating the [SignalQuality] buckets.
///
/// RSSI depends heavily on the phone, the antenna orientation, the
/// environment and the device's transmit power, so these values are
/// configurable. Defaults: excellent ≥ −60, good ≥ −70, fair ≥ −80.
@immutable
final class RssiThresholds {
  /// Creates thresholds; they must satisfy `excellent > good > fair`.
  const RssiThresholds({this.excellent = -60, this.good = -70, this.fair = -80})
    : assert(excellent > good && good > fair, 'Thresholds must be strictly descending');

  /// Minimum RSSI for [SignalQuality.excellent].
  final int excellent;

  /// Minimum RSSI for [SignalQuality.good].
  final int good;

  /// Minimum RSSI for [SignalQuality.fair].
  final int fair;

  /// Throws [ArgumentError] if the thresholds are not strictly descending.
  /// Useful in release builds, where the constructor assert is skipped.
  void validate() {
    if (!(excellent > good && good > fair)) {
      throw ArgumentError('RSSI thresholds must satisfy excellent > good > fair');
    }
  }

  /// Classifies an RSSI sample (raw or smoothed).
  SignalQuality classify(num? rssi) {
    if (rssi == null || !rssi.isFinite || rssi < Rssi.minValid || rssi > Rssi.maxValid) {
      return SignalQuality.unknown;
    }
    if (rssi >= excellent) return SignalQuality.excellent;
    if (rssi >= good) return SignalQuality.good;
    if (rssi >= fair) return SignalQuality.fair;
    return SignalQuality.weak;
  }
}

/// Exponential moving average of RSSI samples.
///
/// `value = alpha * sample + (1 - alpha) * value`. Invalid samples are
/// ignored, so a single dropped reading does not disturb the estimate.
final class RssiSmoother {
  /// Creates a smoother. [alpha] must be in `(0, 1]`; 1 disables smoothing.
  RssiSmoother({this.alpha = 0.3}) {
    if (!(alpha > 0 && alpha <= 1)) {
      throw RangeError.value(alpha, 'alpha', 'must be in (0, 1]');
    }
  }

  /// Weight of the newest sample.
  final double alpha;

  double? _value;

  /// Current smoothed value, or `null` before the first valid sample.
  double? get value => _value;

  /// Adds a sample and returns the updated smoothed value.
  double? add(int? rssi) {
    if (!Rssi.isValid(rssi)) return _value;
    final sample = rssi!.toDouble();
    final previous = _value;
    _value = previous == null ? sample : alpha * sample + (1 - alpha) * previous;
    return _value;
  }

  /// Forgets all samples.
  void reset() => _value = null;
}
