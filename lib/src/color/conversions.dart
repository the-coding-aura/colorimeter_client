import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/color_spaces.dart';

/// Reference white (tristimulus values with Y = 100).
@immutable
final class WhitePoint {
  /// Creates a custom white point.
  const WhitePoint(this.x, this.y, this.z, {this.name = 'custom'});

  /// D65, 2° observer: the white point of sRGB (95.047, 100, 108.883).
  static const WhitePoint d65TwoDegree = WhitePoint(95.047, 100, 108.883, name: 'D65/2°');

  /// D65, 10° observer: what the LS170 reports (94.811, 100, 107.304).
  ///
  /// This is the package default.
  static const WhitePoint d65TenDegree = WhitePoint(94.811, 100, 107.304, name: 'D65/10°');

  /// Tristimulus X of the white.
  final double x;

  /// Tristimulus Y of the white (normally 100).
  final double y;

  /// Tristimulus Z of the white.
  final double z;

  /// Label for display.
  final String name;

  /// The white as an [Xyz].
  Xyz get xyz => Xyz(x, y, z);

  @override
  bool operator ==(Object other) =>
      other is WhitePoint && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() => 'WhitePoint($name)';
}

/// Color-space conversions.
///
/// Every function that depends on a reference white takes a `whitePoint`
/// argument that defaults to [WhitePoint.d65TenDegree], matching the
/// instrument. The sRGB matrices are the standard (D65/2°) ones; pass
/// [WhitePoint.d65TwoDegree] to get textbook sRGB ↔ Lab values (e.g. pure
/// white `#FFFFFF` → Lab(100, 0, 0)). With the 10° default, sRGB white maps
/// to roughly Lab(100, 0.4, −1.0).
abstract final class ColorConversions {
  static const double _epsilon = 216 / 24389;
  static const double _kappa = 24389 / 27;

  /// Lab → XYZ.
  static Xyz labToXyz(Lab lab, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) {
    final fy = (lab.l + 16) / 116;
    final fx = fy + lab.a / 500;
    final fz = fy - lab.b / 200;
    double inv(double f) {
      final f3 = f * f * f;
      return f3 > _epsilon ? f3 : (116 * f - 16) / _kappa;
    }

    final yr = lab.l > _kappa * _epsilon ? math.pow(fy, 3).toDouble() : lab.l / _kappa;
    return Xyz(inv(fx) * whitePoint.x, yr * whitePoint.y, inv(fz) * whitePoint.z);
  }

  /// XYZ → Lab.
  static Lab xyzToLab(Xyz xyz, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) {
    double f(double t) => t > _epsilon ? math.pow(t, 1 / 3).toDouble() : (_kappa * t + 16) / 116;
    final fx = f(xyz.x / whitePoint.x);
    final fy = f(xyz.y / whitePoint.y);
    final fz = f(xyz.z / whitePoint.z);
    return Lab(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
  }

  /// XYZ → Luv.
  static Luv xyzToLuv(Xyz xyz, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) {
    final yr = xyz.y / whitePoint.y;
    final l = yr > _epsilon ? 116 * math.pow(yr, 1 / 3).toDouble() - 16 : _kappa * yr;
    final (un, vn) = _uvPrime(whitePoint.xyz);
    final denominator = xyz.x + 15 * xyz.y + 3 * xyz.z;
    if (denominator == 0) return Luv(l, 0, 0);
    final (u, v) = _uvPrime(xyz);
    return Luv(l, 13 * l * (u - un), 13 * l * (v - vn));
  }

  /// Luv → XYZ.
  static Xyz luvToXyz(Luv luv, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) {
    if (luv.l <= 0) return const Xyz(0, 0, 0);
    final (un, vn) = _uvPrime(whitePoint.xyz);
    final y = luv.l > _kappa * _epsilon
        ? math.pow((luv.l + 16) / 116, 3).toDouble() * whitePoint.y
        : luv.l / _kappa * whitePoint.y;
    final u = luv.u / (13 * luv.l) + un;
    final v = luv.v / (13 * luv.l) + vn;
    final x = y * 9 * u / (4 * v);
    final z = y * (12 - 3 * u - 20 * v) / (4 * v);
    return Xyz(x, y, z);
  }

  static (double, double) _uvPrime(Xyz xyz) {
    final d = xyz.x + 15 * xyz.y + 3 * xyz.z;
    if (d == 0) return (0, 0);
    return (4 * xyz.x / d, 9 * xyz.y / d);
  }

  /// Lab → Luv (via XYZ).
  static Luv labToLuv(Lab lab, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) =>
      xyzToLuv(labToXyz(lab, whitePoint: whitePoint), whitePoint: whitePoint);

  /// XYZ → Yxy. Black maps to the white point's chromaticity.
  static Yxy xyzToYxy(Xyz xyz, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) {
    final sum = xyz.x + xyz.y + xyz.z;
    if (sum == 0) {
      final ws = whitePoint.x + whitePoint.y + whitePoint.z;
      return Yxy(0, whitePoint.x / ws, whitePoint.y / ws);
    }
    return Yxy(xyz.y, xyz.x / sum, xyz.y / sum);
  }

  /// Yxy → XYZ.
  static Xyz yxyToXyz(Yxy yxy) {
    if (yxy.y == 0) return const Xyz(0, 0, 0);
    final x = yxy.x * yxy.luminance / yxy.y;
    final z = (1 - yxy.x - yxy.y) * yxy.luminance / yxy.y;
    return Xyz(x, yxy.luminance, z);
  }

  /// Lab → Yxy (via XYZ).
  static Yxy labToYxy(Lab lab, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) =>
      xyzToYxy(labToXyz(lab, whitePoint: whitePoint), whitePoint: whitePoint);

  /// Lab → LCh.
  static LCh labToLch(Lab lab) => lab.toLch();

  /// LCh → Lab.
  static Lab lchToLab(LCh lch) => lch.toLab();

  /// 8-bit sRGB → XYZ (0–100, sRGB/D65 primaries).
  static Xyz rgbToXyz(Rgb rgb) {
    double lin(int c) {
      final v = c / 255;
      return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    }

    final r = lin(rgb.r), g = lin(rgb.g), b = lin(rgb.b);
    return Xyz(
      (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) * 100,
      (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) * 100,
      (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) * 100,
    );
  }

  /// XYZ → 8-bit sRGB. Out-of-gamut colors are clamped.
  static Rgb xyzToRgb(Xyz xyz) {
    final x = xyz.x / 100, y = xyz.y / 100, z = xyz.z / 100;
    final r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    final g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    final b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
    int enc(double v) {
      final c = v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
      return (c * 255).round().clamp(0, 255);
    }

    return Rgb(enc(r), enc(g), enc(b));
  }

  /// 8-bit sRGB → Lab.
  static Lab rgbToLab(Rgb rgb, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) =>
      xyzToLab(rgbToXyz(rgb), whitePoint: whitePoint);

  /// Lab → 8-bit sRGB (clamped).
  static Rgb labToRgb(Lab lab, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) =>
      xyzToRgb(labToXyz(lab, whitePoint: whitePoint));

  /// RGB → CMYK (naive, see [Cmyk.fromRgb]).
  static Cmyk rgbToCmyk(Rgb rgb) => Cmyk.fromRgb(rgb);

  /// CMYK → RGB (naive).
  static Rgb cmykToRgb(Cmyk cmyk) => cmyk.toRgb();
}
