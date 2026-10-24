import 'dart:async';

import 'package:flutter/services.dart';

import '../exceptions.dart';
import '../protocol/ls170_protocol.dart';
import '../signal/rssi.dart';
import 'colorimeter_transport.dart';
import 'transport_types.dart';

/// [ColorimeterTransport] backed by this plugin's Android code
/// (`android.bluetooth` GATT APIs via a method channel and an event channel).
final class MethodChannelColorimeterTransport implements ColorimeterTransport {
  /// Creates the transport. The channels can be overridden for tests.
  MethodChannelColorimeterTransport({
    MethodChannel methodChannel = const MethodChannel(methodChannelName),
    EventChannel eventChannel = const EventChannel(eventChannelName),
  }) : _methods = methodChannel,
       _events = eventChannel;

  /// Name of the method channel.
  static const String methodChannelName = 'com.icrpaints.colorimeter_client/methods';

  /// Name of the event channel.
  static const String eventChannelName = 'com.icrpaints.colorimeter_client/events';

  final MethodChannel _methods;
  final EventChannel _events;

  final _advertisements = StreamController<BleAdvertisement>.broadcast();
  final _connections = StreamController<TransportConnectionEvent>.broadcast();
  final _notifications = StreamController<TransportNotification>.broadcast();
  final _adapter = StreamController<BluetoothAdapterState>.broadcast();
  StreamSubscription<Object?>? _eventSubscription;
  bool _disposed = false;

  void _ensureListening() {
    if (_eventSubscription != null || _disposed) return;
    _eventSubscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) {
        _advertisements.addError(_mapError(error));
      },
    );
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final map = event.cast<Object?, Object?>();
    switch (map['event']) {
      case 'advertisement':
        final id = map['id'];
        if (id is! String) return;
        final ts = map['timestamp'];
        _advertisements.add(
          BleAdvertisement(
            deviceId: id,
            name: map['name'] as String?,
            rssi: Rssi.parse(map['rssi']),
            timestamp: ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
          ),
        );
      case 'scanFailed':
        final code = map['code'];
        _advertisements.addError(
          ScanFailedException('BLE scan failed (code $code)', errorCode: code is int ? code : null),
        );
      case 'connection':
        final id = map['id'];
        if (id is! String) return;
        final status = map['status'];
        _connections.add(
          TransportConnectionEvent(
            deviceId: id,
            connected: map['connected'] == true,
            gattStatus: status is int ? status : null,
          ),
        );
      case 'notification':
        final id = map['id'];
        final value = map['value'];
        if (id is! String || value is! Uint8List) return;
        _notifications.add(TransportNotification(deviceId: id, value: value));
      case 'adapterState':
        _adapter.add(_parseAdapterState(map['state']));
    }
  }

  @override
  Stream<BleAdvertisement> get advertisements {
    _ensureListening();
    return _advertisements.stream;
  }

  @override
  Stream<TransportConnectionEvent> get connectionEvents {
    _ensureListening();
    return _connections.stream;
  }

  @override
  Stream<TransportNotification> get notifications {
    _ensureListening();
    return _notifications.stream;
  }

  @override
  Stream<BluetoothAdapterState> get adapterStateChanges {
    _ensureListening();
    return _adapter.stream;
  }

  @override
  Future<BluetoothAdapterState> getAdapterState() async =>
      _parseAdapterState(await _invoke<String>('getAdapterState'));

  @override
  Future<BluetoothPermissionStatus> checkPermissions() async =>
      _parsePermissions(await _invoke<Map<Object?, Object?>>('checkPermissions'));

  @override
  Future<BluetoothPermissionStatus> requestPermissions() async =>
      _parsePermissions(await _invoke<Map<Object?, Object?>>('requestPermissions'));

  @override
  Future<void> startScan({List<String> namePrefixes = const []}) async {
    _ensureListening();
    await _invoke<void>('startScan', {'namePrefixes': namePrefixes});
  }

  @override
  Future<void> stopScan() => _invoke<void>('stopScan');

  @override
  Future<GattSession> connect(
    String deviceId, {
    int requestedMtu = Ls170Gatt.requestedMtu,
    List<GattCharacteristicPair> candidates = Ls170Gatt.candidates,
    String cccd = Ls170Gatt.cccd,
  }) async {
    _ensureListening();
    final result = await _invoke<Map<Object?, Object?>>('connect', {
      'id': deviceId,
      'mtu': requestedMtu,
      'cccd': cccd,
      'candidates': [
        for (final c in candidates)
          {
            'notifyService': c.notifyService,
            'notifyCharacteristic': c.notifyCharacteristic,
            'writeService': c.writeService,
            'writeCharacteristic': c.writeCharacteristic,
          },
      ],
    });
    final mtu = result?['mtu'];
    return GattSession(
      deviceId: deviceId,
      mtu: mtu is int ? mtu : null,
      notifyCharacteristic: result?['notifyCharacteristic'] as String?,
      writeCharacteristic: result?['writeCharacteristic'] as String?,
      writeWithoutResponse: result?['writeWithoutResponse'] != false,
    );
  }

  @override
  Future<void> disconnect(String deviceId) => _invoke<void>('disconnect', {'id': deviceId});

  @override
  Future<void> write(String deviceId, Uint8List data) =>
      _invoke<void>('write', {'id': deviceId, 'value': data});

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _methods.invokeMethod<void>('release');
    } on PlatformException {
      // The engine may already be detaching.
    } on MissingPluginException {
      // Not running on Android.
    }
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await Future.wait([
      _advertisements.close(),
      _connections.close(),
      _notifications.close(),
      _adapter.close(),
    ]);
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw _mapError(e, deviceId: args?['id'] as String?);
    } on MissingPluginException catch (e) {
      throw BluetoothUnavailableException(
        'colorimeter_client is only implemented on Android',
        state: BluetoothAdapterState.unavailable,
        cause: e,
      );
    }
  }

  static ColorimeterException _mapError(Object error, {String? deviceId}) {
    if (error is! PlatformException) {
      return ColorimeterConnectionException('Platform error', deviceId: deviceId, cause: error);
    }
    final message = error.message ?? error.code;
    final details = error.details is Map ? (error.details as Map).cast<Object?, Object?>() : null;
    final status = details?['status'];
    final gattStatus = status is int ? status : null;
    return switch (error.code) {
      'bluetooth_unavailable' => BluetoothUnavailableException(
        message,
        state: BluetoothAdapterState.unavailable,
        cause: error,
      ),
      'bluetooth_off' => BluetoothUnavailableException(
        message,
        state: BluetoothAdapterState.off,
        cause: error,
      ),
      'permission_denied' => BluetoothPermissionException(
        message,
        missingPermissions: [
          for (final p in (details?['missing'] as List<Object?>? ?? const []))
            if (p is String) p,
        ],
        cause: error,
      ),
      'no_activity' => BluetoothPermissionException(message, cause: error),
      'scan_failed' => ScanFailedException(message, errorCode: gattStatus, cause: error),
      'gatt_setup_failed' => GattSetupException(message, cause: error),
      'not_connected' => const NotConnectedException(),
      'write_failed' => WriteFailedException(message, cause: error),
      'cancelled' => const OperationCancelledException(
        'Connection cancelled',
        operation: ColorimeterOperation.connect,
      ),
      _ => ColorimeterConnectionException(
        message,
        deviceId: deviceId,
        gattStatus: gattStatus,
        cause: error,
      ),
    };
  }

  static BluetoothAdapterState _parseAdapterState(Object? raw) => switch (raw) {
    'unavailable' => BluetoothAdapterState.unavailable,
    'off' => BluetoothAdapterState.off,
    'turningOn' => BluetoothAdapterState.turningOn,
    'on' => BluetoothAdapterState.on,
    'turningOff' => BluetoothAdapterState.turningOff,
    _ => BluetoothAdapterState.unknown,
  };

  static BluetoothPermissionStatus _parsePermissions(Map<Object?, Object?>? raw) {
    List<String> strings(Object? v) => [
      if (v is List)
        for (final s in v)
          if (s is String) s,
    ];
    return BluetoothPermissionStatus(
      missingPermissions: strings(raw?['missing']),
      permanentlyDenied: strings(raw?['permanentlyDenied']),
      locationServicesRequired: raw?['locationServicesRequired'] == true,
      locationServicesEnabled: raw?['locationServicesEnabled'] != false,
    );
  }
}
