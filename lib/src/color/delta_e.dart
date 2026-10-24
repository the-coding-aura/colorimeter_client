import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/color_spaces.dart';
import 'conversions.dart';

/// Color-difference formulas supported by the LS170 / LScolor.
enum DeltaEFormula {
  /// ΔE\*ab (CIE 1976): Euclidean distance in Lab.
  ab('ΔE*ab'),

  /// ΔE\*uv: Euclidean distance in CIELUV.
  uv('ΔE*uv'),

  /// ΔE\*94 (CIE 1994, graphic-arts weights kL = 1, K1 = 0.045, K2 = 0.015).
  cie94('ΔE*94'),

  /// ΔE\*cmc with l:c = 2:1 (acceptability).
  cmc2To1('ΔE*cmc(2:1)'),

  /// ΔE\*cmc with l:c = 1:1 (perceptibility).
  cmc1To1('ΔE*cmc(1:1)'),

  /// ΔE\*cmc with l:c = 1.4:1.
  cmc1Point4To1('ΔE*cmc(1.4:1)'),

  /// ΔE\*00 (CIEDE2000, kL = kC = kH = 1).
  cie2000('ΔE*00');

  const DeltaEFormula(this.label);

  /// Display label, e.g. `ΔE*cmc(2:1)`.
  final String label;
}

/// Signed differences between a standard and a sample (sample − standard).
@immutable
final class ColorDifference {
  /// Creates a color difference.
  const ColorDifference({
    required this.dL,
    required this.da,
    required this.db,
    required this.dC,
    required this.dH,
    required this.deltaE,
    required this.formula,
  });

  /// ΔL\*: positive means the sample is lighter.
  final double dL;

  /// Δa\*: positive means the sample is redder (less green).
  final double da;

  /// Δb\*: positive means the sample is yellower (less blue).
  final double db;

  /// ΔC\*ab: positive means the sample is more chromatic.
  final double dC;

  /// ΔH\*ab (signed by the direction of the hue rotation).
  final double dH;

  /// ΔE for [formula].
  final double deltaE;

  /// The formula used for [deltaE].
  final DeltaEFormula formula;

  @override
  String toString() => 'ColorDifference(${formula.label} = ${deltaE.toStringAsFixed(2)})';
}

/// Color-difference calculations.
///
/// The non-symmetric formulas (ΔE\*94 and ΔE\*cmc) use the first argument as
/// the reference (standard), as the CIE and SDC define them.
abstract final class DeltaE {
  /// Computes ΔE between [standard] and [sample] with [formula].
  ///
  /// [whitePoint] is only used by [DeltaEFormula.uv] (Lab → Luv).
  static double compute(
    Lab standard,
    Lab sample, {
    DeltaEFormula formula = DeltaEFormula.ab,
    WhitePoint whitePoint = WhitePoint.d65TenDegree,
  }) => switch (formula) {
    DeltaEFormula.ab => cie76(standard, sample),
    DeltaEFormula.uv => cieLuv(standard, sample, whitePoint: whitePoint),
    DeltaEFormula.cie94 => cie94(standard, sample),
    DeltaEFormula.cmc2To1 => cmc(standard, sample, lightness: 2, chroma: 1),
    DeltaEFormula.cmc1To1 => cmc(standard, sample),
    DeltaEFormula.cmc1Point4To1 => cmc(standard, sample, lightness: 1.4, chroma: 1),
    DeltaEFormula.cie2000 => ciede2000(standard, sample),
  };

  /// Full difference breakdown (ΔL, Δa, Δb, ΔC, ΔH and ΔE).
  static ColorDifference difference(
    Lab standard,
    Lab sample, {
    DeltaEFormula formula = DeltaEFormula.ab,
    WhitePoint whitePoint = WhitePoint.d65TenDegree,
  }) {
    final dL = sample.l - standard.l;
    final da = sample.a - standard.a;
    final db = sample.b - standard.b;
    final dC = sample.chroma - standard.chroma;
    final dH2 = math.max(0.0, da * da + db * db - dC * dC);
    var hueDelta = sample.hue - standard.hue;
    if (hueDelta > 180) hueDelta -= 360;
    if (hueDelta < -180) hueDelta += 360;
    final dH = (hueDelta < 0 ? -1 : 1) * math.sqrt(dH2);
    return ColorDifference(
      dL: dL,
      da: da,
      db: db,
      dC: dC,
      dH: dH,
      deltaE: compute(standard, sample, formula: formula, whitePoint: whitePoint),
      formula: formula,
    );
  }

  /// ΔE\*ab = √(ΔL² + Δa² + Δb²).
  static double cie76(Lab x, Lab y) {
    final dl = x.l - y.l, da = x.a - y.a, db = x.b - y.b;
    return math.sqrt(dl * dl + da * da + db * db);
  }

  /// ΔE\*uv = √(ΔL² + Δu² + Δv²) after converting both colors to CIELUV.
  static double cieLuv(Lab x, Lab y, {WhitePoint whitePoint = WhitePoint.d65TenDegree}) {
    final a = ColorConversions.labToLuv(x, whitePoint: whitePoint);
    final b = ColorConversions.labToLuv(y, whitePoint: whitePoint);
    return luvDistance(a, b);
  }

  /// Euclidean distance between two CIELUV colors (ΔE\*uv).
  static double luvDistance(Luv x, Luv y) {
    final dl = x.l - y.l, du = x.u - y.u, dv = x.v - y.v;
    return math.sqrt(dl * dl + du * du + dv * dv);
  }

  /// ΔE\*94. Defaults are the graphic-arts weights; textiles use
  /// `kL: 2, k1: 0.048, k2: 0.014`.
  static double cie94(
    Lab standard,
    Lab sample, {
    double kL = 1,
    double k1 = 0.045,
    double k2 = 0.015,
  }) {
    final c1 = standard.chroma, c2 = sample.chroma;
    final dL = standard.l - sample.l;
    final dC = c1 - c2;
    final da = standard.a - sample.a, db = standard.b - sample.b;
    final dH2 = math.max(0.0, da * da + db * db - dC * dC);
    final sC = 1 + k1 * c1;
    final sH = 1 + k2 * c1;
    final tL = dL / kL;
    final tC = dC / sC;
    return math.sqrt(tL * tL + tC * tC + dH2 / (sH * sH));
  }

  /// ΔE\*cmc(l:c). Use `lightness: 2` for 2:1, `1` for 1:1, `1.4` for 1.4:1.
  static double cmc(Lab standard, Lab sample, {double lightness = 1, double chroma = 1}) {
    final l1 = standard.l;
    final c1 = standard.chroma, c2 = sample.chroma;
    final dL = l1 - sample.l;
    final dC = c1 - c2;
    final da = standard.a - sample.a, db = standard.b - sample.b;
    final dH2 = math.max(0.0, da * da + db * db - dC * dC);
    final sL = l1 < 16 ? 0.511 : 0.040975 * l1 / (1 + 0.01765 * l1);
    final sC = 0.0638 * c1 / (1 + 0.0131 * c1) + 0.638;
    final h1 = standard.hue;
    final t = h1 >= 164 && h1 <= 345
        ? 0.56 + (0.2 * math.cos(_rad(h1 + 168))).abs()
        : 0.36 + (0.4 * math.cos(_rad(h1 + 35))).abs();
    final c14 = math.pow(c1, 4).toDouble();
    final f = math.sqrt(c14 / (c14 + 1900));
    final sH = sC * (f * t + 1 - f);
    final tL = dL / (lightness * sL);
    final tC = dC / (chroma * sC);
    return math.sqrt(tL * tL + tC * tC + dH2 / (sH * sH));
  }

  /// ΔE\*00 (CIEDE2000) following Sharma, Wu & Dalal (2005).
  static double ciede2000(Lab x, Lab y, {double kL = 1, double kC = 1, double kH = 1}) {
    const pow25To7 = 6103515625.0; // 25^7
    final c1 = x.chroma, c2 = y.chroma;
    final cBar = (c1 + c2) / 2;
    final cBar7 = math.pow(cBar, 7).toDouble();
    final g = 0.5 * (1 - math.sqrt(cBar7 / (cBar7 + pow25To7)));
    final a1p = (1 + g) * x.a, a2p = (1 + g) * y.a;
    final c1p = math.sqrt(a1p * a1p + x.b * x.b);
    final c2p = math.sqrt(a2p * a2p + y.b * y.b);
    double hp(double b, double ap) =>
        (b == 0 && ap == 0) ? 0 : normalizeHue(math.atan2(b, ap) * 180 / math.pi);
    final h1p = hp(x.b, a1p), h2p = hp(y.b, a2p);

    final dLp = y.l - x.l;
    final dCp = c2p - c1p;
    double dhp;
    if (c1p * c2p == 0) {
      dhp = 0;
    } else {
      dhp = h2p - h1p;
      if (dhp > 180) {
        dhp -= 360;
      } else if (dhp < -180) {
        dhp += 360;
      }
    }
    final dHp = 2 * math.sqrt(c1p * c2p) * math.sin(_rad(dhp / 2));

    final lBarP = (x.l + y.l) / 2;
    final cBarP = (c1p + c2p) / 2;
    double hBarP;
    if (c1p * c2p == 0) {
      hBarP = h1p + h2p;
    } else if ((h1p - h2p).abs() <= 180) {
      hBarP = (h1p + h2p) / 2;
    } else if (h1p + h2p < 360) {
      hBarP = (h1p + h2p + 360) / 2;
    } else {
      hBarP = (h1p + h2p - 360) / 2;
    }

    final t =
        1 -
        0.17 * math.cos(_rad(hBarP - 30)) +
        0.24 * math.cos(_rad(2 * hBarP)) +
        0.32 * math.cos(_rad(3 * hBarP + 6)) -
        0.20 * math.cos(_rad(4 * hBarP - 63));
    final dTheta = 30 * math.exp(-math.pow((hBarP - 275) / 25, 2));
    final cBarP7 = math.pow(cBarP, 7).toDouble();
    final rC = 2 * math.sqrt(cBarP7 / (cBarP7 + pow25To7));
    final lm50 = (lBarP - 50) * (lBarP - 50);
    final sL = 1 + 0.015 * lm50 / math.sqrt(20 + lm50);
    final sC = 1 + 0.045 * cBarP;
    final sH = 1 + 0.015 * cBarP * t;
    final rT = -math.sin(_rad(2 * dTheta)) * rC;

    final tL = dLp / (kL * sL);
    final tC = dCp / (kC * sC);
    final tH = dHp / (kH * sH);
    return math.sqrt(tL * tL + tC * tC + tH * tH + rT * tC * tH);
  }

  static double _rad(double deg) => deg * math.pi / 180;
}
