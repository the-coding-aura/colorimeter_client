import 'dart:typed_data';

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> hex(String s) => [for (final p in s.split(' ')) int.parse(p, radix: 16)];

void main() {
  group('Ls170Commands', () {
    test('match the commands verified on hardware', () {
      expect(Ls170Commands.measure, hex('AB 44 00 00 00 00 36 00 18 64'));
      expect(Ls170Commands.calibrate, hex('AB 20 2E 00 02 00 90 4F'));
      expect(Ls170Commands.battery, hex('AB 20 0B 00 02 00 9B 43'));
      expect(Ls170Commands.deviceInfo, hex('AB 40 00 00 00 00 14 00 45 04'));
    });

    test('getters return independent copies', () {
      final a = Ls170Commands.measure..[0] = 0;
      expect(a[0], 0);
      expect(Ls170Commands.measure[0], 0xAB);
    });

    test('CRC-16/MODBUS reference value', () {
      // "123456789" -> 0x4B37 (standard check value).
      expect(Crc16Modbus.compute('123456789'.codeUnits), 0x4B37);
    });
  });

  group('Ls170FrameAssembler', () {
    late Ls170FrameAssembler assembler;
    setUp(() => assembler = Ls170FrameAssembler());

    test('expected lengths follow the header rules', () {
      expect(Ls170FrameAssembler.expectedLength(hex('AB 44 00 00 00 00 36 00')), 62);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 44 00 00 00 00 05 00')), 39);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 44 00 00 00 00 FF 00')), 39);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 44 00')), 39);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 20 0B')), 10);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 40 00')), 40);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 55 00 00 00 00 06 00')), 14);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 55 00 00 00 00 02 00')), -1);
      expect(Ls170FrameAssembler.expectedLength(hex('AB 55 00')), -1);
    });

    test('reassembles a fragmented AB44 frame', () {
      final frame = Ls170FrameEncoder.colorResult(lab: const Lab(50, 10, -10));
      final chunks = Ls170FrameEncoder.chunk(frame);
      expect(chunks.length, greaterThan(1));
      final out = <Ls170Frame>[];
      for (final c in chunks) {
        out.addAll(assembler.add(c));
      }
      expect(out, hasLength(1));
      expect(out.single.bytes, frame);
      expect(out.single.type, Ls170FrameType.colorResult);
      expect(assembler.bufferedLength, 0);
    });

    test('a chunk starting with 0xAB discards a partial frame', () {
      final color = Ls170FrameEncoder.colorResult(lab: const Lab(50, 0, 0));
      expect(assembler.add(color.sublist(0, 20)), isEmpty);
      final battery = Ls170FrameEncoder.battery(80);
      final out = assembler.add(battery);
      expect(out.single.type, Ls170FrameType.status);
      expect(out.single.subType, Ls170StatusCode.battery);
    });

    test('keeps leftover bytes after a complete frame', () {
      final a = Ls170FrameEncoder.battery(1);
      final b = Ls170FrameEncoder.calibration();
      final out = assembler.add([...a, ...b.sublist(0, 4)]);
      expect(out, hasLength(1));
      expect(assembler.bufferedLength, 4);
      // A continuation chunk (not starting with 0xAB) completes the second.
      final rest = assembler.add(b.sublist(4));
      expect(rest.single.subType, Ls170StatusCode.calibration);
    });

    test('extracts several frames from one chunk', () {
      final out = assembler.add([
        ...Ls170FrameEncoder.battery(1),
        ...Ls170FrameEncoder.calibration(),
        ...Ls170FrameEncoder.deviceInfo(),
      ]);
      expect(out.map((f) => f.type), [
        Ls170FrameType.status,
        Ls170FrameType.status,
        Ls170FrameType.deviceInfo,
      ]);
    });

    test('ignores garbage and empty chunks', () {
      expect(assembler.add([]), isEmpty);
      expect(assembler.add([1, 2, 3, 4]), isEmpty);
      expect(assembler.add(Ls170FrameEncoder.battery(5)), hasLength(1));
    });

    test('bounds the buffer', () {
      final small = Ls170FrameAssembler(maxBufferSize: 16);
      small.add(hex('AB 55 00 00 00 00 C8 00'));
      small.add(List.filled(20, 0));
      expect(small.bufferedLength, 0);
    });
  });

  group('Ls170Parser', () {
    test('parses the AB44 layout', () {
      final bytes = Uint8List(62);
      final data = ByteData.sublistView(bytes);
      bytes
        ..[0] = 0xAB
        ..[1] = 0x44;
      data.setUint16(6, 0x36, Endian.little);
      final values = [9259, -29, 55, 9259, -50, 80, 9259, 62, 11792, 8213, 3140, 3310];
      for (var i = 0; i < values.length; i++) {
        data.setInt16(8 + i * 2, values[i], Endian.little);
      }
      data.setUint16(24, 11792, Endian.little);
      bytes.setRange(32, 39, [1, 2, 3, 4, 236, 234, 231]);

      final m = Ls170Parser.parseColorResult(Ls170Frame(bytes))!;
      expect(m.lab, const Lab(92.59, -0.29, 0.55));
      expect(m.luv, const Luv(92.59, -0.5, 0.8));
      expect(m.lch.l, 92.59);
      expect(m.lch.c, 0.62);
      expect(m.lch.h, closeTo(117.92, 1e-9));
      expect(m.yxy, const Yxy(82.13, 31.4, 33.1));
      expect(m.reserved, [1, 2, 3, 4]);
      expect(m.rgb, Rgb(236, 234, 231));
      expect(m.hex, '#ECEAE7');
      expect(m.source, MeasurementSource.app);
      expect(m.rawFrame, bytes);
    });

    test('hue above 327.67 is decoded as unsigned', () {
      final frame = Ls170FrameEncoder.colorResult(
        lab: const Lab(50, 10, -1),
        lch: const LCh(50, 10.05, 354.29),
      );
      final m = Ls170Parser.parseColorResult(Ls170Frame(frame))!;
      expect(m.lch.h, closeTo(354.29, 1e-9));
    });

    test('rejects short or foreign frames', () {
      expect(Ls170Parser.parseColorResult(Ls170Frame(hex('AB 44 00 00'))), isNull);
      expect(Ls170Parser.parseColorResult(Ls170Frame(Ls170FrameEncoder.battery(3))), isNull);
      expect(() => Ls170Frame([0x00, 0x44]), throwsArgumentError);
    });

    test('encoder frames round-trip and carry a valid CRC', () {
      final frame = Ls170Frame(
        Ls170FrameEncoder.colorResult(lab: const Lab(40.12, -20.5, 33.33), rgb: Rgb(1, 2, 3)),
      );
      expect(frame.hasValidChecksum, isTrue);
      final m = Ls170Parser.parseColorResult(frame, source: MeasurementSource.deviceButton)!;
      expect(m.lab, const Lab(40.12, -20.5, 33.33));
      expect(m.rgb, Rgb(1, 2, 3));
      expect(m.source, MeasurementSource.deviceButton);
    });

    test('battery, calibration and device info', () {
      final battery = Ls170Parser.parseBattery(Ls170Frame(Ls170FrameEncoder.battery(87)))!;
      expect(battery.rawValue, 87);
      expect(battery.percent, 87);
      expect(
        Ls170Parser.parseBattery(Ls170Frame(Ls170FrameEncoder.battery(4100)))!.percent,
        isNull,
      );
      expect(Ls170Parser.parseBattery(Ls170Frame(Ls170FrameEncoder.calibration())), isNull);

      final cal = Ls170Parser.parseCalibration(Ls170Frame(Ls170FrameEncoder.calibration()))!;
      expect(cal.isSuccess, isTrue);
      expect(Ls170Parser.parseCalibration(Ls170Frame(Ls170FrameEncoder.battery(1))), isNull);

      final info = Ls170Parser.parseDeviceInfo(
        Ls170Frame(
          Ls170FrameEncoder.deviceInfo(payload: [...'V1.2'.codeUnits, 0, ...'2024'.codeUnits]),
        ),
        deviceId: 'AA:BB',
        deviceName: 'LS171X99',
      )!;
      expect(info.model, ColorimeterModel.ls171);
      expect(info.serialNumber, 'X99');
      expect(info.printableStrings, ['V1.2', '2024']);
      expect(info.rawFrame, hasLength(40));
    });
  });
}
