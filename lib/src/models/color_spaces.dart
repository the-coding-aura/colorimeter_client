import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../json_utils.dart';

/// CIE L\*a\*b\* color.
@immutable
final class Lab {
  /// Creates a Lab color.
  const Lab(this.l, this.a, this.b);

  /// Creates a Lab color from its JSON form (`{"l":..,"a":..,"b":..}`).
  factory Lab.fromJson(JsonMap json) =>
      Lab(readDouble(json, 'l'), readDouble(json, 'a'), readDouble(json, 'b'));

  /// Lightness L\* (0 = black, 100 = diffuse white).
  final double l;

  /// Green (−) to red (+) axis a\*.
  final double a;

  /// Blue (−) to yellow (+) axis b\*.
  final double b;

  /// Chroma C\*ab = √(a² + b²).
  double get chroma => math.sqrt(a * a + b * b);

  /// Hue angle h\_ab in degrees, in `[0, 360)`.
  double get hue => normalizeHue(math.atan2(b, a) * 180 / math.pi);

  /// Converts to cylindrical LCh(ab).
  LCh toLch() => LCh(l, chroma, hue);

  /// JSON form of this color.
  JsonMap toJson() => {'l': l, 'a': a, 'b': b};

  @override
  bool operator ==(Object other) => other is Lab && other.l == l && other.a == a && other.b == b;

  @override
  int get hashCode => Object.hash(l, a, b);

  @override
  String toString() =>
      'Lab(${l.toStringAsFixed(2)}, ${a.toStringAsFixed(2)}, ${b.toStringAsFixed(2)})';
}

/// CIE LCh(ab) color, the cylindrical form of [Lab].
@immutable
final class LCh {
  /// Creates an LCh color. [h] is in degrees.
  const LCh(this.l, this.c, this.h);

  /// Creates an LCh color from its JSON form (`{"l":..,"c":..,"h":..}`).
  factory LCh.fromJson(JsonMap json) =>
      LCh(readDouble(json, 'l'), readDouble(json, 'c'), readDouble(json, 'h'));

  /// Lightness L\*.
  final double l;

  /// Chroma C\*.
  final double c;

  /// Hue angle in degrees.
  final double h;

  /// Converts to rectangular [Lab].
  Lab toLab() {
    final rad = h * math.pi / 180;
    return Lab(l, c * math.cos(rad), c * math.sin(rad));
  }

  /// JSON form of this color.
  JsonMap toJson() => {'l': l, 'c': c, 'h': h};

  @override
  bool operator ==(Object other) => other is LCh && other.l == l && other.c == c && other.h == h;

  @override
  int get hashCode => Object.hash(l, c, h);

  @override
  String toString() =>
      'LCh(${l.toStringAsFixed(2)}, ${c.toStringAsFixed(2)}, ${h.toStringAsFixed(2)})';
}

/// CIE L\*u\*v\* color.
@immutable
final class Luv {
  /// Creates a Luv color.
  const Luv(this.l, this.u, this.v);

  /// Creates a Luv color from its JSON form.
  factory Luv.fromJson(JsonMap json) =>
      Luv(readDouble(json, 'l'), readDouble(json, 'u'), readDouble(json, 'v'));

  /// Lightness L\*.
  final double l;

  /// u\* coordinate.
  final double u;

  /// v\* coordinate.
  final double v;

  /// JSON form of this color.
  JsonMap toJson() => {'l': l, 'u': u, 'v': v};

  @override
  bool operator ==(Object other) => other is Luv && other.l == l && other.u == u && other.v == v;

  @override
  int get hashCode => Object.hash(l, u, v);

  @override
  String toString() =>
      'Luv(${l.toStringAsFixed(2)}, ${u.toStringAsFixed(2)}, ${v.toStringAsFixed(2)})';
}

/// CIE Yxy color: luminance Y plus chromaticity coordinates x, y.
@immutable
final class Yxy {
  /// Creates a Yxy color. [luminance] is Y on a 0–100 scale.
  const Yxy(this.luminance, this.x, this.y);

  /// Creates a Yxy color from its JSON form (`{"Y":..,"x":..,"y":..}`).
  factory Yxy.fromJson(JsonMap json) =>
      Yxy(readDouble(json, 'Y'), readDouble(json, 'x'), readDouble(json, 'y'));

  /// Luminance Y (0–100).
  final double luminance;

  /// Chromaticity x.
  final double x;

  /// Chromaticity y.
  final double y;

  /// JSON form of this color.
  JsonMap toJson() => {'Y': luminance, 'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      other is Yxy && other.luminance == luminance && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(luminance, x, y);

  @override
  String toString() =>
      'Yxy(${luminance.toStringAsFixed(2)}, ${x.toStringAsFixed(4)}, ${y.toStringAsFixed(4)})';
}

/// CIE XYZ tristimulus values on a 0–100 scale (Y = 100 for the white point).
@immutable
final class Xyz {
  /// Creates an XYZ color.
  const Xyz(this.x, this.y, this.z);

  /// Tristimulus X.
  final double x;

  /// Tristimulus Y (luminance).
  final double y;

  /// Tristimulus Z.
  final double z;

  @override
  bool operator ==(Object other) => other is Xyz && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() =>
      'Xyz(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

/// 8-bit RGB color as reported by the device.
@immutable
final class Rgb {
  /// Creates an RGB color. Each channel must be in `0..255`.
  Rgb(this.r, this.g, this.b) {
    for (final c in [r, g, b]) {
      RangeError.checkValueInInterval(c, 0, 255, 'channel');
    }
  }

  /// Parses `#RRGGBB` or `RRGGBB` (case-insensitive).
  factory Rgb.fromHex(String hex) {
    final clean = hex.startsWith('#') ? hex.substring(1) : hex;
    final value = clean.length == 6 ? int.tryParse(clean, radix: 16) : null;
    if (value == null) throw FormatException('Not an #RRGGBB color', hex);
    return Rgb((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF);
  }

  /// Creates an RGB color from its JSON form.
  factory Rgb.fromJson(JsonMap json) =>
      Rgb(readInt(json, 'r'), readInt(json, 'g'), readInt(json, 'b'));

  /// Red channel (0–255).
  final int r;

  /// Green channel (0–255).
  final int g;

  /// Blue channel (0–255).
  final int b;

  /// `#RRGGBB` in upper case.
  String get hex =>
      '#${[r, g, b].map((c) => c.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

  /// ARGB integer (alpha = 0xFF), suitable for `Color(rgb.argb)`.
  int get argb => 0xFF000000 | (r << 16) | (g << 8) | b;

  /// Euclidean distance √(ΔR² + ΔG² + ΔB²).
  ///
  /// This is **not** a perceptual color difference; use `DeltaE` for QC.
  double distanceTo(Rgb other) {
    final dr = r - other.r, dg = g - other.g, db = b - other.b;
    return math.sqrt((dr * dr + dg * dg + db * db).toDouble());
  }

  /// JSON form of this color.
  JsonMap toJson() => {'r': r, 'g': g, 'b': b};

  @override
  bool operator ==(Object other) => other is Rgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'Rgb($r, $g, $b)';
}

/// Device-independent CMYK in percent (0–100), derived from RGB.
@immutable
final class Cmyk {
  /// Creates a CMYK color with channels in percent.
  const Cmyk(this.c, this.m, this.y, this.k);

  /// Naive (profile-free) RGB → CMYK conversion.
  ///
  /// The LS170 frame does not carry verified CMYK values, so this is what the
  /// package exposes as `ColorMeasurement.cmyk`. It is not a press profile.
  factory Cmyk.fromRgb(Rgb rgb) {
    final r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255;
    final k = 1 - math.max(r, math.max(g, b));
    if (k >= 1) return const Cmyk(0, 0, 0, 100);
    double ch(double v) => (1 - v - k) / (1 - k) * 100;
    return Cmyk(ch(r), ch(g), ch(b), k * 100);
  }

  /// Cyan, percent.
  final double c;

  /// Magenta, percent.
  final double m;

  /// Yellow, percent.
  final double y;

  /// Key (black), percent.
  final double k;

  /// Inverse of [Cmyk.fromRgb].
  Rgb toRgb() {
    int ch(double v) => (255 * (1 - v / 100) * (1 - k / 100)).round().clamp(0, 255);
    return Rgb(ch(c), ch(m), ch(y));
  }

  @override
  bool operator ==(Object other) =>
      other is Cmyk && other.c == c && other.m == m && other.y == y && other.k == k;

  @override
  int get hashCode => Object.hash(c, m, y, k);

  @override
  String toString() =>
      'Cmyk(${c.toStringAsFixed(1)}, ${m.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, ${k.toStringAsFixed(1)})';
}

/// Normalizes an angle in degrees to `[0, 360)`.
double normalizeHue(double degrees) {
  final h = degrees % 360;
  return h < 0 ? h + 360 : h;
}
