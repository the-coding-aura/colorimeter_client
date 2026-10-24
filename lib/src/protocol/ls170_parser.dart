import 'dart:typed_data';

import '../models/color_measurement.dart';
import '../models/color_spaces.dart';
import '../models/device_models.dart';
import 'frame_assembler.dart';
import 'ls170_protocol.dart';

/// Decoders for LS170 response frames.
abstract final class Ls170Parser {
  /// Decodes an AB44 color result, or returns `null` when [frame] is not a
  /// color result or is too short.
  ///
  /// Layout: int16 LE / 100 at offsets 8.. (Lab, Luv, LCh, Yxy), 4 reserved
  /// bytes at 32–35, RGB bytes at 36–38. The hue at offset 24 is read as
  /// unsigned because 0–360.00 exceeds the int16 range.
  static ColorMeasurement? parseColorResult(
    Ls170Frame frame, {
    MeasurementSource source = MeasurementSource.app,
    DateTime? timestamp,
  }) {
    final bytes = frame.bytes;
    if (frame.type != Ls170FrameType.colorResult ||
        bytes.length < Ls170FrameAssembler.colorFrameMinLength) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    double v(int offset) => data.getInt16(offset, Endian.little) / 100.0;
    return ColorMeasurement(
      lab: Lab(v(8), v(10), v(12)),
      luv: Luv(v(14), v(16), v(18)),
      lch: LCh(v(20), v(22), data.getUint16(24, Endian.little) / 100.0),
      yxy: Yxy(v(26), v(28), v(30)),
      reserved: bytes.sublist(32, 36),
      rgb: Rgb(bytes[36], bytes[37], bytes[38]),
      source: source,
      timestamp: timestamp ?? DateTime.now(),
      rawFrame: bytes,
    );
  }

  /// Decodes an `AB 20 0B` battery response, or `null` for other frames.
  static BatteryStatus? parseBattery(Ls170Frame frame, {DateTime? timestamp}) {
    if (frame.type != Ls170FrameType.status ||
        frame.subType != Ls170StatusCode.battery ||
        frame.bytes.length < 8) {
      return null;
    }
    final raw = ByteData.sublistView(frame.bytes).getInt16(6, Endian.little);
    return BatteryStatus(
      rawValue: raw,
      timestamp: timestamp ?? DateTime.now(),
      rawFrame: frame.bytes,
    );
  }

  /// Decodes an `AB 20 2E` calibration response, or `null` for other frames.
  ///
  /// Receiving the response is treated as success (verified on hardware).
  /// The failure encoding is unknown, so [CalibrationStatus.failed] is never
  /// produced from a frame yet.
  static CalibrationResult? parseCalibration(Ls170Frame frame, {DateTime? timestamp}) {
    if (frame.type != Ls170FrameType.status || frame.subType != Ls170StatusCode.calibration) {
      return null;
    }
    return CalibrationResult(
      status: CalibrationStatus.success,
      timestamp: timestamp ?? DateTime.now(),
      rawFrame: frame.bytes,
    );
  }

  /// Decodes an AB40 device-info response, or `null` for other frames.
  ///
  /// Model and serial number come from the advertised [deviceName]; the frame
  /// layout is not verified, so only [DeviceInfo.printableStrings] is
  /// extracted from it.
  static DeviceInfo? parseDeviceInfo(
    Ls170Frame frame, {
    required String deviceId,
    String? deviceName,
    DateTime? timestamp,
  }) {
    if (frame.type != Ls170FrameType.deviceInfo) return null;
    final model = ColorimeterModel.fromAdvertisedName(deviceName);
    String? serial;
    if (model != null && deviceName != null) {
      final s = deviceName.trim().substring(model.namePrefix.length).trim();
      serial = s.isEmpty ? null : s;
    }
    final payload = frame.bytes.length > 8 ? frame.bytes.sublist(8) : Uint8List(0);
    return DeviceInfo(
      deviceId: deviceId,
      name: deviceName,
      model: model,
      serialNumber: serial,
      timestamp: timestamp ?? DateTime.now(),
      rawFrame: frame.bytes,
      printableStrings: printableRuns(payload),
    );
  }

  /// Runs of printable ASCII (0x20–0x7E) of at least [minLength] characters.
  static List<String> printableRuns(List<int> bytes, {int minLength = 3}) {
    final runs = <String>[];
    final current = StringBuffer();
    void flush() {
      final s = current.toString().trim();
      if (s.length >= minLength) runs.add(s);
      current.clear();
    }

    for (final b in bytes) {
      if (b >= 0x20 && b <= 0x7E) {
        current.writeCharCode(b);
      } else {
        flush();
      }
    }
    flush();
    return runs;
  }
}
