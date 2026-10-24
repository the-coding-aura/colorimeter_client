import 'package:flutter/foundation.dart';

/// Phone Bluetooth adapter state.
enum BluetoothAdapterState {
  /// The phone has no Bluetooth LE support.
  unavailable,

  /// Bluetooth is switched off.
  off,

  /// Bluetooth is switching on.
  turningOn,

  /// Bluetooth is on.
  on,

  /// Bluetooth is switching off.
  turningOff,

  /// The state could not be determined.
  unknown,
}

/// Runtime-permission status for BLE scanning and connecting.
@immutable
final class BluetoothPermissionStatus {
  /// Creates a status.
  const BluetoothPermissionStatus({
    this.missingPermissions = const [],
    this.permanentlyDenied = const [],
    this.locationServicesRequired = false,
    this.locationServicesEnabled = true,
  });

  /// All permissions granted and nothing else blocking scans.
  static const BluetoothPermissionStatus granted = BluetoothPermissionStatus();

  /// Android permissions not granted yet.
  final List<String> missingPermissions;

  /// Permissions the user denied with "don't ask again"; only reported after
  /// a request. The app should direct the user to the system settings.
  final List<String> permanentlyDenied;

  /// On Android 11 and lower, BLE scans return nothing unless location
  /// services are on.
  final bool locationServicesRequired;

  /// Whether location services are on (meaningful only when
  /// [locationServicesRequired]).
  final bool locationServicesEnabled;

  /// Whether every required permission is granted.
  bool get isGranted => missingPermissions.isEmpty;

  /// Whether scanning can work (permissions plus location services).
  bool get canScan => isGranted && (!locationServicesRequired || locationServicesEnabled);

  @override
  String toString() => 'BluetoothPermissionStatus(missing: $missingPermissions)';
}

/// One BLE advertisement as reported by the transport.
@immutable
final class BleAdvertisement {
  /// Creates an advertisement.
  const BleAdvertisement({required this.deviceId, this.name, this.rssi, this.timestamp});

  /// Bluetooth address.
  final String deviceId;

  /// Advertised local name, if present.
  final String? name;

  /// RSSI in dBm, or `null` when missing or invalid.
  final int? rssi;

  /// When the advertisement was received (defaults to the time of handling).
  final DateTime? timestamp;

  @override
  String toString() => 'BleAdvertisement($deviceId, $name, $rssi)';
}

/// A connection state change reported by the transport.
@immutable
final class TransportConnectionEvent {
  /// Creates an event.
  const TransportConnectionEvent({
    required this.deviceId,
    required this.connected,
    this.gattStatus,
  });

  /// Bluetooth address.
  final String deviceId;

  /// `true` when GATT is fully set up, `false` when the link dropped or was
  /// closed.
  final bool connected;

  /// Android GATT status code, if any.
  final int? gattStatus;

  @override
  String toString() => 'TransportConnectionEvent($deviceId, connected: $connected)';
}

/// A notification chunk received on the notify characteristic.
@immutable
final class TransportNotification {
  /// Creates a notification.
  const TransportNotification({required this.deviceId, required this.value});

  /// Bluetooth address.
  final String deviceId;

  /// Raw bytes (one ATT notification; a frame may span several).
  final Uint8List value;
}

/// Details of an established GATT session.
@immutable
final class GattSession {
  /// Creates a session description.
  const GattSession({
    required this.deviceId,
    this.mtu,
    this.notifyCharacteristic,
    this.writeCharacteristic,
    this.writeWithoutResponse = true,
  });

  /// Bluetooth address.
  final String deviceId;

  /// Negotiated ATT MTU, if known.
  final int? mtu;

  /// UUID of the characteristic used for notifications.
  final String? notifyCharacteristic;

  /// UUID of the characteristic used for writes.
  final String? writeCharacteristic;

  /// Whether writes use `WRITE_TYPE_NO_RESPONSE`.
  final bool writeWithoutResponse;
}
