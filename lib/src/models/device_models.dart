import 'package:flutter/foundation.dart';

import '../signal/rssi.dart';

/// A colorimeter model, identified by the prefix of its BLE advertised name.
///
/// [ls170] and [ls171] are built in. A future instrument is another instance,
/// for example `const ColorimeterModel('XR200')`, and is attached to a
/// `ColorimeterDeviceProfile`.
@immutable
final class ColorimeterModel {
  /// Creates a model. [namePrefix] is matched at the start of the advertised
  /// name, case-insensitively. It must not be empty.
  const ColorimeterModel(this.namePrefix) : assert(namePrefix.length > 0, 'namePrefix is empty');

  /// Linshang LS170.
  static const ColorimeterModel ls170 = ColorimeterModel('LS170');

  /// Linshang LS171.
  static const ColorimeterModel ls171 = ColorimeterModel('LS171');

  /// Models shipped with this package.
  static const List<ColorimeterModel> builtIn = [ls170, ls171];

  /// Prefix of the BLE advertised name (followed by the serial number).
  final String namePrefix;

  /// Whether [advertisedName] starts with [namePrefix].
  bool matches(String? advertisedName) {
    if (advertisedName == null) return false;
    final trimmed = advertisedName.trim();
    if (trimmed.isEmpty) return false;
    return trimmed.toUpperCase().startsWith(namePrefix.toUpperCase());
  }

  /// Detects the model from an advertised name such as `LS170A1B2C3`.
  ///
  /// [catalog] defaults to [builtIn]. The longest matching prefix wins.
  static ColorimeterModel? fromAdvertisedName(String? name, {Iterable<ColorimeterModel>? catalog}) {
    ColorimeterModel? best;
    for (final model in catalog ?? builtIn) {
      if (!model.matches(name)) continue;
      if (best == null || model.namePrefix.length > best.namePrefix.length) best = model;
    }
    return best;
  }

  /// Parses [namePrefix] (case-insensitive), e.g. from imported data.
  ///
  /// [catalog] defaults to [builtIn].
  static ColorimeterModel? fromLabel(String label, {Iterable<ColorimeterModel>? catalog}) {
    final upper = label.trim().toUpperCase();
    for (final model in catalog ?? builtIn) {
      if (model.namePrefix.toUpperCase() == upper) return model;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ColorimeterModel && other.namePrefix.toUpperCase() == namePrefix.toUpperCase();

  @override
  int get hashCode => namePrefix.toUpperCase().hashCode;

  @override
  String toString() => 'ColorimeterModel($namePrefix)';
}

/// A colorimeter seen during a scan, de-duplicated by [id].
@immutable
final class DiscoveredDevice {
  /// Creates a discovered device.
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.firstSeen,
    required this.lastSeen,
    this.rssi,
    this.smoothedRssi,
    this.signalQuality = SignalQuality.unknown,
    this.advertisementCount = 1,
    this.knownModel,
  });

  /// Bluetooth MAC address, used as the device identifier on Android.
  final String id;

  /// Advertised name, e.g. `LS170` followed by the serial number.
  final String name;

  /// Last valid raw RSSI in dBm, or `null` if none was valid.
  final int? rssi;

  /// RSSI after exponential smoothing, or `null` if no valid sample yet.
  final double? smoothedRssi;

  /// Quality bucket of [smoothedRssi] for the configured thresholds.
  final SignalQuality signalQuality;

  /// First advertisement time in this scan.
  final DateTime firstSeen;

  /// Most recent advertisement time.
  final DateTime lastSeen;

  /// Number of advertisements received from this device in this scan.
  final int advertisementCount;

  /// Model chosen by the client's device profile, when the scan already
  /// matched one. Overrides [ColorimeterModel.fromAdvertisedName].
  final ColorimeterModel? knownModel;

  /// Model derived from [name], or [knownModel] when a profile set it.
  ColorimeterModel? get model => knownModel ?? ColorimeterModel.fromAdvertisedName(name);

  /// Same device, with [model] recorded from a device profile.
  DiscoveredDevice identified(ColorimeterModel? model) => DiscoveredDevice(
    id: id,
    name: name,
    firstSeen: firstSeen,
    lastSeen: lastSeen,
    rssi: rssi,
    smoothedRssi: smoothedRssi,
    signalQuality: signalQuality,
    advertisementCount: advertisementCount,
    knownModel: model ?? knownModel,
  );

  /// Serial number: the part of [name] after the model prefix, if any.
  String? get serialNumber {
    final m = model;
    if (m == null) return null;
    final sn = name.trim().substring(m.namePrefix.length).trim();
    return sn.isEmpty ? null : sn;
  }

  @override
  String toString() => 'DiscoveredDevice($name, $id, rssi: $rssi)';
}

/// Battery response (`AB 20 0B ...`).
@immutable
final class BatteryStatus {
  /// Creates a battery status.
  BatteryStatus({required this.rawValue, required this.timestamp, Uint8List? rawFrame})
    : rawFrame = Uint8List.fromList(rawFrame ?? const []);

  /// The int16 value at bytes 6–7 of the response.
  ///
  /// The scale is **not verified on hardware**; see [percent].
  final int rawValue;

  /// When the response was received.
  final DateTime timestamp;

  /// The complete response frame.
  final Uint8List rawFrame;

  /// [rawValue] interpreted as a percentage when it lies in 0–100,
  /// otherwise `null`.
  int? get percent => rawValue >= 0 && rawValue <= 100 ? rawValue : null;

  @override
  String toString() => 'BatteryStatus(raw: $rawValue)';
}

/// Outcome of a white-tile calibration.
enum CalibrationStatus {
  /// The device acknowledged calibration (`AB 20 2E ...`).
  success,

  /// The device reported a failure. Reserved: the failure frame has not been
  /// observed on hardware yet.
  failed,
}

/// Calibration response (`AB 20 2E ...`).
@immutable
final class CalibrationResult {
  /// Creates a calibration result.
  CalibrationResult({required this.status, required this.timestamp, Uint8List? rawFrame})
    : rawFrame = Uint8List.fromList(rawFrame ?? const []);

  /// Success or failure.
  final CalibrationStatus status;

  /// When the response was received.
  final DateTime timestamp;

  /// The complete response frame.
  final Uint8List rawFrame;

  /// Whether calibration succeeded.
  bool get isSuccess => status == CalibrationStatus.success;

  @override
  String toString() => 'CalibrationResult(${status.name})';
}

/// Device information (`AB 40 ...` response plus advertisement data).
///
/// The AB40 field layout is **not verified**. Fields that cannot be decoded
/// yet are `null`; [rawFrame] and [printableStrings] are provided so that the
/// layout can be confirmed on hardware.
@immutable
final class DeviceInfo {
  /// Creates device information.
  DeviceInfo({
    required this.deviceId,
    required this.timestamp,
    this.name,
    this.model,
    this.serialNumber,
    this.firmwareVersion,
    this.manufactureDate,
    this.calibrationDate,
    this.deviceStatus,
    Uint8List? rawFrame,
    List<String> printableStrings = const [],
  }) : rawFrame = Uint8List.fromList(rawFrame ?? const []),
       printableStrings = List.unmodifiable(printableStrings);

  /// Bluetooth address of the device.
  final String deviceId;

  /// Advertised name.
  final String? name;

  /// Model, from the advertised name.
  final ColorimeterModel? model;

  /// Serial number, from the advertised name.
  final String? serialNumber;

  /// Firmware version (not decoded yet).
  final String? firmwareVersion;

  /// Manufacture date (not decoded yet).
  final String? manufactureDate;

  /// Last calibration date (not decoded yet).
  final String? calibrationDate;

  /// Device status (not decoded yet).
  final String? deviceStatus;

  /// When the response was received.
  final DateTime timestamp;

  /// The complete AB40 frame.
  final Uint8List rawFrame;

  /// Runs of printable ASCII (length ≥ 3) found in the frame payload.
  final List<String> printableStrings;

  @override
  String toString() => 'DeviceInfo($name, model: ${model?.namePrefix}, sn: $serialNumber)';
}
