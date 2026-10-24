import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher labCloseTo(Lab e, [double tol = 1e-3]) => isA<Lab>()
    .having((x) => x.l, 'l', closeTo(e.l, tol))
    .having((x) => x.a, 'a', closeTo(e.a, tol))
    .having((x) => x.b, 'b', closeTo(e.b, tol));

void main() {
  group('conversions', () {
    test('Lab <-> LCh', () {
      const lab = Lab(50, -20, 20);
      final lch = lab.toLch();
      expect(lch.c, closeTo(28.2843, 1e-4));
      expect(lch.h, closeTo(135, 1e-9));
      expect(lch.toLab(), labCloseTo(lab));
      expect(const Lab(50, 0, -10).hue, closeTo(270, 1e-9));
    });

    test('Lab <-> XYZ round trip for both white points', () {
      for (final wp in [WhitePoint.d65TenDegree, WhitePoint.d65TwoDegree]) {
        for (final lab in const [Lab(92.59, -0.29, 0.55), Lab(5, 3, -4), Lab(60, 70, -50)]) {
          final back = ColorConversions.xyzToLab(
            ColorConversions.labToXyz(lab, whitePoint: wp),
            whitePoint: wp,
          );
          expect(back, labCloseTo(lab, 1e-9));
        }
      }
    });

    test('white maps to L=100 and zero chroma in Lab and Luv', () {
      const wp = WhitePoint.d65TenDegree;
      expect(ColorConversions.xyzToLab(wp.xyz), labCloseTo(const Lab(100, 0, 0), 1e-9));
      final luv = ColorConversions.xyzToLuv(wp.xyz);
      expect(luv.l, closeTo(100, 1e-9));
      expect(luv.u, closeTo(0, 1e-9));
      expect(luv.v, closeTo(0, 1e-9));
      expect(ColorConversions.xyzToLuv(const Xyz(0, 0, 0)), const Luv(0, 0, 0));
    });

    test('Luv round trip', () {
      const xyz = Xyz(30, 40, 20);
      final back = ColorConversions.luvToXyz(ColorConversions.xyzToLuv(xyz));
      expect(back.x, closeTo(30, 1e-9));
      expect(back.y, closeTo(40, 1e-9));
      expect(back.z, closeTo(20, 1e-9));
    });

    test('Yxy', () {
      final yxy = ColorConversions.xyzToYxy(const Xyz(20, 30, 50));
      expect(yxy, const Yxy(30, 0.2, 0.3));
      final xyz = ColorConversions.yxyToXyz(yxy);
      expect(xyz.x, closeTo(20, 1e-9));
      expect(xyz.z, closeTo(50, 1e-9));
      final black = ColorConversions.xyzToYxy(const Xyz(0, 0, 0));
      expect(black.luminance, 0);
      expect(black.x, closeTo(0.3138, 1e-3));
    });

    test('sRGB with the 2° white point gives textbook values', () {
      const wp = WhitePoint.d65TwoDegree;
      expect(
        ColorConversions.rgbToLab(Rgb(255, 255, 255), whitePoint: wp),
        labCloseTo(const Lab(100, 0, 0), 1e-2),
      );
      expect(
        ColorConversions.rgbToLab(Rgb(255, 0, 0), whitePoint: wp),
        labCloseTo(const Lab(53.2408, 80.0925, 67.2032), 1e-2),
      );
      expect(
        ColorConversions.labToRgb(const Lab(53.2408, 80.0925, 67.2032), whitePoint: wp),
        Rgb(255, 0, 0),
      );
      expect(ColorConversions.rgbToLab(Rgb(0, 0, 0)), labCloseTo(const Lab(0, 0, 0)));
    });

    test('the default white point is D65/10°', () {
      final white = ColorConversions.rgbToLab(Rgb(255, 255, 255));
      expect(white.l, closeTo(100, 1e-4));
      expect(white.a, isNot(closeTo(0, 0.1)));
    });

    test('RGB hex, distance and CMYK', () {
      expect(Rgb.fromHex('#ff8000'), Rgb(255, 128, 0));
      expect(Rgb.fromHex('00FF00').hex, '#00FF00');
      expect(() => Rgb.fromHex('#12'), throwsFormatException);
      expect(() => Rgb(256, 0, 0), throwsRangeError);
      expect(Rgb(0, 0, 0).distanceTo(Rgb(3, 4, 0)), 5);
      expect(Cmyk.fromRgb(Rgb(0, 0, 0)), const Cmyk(0, 0, 0, 100));
      final c = Cmyk.fromRgb(Rgb(255, 0, 0));
      expect([c.c, c.m, c.y, c.k], [0, 100, 100, 0]);
      expect(Cmyk.fromRgb(Rgb(12, 200, 99)).toRgb(), Rgb(12, 200, 99));
    });
  });

  group('DeltaE', () {
    // Sharma, Wu & Dalal (2005) test data.
    const sharma = [
      (Lab(50, 2.6772, -79.7751), Lab(50, 0, -82.7485), 2.0425),
      (Lab(50, 3.1571, -77.2803), Lab(50, 0, -82.7485), 2.8615),
      (Lab(50, 2.8361, -74.02), Lab(50, 0, -82.7485), 3.4412),
      (Lab(50, 0, 0), Lab(50, -1, 2), 2.3669),
      (Lab(50, 2.5, 0), Lab(73, 25, -18), 27.1492),
      (Lab(50, 2.5, 0), Lab(61, -5, 29), 22.8977),
      (Lab(60.2574, -34.0099, 36.2677), Lab(60.4626, -34.1751, 39.4387), 1.2644),
      (Lab(2.0776, 0.0795, -1.135), Lab(0.9033, -0.0636, -0.5514), 0.9082),
    ];

    test('CIEDE2000 matches Sharma reference data', () {
      for (final (a, b, expected) in sharma) {
        expect(DeltaE.ciede2000(a, b), closeTo(expected, 1e-4), reason: '$a vs $b');
        expect(DeltaE.ciede2000(b, a), closeTo(expected, 1e-4));
      }
    });

    test('ΔE*ab is Euclidean', () {
      expect(DeltaE.cie76(const Lab(50, 0, 0), const Lab(53, 4, 0)), 5);
      expect(DeltaE.compute(const Lab(1, 2, 3), const Lab(1, 2, 3)), 0);
    });

    test('ΔE*94 and ΔE*cmc reduce to known cases', () {
      const std = Lab(50, 0, 0);
      // Lightness-only difference: CIE94 SL = 1.
      expect(DeltaE.cie94(std, const Lab(52, 0, 0)), closeTo(2, 1e-12));
      // CMC: SL = 0.040975 L / (1 + 0.01765 L).
      const sL = 0.040975 * 50 / (1 + 0.01765 * 50);
      expect(DeltaE.cmc(std, const Lab(52, 0, 0)), closeTo(2 / sL, 1e-12));
      expect(DeltaE.cmc(std, const Lab(52, 0, 0), lightness: 2), closeTo(1 / sL, 1e-12));
      // Neutral standard: CIE94 SC = SH = 1, so it equals ΔE*ab.
      expect(DeltaE.cie94(std, const Lab(50, 3, 4)), closeTo(5, 1e-12));
      // Below L=16 the CMC lightness weight is the constant 0.511.
      expect(DeltaE.cmc(const Lab(10, 0, 0), const Lab(11, 0, 0)), closeTo(1 / 0.511, 1e-12));
    });

    test('CMC variants are ordered by the lightness weight', () {
      const a = Lab(60, 20, 10), b = Lab(63, 22, 9);
      final v21 = DeltaE.compute(a, b, formula: DeltaEFormula.cmc2To1);
      final v141 = DeltaE.compute(a, b, formula: DeltaEFormula.cmc1Point4To1);
      final v11 = DeltaE.compute(a, b, formula: DeltaEFormula.cmc1To1);
      expect(v21, lessThan(v141));
      expect(v141, lessThan(v11));
    });

    test('ΔE*uv uses CIELUV', () {
      const a = Lab(50, 10, 10), b = Lab(50, 12, 8);
      final expected = DeltaE.luvDistance(
        ColorConversions.labToLuv(a),
        ColorConversions.labToLuv(b),
      );
      expect(DeltaE.compute(a, b, formula: DeltaEFormula.uv), closeTo(expected, 1e-12));
      expect(expected, greaterThan(0));
    });

    test('every formula is zero for identical colors', () {
      for (final f in DeltaEFormula.values) {
        expect(DeltaE.compute(const Lab(40, 5, -7), const Lab(40, 5, -7), formula: f), 0);
      }
    });

    test('difference breakdown is sample minus standard', () {
      final d = DeltaE.difference(const Lab(50, 10, 0), const Lab(52, 0, 10));
      expect(d.dL, 2);
      expect(d.da, -10);
      expect(d.db, 10);
      expect(d.dC, closeTo(0, 1e-12));
      expect(d.dH, closeTo(14.1421, 1e-4)); // hue rotated counter-clockwise
      expect(d.deltaE, closeTo(14.2829, 1e-4));
    });
  });

  group('QC', () {
    test('threshold range 0.1–50', () {
      expect(() => QcSettings(threshold: 0.05), throwsRangeError);
      expect(() => QcSettings(threshold: 50.1), throwsRangeError);
      expect(QcSettings(threshold: 0.1).threshold, 0.1);
      expect(QcSettings(threshold: 50).threshold, 50);
      expect(QcSettings.lenient(threshold: 99).threshold, QcSettings.defaultThreshold);
      expect(QcSettings.lenient(threshold: double.nan).threshold, QcSettings.defaultThreshold);
    });

    test('PASS when ΔE <= threshold, NG above', () {
      final s = QcSettings(threshold: 2);
      expect(s.judge(2), QcVerdict.pass);
      expect(s.judge(2.0001), QcVerdict.ng);
    });

    test('comparison with typed LCh standard', () {
      final standard = ColorReference.fromLch(const LCh(50, 10, 0), name: 'Std');
      const sample = ColorReference(lab: Lab(51, 10, 0));
      final result = ColorComparison.compare(
        standard,
        sample,
        settings: QcSettings(threshold: 0.5),
      );
      expect(result.deltaE, closeTo(1, 1e-9));
      expect(result.verdict, QcVerdict.ng);
      final noQc = ColorComparison.compare(standard, sample, settings: QcSettings(enabled: false));
      expect(noQc.verdict, isNull);
    });
  });

  group('chart matching', () {
    final chart = ColorChart(
      name: 'Demo',
      colors: const [
        ChartColor(code: 'W-01', name: 'White', lab: Lab(95, 0, 0)),
        ChartColor(code: 'G-50', name: 'Mid grey', lab: Lab(50, 0, 0)),
        ChartColor(code: 'R-10', name: 'Red', lab: Lab(50, 60, 40)),
        ChartColor(code: 'G-55', name: 'Light grey', lab: Lab(55, 0, 0)),
      ],
    );
    final chart2 = ColorChart(
      name: 'Other',
      colors: const [ChartColor(code: 'X-1', lab: Lab(49, 1, 0))],
    );

    test('returns the three nearest across charts, nearest first', () {
      final m = ColorChartMatcher.nearest(const Lab(50, 0, 0), [chart, chart2]);
      expect(m.map((x) => x.color.code), ['G-50', 'X-1', 'G-55']);
      expect(m.first.deltaE, 0);
      expect(m[1].chart.name, 'Other');
      expect(ColorChartMatcher.nearest(const Lab(0, 0, 0), [chart], count: 10), hasLength(4));
      expect(ColorChartMatcher.nearest(const Lab(0, 0, 0), const []), isEmpty);
    });

    test('fuzzy search over code and name', () {
      expect(chart.search('grey').map((c) => c.code), ['G-50', 'G-55']);
      expect(chart.search('r-1').single.code, 'R-10');
      expect(chart.search(''), hasLength(4));
      expect(ColorChartMatcher.search([chart, chart2], 'x').single.$2.code, 'X-1');
    });
  });
}
