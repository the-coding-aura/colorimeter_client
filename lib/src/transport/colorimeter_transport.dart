import 'dart:typed_data';

import '../protocol/ls170_protocol.dart';
import 'transport_types.dart';

/// Low-level BLE operations the client needs.
///
/// The transport knows nothing about LS170 frames: it scans, opens a GATT
/// connection, enables notifications on one of the given characteristic
/// pairs, writes bytes and forwards notification chunks. Everything above
/// that (framing, retries, timeouts, reconnection) lives in Dart so it can be
/// unit-tested with a fake transport.
///
/// Implementations throw `ColorimeterException` subtypes.
abstract interface class ColorimeterTransport {
  /// Advertisements from the active scan. Scanner failures are delivered as
  /// `ScanFailedException` errors on this stream.
  Stream<BleAdvertisement> get advertisements;

  /// Connection changes. `connected: false` is emitted when an established
  /// link drops or is closed.
  Stream<TransportConnectionEvent> get connectionEvents;

  /// Notification chunks from connected devices.
  Stream<TransportNotification> get notifications;

  /// Adapter state changes (for example the user switched Bluetooth off).
  Stream<BluetoothAdapterState> get adapterStateChanges;

  /// Current adapter state.
  Future<BluetoothAdapterState> getAdapterState();

  /// Checks runtime permissions without prompting.
  Future<BluetoothPermissionStatus> checkPermissions();

  /// Prompts the user for missing permissions.
  Future<BluetoothPermissionStatus> requestPermissions();

  /// Starts a low-latency scan. When [namePrefixes] is non-empty the platform
  /// may drop advertisements whose name does not start with one of them.
  Future<void> startScan({List<String> namePrefixes = const []});

  /// Stops the scan. Safe to call when not scanning.
  Future<void> stopScan();

  /// Connects (LE transport, no auto-connect), requests [requestedMtu],
  /// discovers services, picks the first of [candidates] present and enables
  /// notifications. Completes when the link is ready for writes.
  Future<GattSession> connect(
    String deviceId, {
    int requestedMtu = Ls170Gatt.requestedMtu,
    List<GattCharacteristicPair> candidates = Ls170Gatt.candidates,
    String cccd = Ls170Gatt.cccd,
  });

  /// Disconnects and releases the GATT client. Also aborts a pending
  /// [connect]. Safe to call when not connected.
  Future<void> disconnect(String deviceId);

  /// Writes [data] to the write characteristic (without response when
  /// supported).
  Future<void> write(String deviceId, Uint8List data);

  /// Releases platform resources.
  Future<void> dispose();
}
