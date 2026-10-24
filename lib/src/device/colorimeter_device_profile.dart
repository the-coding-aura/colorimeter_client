import 'package:flutter/foundation.dart';

import '../exceptions.dart';
import '../models/color_measurement.dart';
import '../models/device_models.dart';
import '../protocol/frame_assembler.dart';
import '../protocol/ls170_parser.dart';
import '../protocol/ls170_protocol.dart';

/// One reassembled notification, decoded by a [ColorimeterProtocol].
abstract interface class ProtocolFrame {
  /// Raw frame bytes.
  Uint8List get bytes;

  /// Space-separated upper-case hex.
  String toHex();

  /// Whether this frame is a color reading (app command or device button).
  bool get isColorResult;

  /// Color reading, or `null` when this frame is not one.
  ColorMeasurement? parseColor({
    MeasurementSource source = MeasurementSource.app,
    DateTime? timestamp,
  });

  /// Battery reading, or `null` when this frame is not one.
  BatteryStatus? parseBattery({DateTime? timestamp});

  /// Calibration reading, or `null` when this frame is not one.
  CalibrationResult? parseCalibration({DateTime? timestamp});

  /// Device information, or `null` when this frame is not one.
  DeviceInfo? parseDeviceInfo({required String deviceId, String? deviceName, DateTime? timestamp});
}

/// Turns notification chunks into [ProtocolFrame]s for one connection.
abstract interface class ProtocolDecoder {
  /// Drops a partial frame. Called when the link comes up or a command is sent.
  void reset();

  /// Feeds one notification chunk.
  List<ProtocolFrame> add(List<int> chunk);
}

/// How to speak to one family of colorimeters over BLE.
///
/// LS170 and LS171 share [Ls170Protocol]. A future instrument implements this
/// interface and is passed to [ColorimeterDeviceProfile].
abstract interface class ColorimeterProtocol {
  /// MTU requested after connecting.
  int get requestedMtu;

  /// Client Characteristic Configuration Descriptor UUID.
  String get cccd;

  /// UART layouts tried in order. The first one present on the device is used.
  List<GattCharacteristicPair> get gattCandidates;

  /// Bytes written for [operation].
  ///
  /// Throws [UnsupportedError] when the instrument has no such command.
  Uint8List commandFor(ColorimeterOperation operation);

  /// Decoder for one connection.
  ProtocolDecoder createDecoder();
}

/// A colorimeter family the client knows how to scan and talk to.
///
/// The built-in family is [linshangLs170]: Linshang LS170 and LS171, which use
/// the same BLE protocol and are distinguished only by the advertised name.
/// Add a future instrument by constructing another profile and passing it to
/// `ColorimeterClient(profiles: ...)`.
@immutable
final class ColorimeterDeviceProfile {
  /// Creates a profile. [models] must not be empty. Longer name prefixes are
  /// matched before shorter ones, so `LS1700` wins over `LS170`.
  const ColorimeterDeviceProfile({required this.id, required this.models, required this.protocol});

  /// Linshang LS170 and LS171.
  static const ColorimeterDeviceProfile linshangLs170 = ColorimeterDeviceProfile(
    id: 'linshang-ls170',
    models: [ColorimeterModel.ls170, ColorimeterModel.ls171],
    protocol: Ls170Protocol.instance,
  );

  /// Profiles shipped with this package.
  static const List<ColorimeterDeviceProfile> builtIn = [linshangLs170];

  /// Stable id, for example `linshang-ls170`.
  final String id;

  /// Models this profile accepts. Each model's [ColorimeterModel.namePrefix]
  /// is the BLE advertised-name prefix.
  final List<ColorimeterModel> models;

  /// GATT layout, commands and frame decoder.
  final ColorimeterProtocol protocol;

  /// Advertised-name prefixes, in model order.
  List<String> get namePrefixes => [for (final model in models) model.namePrefix];

  /// The model in this profile whose prefix matches [advertisedName].
  ///
  /// The longest matching prefix wins.
  ColorimeterModel? modelFor(String? advertisedName) =>
      ColorimeterModel.fromAdvertisedName(advertisedName, catalog: models);

  @override
  String toString() => 'ColorimeterDeviceProfile($id)';
}

/// BLE protocol shared by the Linshang LS170 and LS171.
final class Ls170Protocol implements ColorimeterProtocol {
  /// Creates the protocol. Use [instance].
  const Ls170Protocol();

  /// Shared instance. The protocol has no per-connection state; the decoder does.
  static const Ls170Protocol instance = Ls170Protocol();

  @override
  int get requestedMtu => Ls170Gatt.requestedMtu;

  @override
  String get cccd => Ls170Gatt.cccd;

  @override
  List<GattCharacteristicPair> get gattCandidates => Ls170Gatt.candidates;

  @override
  Uint8List commandFor(ColorimeterOperation operation) => switch (operation) {
    ColorimeterOperation.measure => Ls170Commands.measure,
    ColorimeterOperation.calibrate => Ls170Commands.calibrate,
    ColorimeterOperation.battery => Ls170Commands.battery,
    ColorimeterOperation.deviceInfo => Ls170Commands.deviceInfo,
    _ => throw UnsupportedError('${operation.name} is not an LS170/LS171 command'),
  };

  @override
  ProtocolDecoder createDecoder() => _Ls170Decoder();
}

final class _Ls170Decoder implements ProtocolDecoder {
  final Ls170FrameAssembler _assembler = Ls170FrameAssembler();

  @override
  void reset() => _assembler.reset();

  @override
  List<ProtocolFrame> add(List<int> chunk) => [
    for (final frame in _assembler.add(chunk)) _Ls170ProtocolFrame(frame),
  ];
}

final class _Ls170ProtocolFrame implements ProtocolFrame {
  _Ls170ProtocolFrame(this._frame);

  final Ls170Frame _frame;

  @override
  Uint8List get bytes => _frame.bytes;

  @override
  String toHex() => _frame.toHex();

  @override
  bool get isColorResult => _frame.type == Ls170FrameType.colorResult;

  @override
  ColorMeasurement? parseColor({
    MeasurementSource source = MeasurementSource.app,
    DateTime? timestamp,
  }) => Ls170Parser.parseColorResult(_frame, source: source, timestamp: timestamp);

  @override
  BatteryStatus? parseBattery({DateTime? timestamp}) =>
      Ls170Parser.parseBattery(_frame, timestamp: timestamp);

  @override
  CalibrationResult? parseCalibration({DateTime? timestamp}) =>
      Ls170Parser.parseCalibration(_frame, timestamp: timestamp);

  @override
  DeviceInfo? parseDeviceInfo({
    required String deviceId,
    String? deviceName,
    DateTime? timestamp,
  }) => Ls170Parser.parseDeviceInfo(
    _frame,
    deviceId: deviceId,
    deviceName: deviceName,
    timestamp: timestamp,
  );
}
