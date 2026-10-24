import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Rssi.parse', () {
    test('accepts valid values', () {
      expect(Rssi.parse(-60), -60);
      expect(Rssi.parse(-127), -127);
      expect(Rssi.parse(-1), -1);
      expect(Rssi.parse(-70.0), -70);
      expect(Rssi.parse(' -55 '), -55);
    });

    test('rejects missing and invalid values', () {
      for (final v in <Object?>[null, 0, 127, 5, -128, -70.5, double.nan, 'abc', true, <int>[]]) {
        expect(Rssi.parse(v), isNull, reason: '$v');
      }
    });
  });

  group('RssiThresholds', () {
    test('default buckets', () {
      const t = RssiThresholds();
      expect(t.classify(-50), SignalQuality.excellent);
      expect(t.classify(-60), SignalQuality.excellent);
      expect(t.classify(-61), SignalQuality.good);
      expect(t.classify(-70), SignalQuality.good);
      expect(t.classify(-75.5), SignalQuality.fair);
      expect(t.classify(-80), SignalQuality.fair);
      expect(t.classify(-81), SignalQuality.weak);
      expect(t.classify(null), SignalQuality.unknown);
      expect(t.classify(0), SignalQuality.unknown);
      expect(t.classify(double.nan), SignalQuality.unknown);
    });

    test('custom thresholds', () {
      const t = RssiThresholds(excellent: -45, good: -55, fair: -65);
      expect(t.classify(-50), SignalQuality.good);
      expect(t.classify(-66), SignalQuality.weak);
    });

    test('invalid thresholds are rejected', () {
      // ignore: prefer_const_constructors
      expect(() => RssiThresholds(excellent: -70, good: -60).validate(), throwsA(anything));
    });
  });

  group('RssiSmoother', () {
    test('exponential moving average', () {
      final s = RssiSmoother(alpha: 0.5);
      expect(s.value, isNull);
      expect(s.add(-60), -60);
      expect(s.add(-80), -70);
      expect(s.add(-70), -70);
    });

    test('ignores invalid samples', () {
      final s = RssiSmoother(alpha: 0.5)..add(-60);
      expect(s.add(null), -60);
      expect(s.add(127), -60);
      expect(s.add(0), -60);
    });

    test('alpha 1 disables smoothing; reset clears', () {
      final s = RssiSmoother(alpha: 1)..add(-60);
      expect(s.add(-90), -90);
      s.reset();
      expect(s.value, isNull);
    });

    test('alpha must be in (0, 1]', () {
      expect(() => RssiSmoother(alpha: 0), throwsRangeError);
      expect(() => RssiSmoother(alpha: 1.5), throwsRangeError);
    });
  });
}
