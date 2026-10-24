import 'dart:typed_data';

import '../color/conversions.dart';
import '../models/color_spaces.dart';
import '../protocol/ls170_protocol.dart';

/// Builds LS170 response frames, for tests and simulators.
abstract final class Ls170FrameEncoder {
  /// An AB44 color result. Missing color spaces are derived from [lab]
  /// (D65/10°). [declaredLength] is written at bytes 6–7; the default (54)
  /// produces a 62-byte frame, like the request.
  static Uint8List colorResult({
    required Lab lab,
    Luv? luv,
    LCh? lch,
    Yxy? yxy,
    Rgb? rgb,
    List<int> reserved = const [0, 0, 0, 0],
    int declaredLength = 0x36,
  }) {
    final total = declaredLength >= 30 && declaredLength <= 200 ? declaredLength + 8 : 39;
    final length = total < 39 ? 39 : total;
    final data = ByteData(length);
    final bytes = data.buffer.asUint8List();
    bytes
      ..[0] = 0xAB
      ..[1] = 0x44;
    data.setUint16(6, declaredLength, Endian.little);
    final u = luv ?? ColorConversions.labToLuv(lab);
    final c = lch ?? lab.toLch();
    final y = yxy ?? ColorConversions.labToYxy(lab);
    final values = [lab.l, lab.a, lab.b, u.l, u.u, u.v, c.l, c.c, c.h, y.luminance, y.x, y.y];
    for (var i = 0; i < values.length; i++) {
      final raw = (values[i] * 100).round();
      // Hue (offset 24) spans 0–360.00, beyond the int16 range.
      if (8 + i * 2 == 24) {
        data.setUint16(24, raw, Endian.little);
      } else {
        data.setInt16(8 + i * 2, raw, Endian.little);
      }
    }
    for (var i = 0; i < 4; i++) {
      bytes[32 + i] = i < reserved.length ? reserved[i] & 0xFF : 0;
    }
    final color = rgb ?? ColorConversions.labToRgb(lab);
    bytes
      ..[36] = color.r
      ..[37] = color.g
      ..[38] = color.b;
    _appendCrc(bytes, from: 39);
    return bytes;
  }

  /// An `AB 20 0B` battery response with [value] at bytes 6–7.
  static Uint8List battery(int value) {
    final data = ByteData(10);
    final bytes = data.buffer.asUint8List();
    bytes
      ..[0] = 0xAB
      ..[1] = 0x20
      ..[2] = Ls170StatusCode.battery;
    data.setInt16(6, value, Endian.little);
    _appendCrc(bytes, from: 8);
    return bytes;
  }

  /// An `AB 20 2E` calibration response.
  static Uint8List calibration({List<int> status = const [0x02, 0x00, 0x00, 0x00]}) {
    final bytes = Uint8List(10)
      ..[0] = 0xAB
      ..[1] = 0x20
      ..[2] = Ls170StatusCode.calibration;
    for (var i = 0; i < 4 && i < status.length; i++) {
      bytes[4 + i] = status[i] & 0xFF;
    }
    _appendCrc(bytes, from: 8);
    return bytes;
  }

  /// A 40-byte AB40 device-info response with [payload] from offset 8.
  static Uint8List deviceInfo({List<int> payload = const []}) {
    final bytes = Uint8List(40)
      ..[0] = 0xAB
      ..[1] = 0x40
      ..[6] = 0x20;
    for (var i = 0; i < payload.length && 8 + i < 38; i++) {
      bytes[8 + i] = payload[i] & 0xFF;
    }
    _appendCrc(bytes, from: 38);
    return bytes;
  }

  /// Splits [frame] into notification-sized chunks.
  static List<Uint8List> chunk(Uint8List frame, {int size = 20}) => [
    for (var i = 0; i < frame.length; i += size)
      Uint8List.sublistView(frame, i, i + size > frame.length ? frame.length : i + size),
  ];

  /// Writes the CRC of the bytes before the last two into the last two
  /// (only when the frame is long enough to keep the payload intact).
  static void _appendCrc(Uint8List bytes, {required int from}) {
    if (bytes.length < from + 2) return;
    final crc = Crc16Modbus.compute(bytes.sublist(0, bytes.length - 2));
    bytes[bytes.length - 2] = crc & 0xFF;
    bytes[bytes.length - 1] = crc >> 8;
  }
}
