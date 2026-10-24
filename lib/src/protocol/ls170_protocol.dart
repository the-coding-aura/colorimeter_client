import 'package:flutter/foundation.dart';

/// UART-bridge GATT characteristics: notifications are received on
/// [notifyCharacteristic], commands are written to [writeCharacteristic].
@immutable
final class GattCharacteristicPair {
  /// Creates a pair. Use the same UUIDs twice for a shared characteristic.
  const GattCharacteristicPair({
    required this.notifyService,
    required this.notifyCharacteristic,
    required this.writeService,
    required this.writeCharacteristic,
  });

  /// Creates a pair where one characteristic is used for both roles.
  const GattCharacteristicPair.shared({required String service, required String characteristic})
    : notifyService = service,
      notifyCharacteristic = characteristic,
      writeService = service,
      writeCharacteristic = characteristic;

  /// Service of the notify characteristic.
  final String notifyService;

  /// Notify characteristic.
  final String notifyCharacteristic;

  /// Service of the write characteristic.
  final String writeService;

  /// Write characteristic.
  final String writeCharacteristic;

  @override
  String toString() => 'GattCharacteristicPair($notifyCharacteristic / $writeCharacteristic)';
}

/// GATT layout of the LS170 / LS171 (RF-star CC2640R2F transparent bridge).
abstract final class Ls170Gatt {
  /// Primary layout: notify FFE0/FFE4, write FFE5/FFE9.
  static const GattCharacteristicPair primary = GattCharacteristicPair(
    notifyService: '0000ffe0-0000-1000-8000-00805f9b34fb',
    notifyCharacteristic: '0000ffe4-0000-1000-8000-00805f9b34fb',
    writeService: '0000ffe5-0000-1000-8000-00805f9b34fb',
    writeCharacteristic: '0000ffe9-0000-1000-8000-00805f9b34fb',
  );

  /// Alternate firmware: 1001/1002 for both roles.
  static const GattCharacteristicPair alternate1001 = GattCharacteristicPair.shared(
    service: '00001001-0000-1000-8000-00805f9b34fb',
    characteristic: '00001002-0000-1000-8000-00805f9b34fb',
  );

  /// Alternate firmware: FFF0/FFF1 for both roles.
  static const GattCharacteristicPair alternateFff0 = GattCharacteristicPair.shared(
    service: '0000fff0-0000-1000-8000-00805f9b34fb',
    characteristic: '0000fff1-0000-1000-8000-00805f9b34fb',
  );

  /// Candidates in priority order; the first one present on the device is
  /// used.
  static const List<GattCharacteristicPair> candidates = [primary, alternate1001, alternateFff0];

  /// Client Characteristic Configuration Descriptor.
  static const String cccd = '00002902-0000-1000-8000-00805f9b34fb';

  /// MTU requested after connecting. Frames are still reassembled if the
  /// phone negotiates a smaller one.
  static const int requestedMtu = 247;

  /// Advertised-name prefixes of supported devices.
  static const List<String> namePrefixes = ['LS170', 'LS171'];
}

/// CRC-16/MODBUS (poly 0x8005 reflected, init 0xFFFF), the checksum that
/// terminates every LS170 command (stored little-endian).
abstract final class Crc16Modbus {
  /// Computes the CRC of [bytes].
  static int compute(List<int> bytes) {
    var crc = 0xFFFF;
    for (final byte in bytes) {
      crc ^= byte & 0xFF;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc;
  }
}

/// Command frames understood by the LS170.
abstract final class Ls170Commands {
  /// Start byte of every frame.
  static const int frameStart = 0xAB;

  /// Appends the CRC-16/MODBUS (little-endian) to [body].
  static Uint8List build(List<int> body) {
    final crc = Crc16Modbus.compute(body);
    return Uint8List.fromList([...body, crc & 0xFF, (crc >> 8) & 0xFF]);
  }

  /// Scan / measure: `AB 44 00 00 00 00 36 00 18 64`.
  static Uint8List get measure => build(const [0xAB, 0x44, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00]);

  /// White-tile calibration (bottom cap closed): `AB 20 2E 00 02 00 90 4F`.
  static Uint8List get calibrate => build(const [0xAB, 0x20, 0x2E, 0x00, 0x02, 0x00]);

  /// Battery query: `AB 20 0B 00 02 00 9B 43`.
  static Uint8List get battery => build(const [0xAB, 0x20, 0x0B, 0x00, 0x02, 0x00]);

  /// Device information: `AB 40 00 00 00 00 14 00 45 04`.
  static Uint8List get deviceInfo => build(const [0xAB, 0x40, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00]);
}

/// Frame types (byte 1).
enum Ls170FrameType {
  /// `0x44`: color result.
  colorResult(0x44),

  /// `0x20`: status response (battery, calibration).
  status(0x20),

  /// `0x40`: device information.
  deviceInfo(0x40),

  /// Anything else.
  unknown(-1);

  const Ls170FrameType(this.code);

  /// Byte value, or −1 for [unknown].
  final int code;

  /// Maps a type byte to a frame type.
  static Ls170FrameType fromCode(int code) => switch (code) {
    0x44 => colorResult,
    0x20 => status,
    0x40 => deviceInfo,
    _ => unknown,
  };
}

/// Sub-type (byte 2) of [Ls170FrameType.status] frames.
abstract final class Ls170StatusCode {
  /// Battery response.
  static const int battery = 0x0B;

  /// Calibration response.
  static const int calibration = 0x2E;
}

/// A complete frame received from the device.
@immutable
final class Ls170Frame {
  /// Wraps [bytes] (copied).
  Ls170Frame(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length < 2 || this.bytes[0] != Ls170Commands.frameStart) {
      throw ArgumentError.value(bytes, 'bytes', 'not an LS170 frame');
    }
  }

  /// Raw frame bytes.
  final Uint8List bytes;

  /// Frame type (byte 1).
  Ls170FrameType get type => Ls170FrameType.fromCode(bytes[1]);

  /// Byte 2, used as the sub-type of status frames.
  int? get subType => bytes.length > 2 ? bytes[2] : null;

  /// Little-endian length field at bytes 6–7, if present.
  int? get declaredLength => bytes.length >= 8 ? bytes[6] | (bytes[7] << 8) : null;

  /// Whether the last two bytes are a valid CRC-16/MODBUS of the rest.
  ///
  /// Commands carry this checksum; whether every response does is not
  /// verified, so the package does not reject frames that fail this check.
  bool get hasValidChecksum {
    if (bytes.length < 4) return false;
    final crc = Crc16Modbus.compute(bytes.sublist(0, bytes.length - 2));
    return bytes[bytes.length - 2] == (crc & 0xFF) && bytes[bytes.length - 1] == (crc >> 8);
  }

  /// Space-separated upper-case hex, e.g. `AB 44 00 ...`.
  String toHex() => bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  @override
  String toString() => 'Ls170Frame(${type.name}, ${bytes.length} bytes)';
}
