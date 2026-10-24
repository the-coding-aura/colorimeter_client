import 'dart:async';
import 'dart:typed_data';

import '../exceptions.dart';
import '../protocol/ls170_protocol.dart';
import '../transport/colorimeter_transport.dart';
import '../transport/transport_types.dart';

/// How [FakeColorimeterTransport.connect] behaves.
enum FakeConnectBehavior {
  /// Completes successfully after [FakeColorimeterTransport.connectDelay].
  succeed,

  /// Throws [FakeColorimeterTransport.connectError].
  fail,

  /// Never completes (until [FakeColorimeterTransport.disconnect]).
  hang,
}

/// Handler invoked for every write to the fake device.
typedef FakeWriteHandler = FutureOr<void> Function(String deviceId, Uint8List data);

/// Scriptable in-memory [ColorimeterTransport] for unit tests and demos.
///
/// All events are delivered asynchronously, like the platform transport.
final class FakeColorimeterTransport implements ColorimeterTransport {
  /// Creates a fake with Bluetooth on and permissions granted.
  FakeColorimeterTransport();

  final _advertisements = StreamController<BleAdvertisement>.broadcast();
  final _connections = StreamController<TransportConnectionEvent>.broadcast();
  final _notifications = StreamController<TransportNotification>.broadcast();
  final _adapter = StreamController<BluetoothAdapterState>.broadcast();
  final Map<String, Completer<GattSession>> _hanging = {};

  /// Returned by [getAdapterState].
  BluetoothAdapterState adapterState = BluetoothAdapterState.on;

  /// Returned by [checkPermissions].
  BluetoothPermissionStatus permissionStatus = BluetoothPermissionStatus.granted;

  /// Becomes [permissionStatus] when [requestPermissions] is called; `null`
  /// leaves it unchanged.
  BluetoothPermissionStatus? permissionStatusAfterRequest;

  /// Thrown by [startScan] when set.
  ColorimeterException? startScanError;

  /// Advertisements emitted shortly after [startScan].
  List<BleAdvertisement> advertisementsOnScan = [];

  /// Default behavior of [connect].
  FakeConnectBehavior connectBehavior = FakeConnectBehavior.succeed;

  /// Per-attempt behaviors consumed before falling back to
  /// [connectBehavior].
  final List<FakeConnectBehavior> connectBehaviorQueue = [];

  /// Thrown for [FakeConnectBehavior.fail].
  ColorimeterException connectError = const ColorimeterConnectionException(
    'GATT error 133',
    gattStatus: 133,
  );

  /// Simulated connection time.
  Duration connectDelay = Duration.zero;

  /// MTU reported by successful connections.
  int negotiatedMtu = 247;

  /// MTU requested by the last [connect] call.
  int? lastRequestedMtu;

  /// Characteristic candidates from the last [connect] call.
  List<GattCharacteristicPair>? lastCandidates;

  /// CCCD UUID from the last [connect] call.
  String? lastCccd;

  /// Thrown by [write] when set.
  ColorimeterException? writeError;

  /// Called for each successful write; use it to send responses.
  FakeWriteHandler? onWrite;

  /// Device ids passed to [connect], in order.
  final List<String> connectCalls = [];

  /// Device ids passed to [disconnect], in order.
  final List<String> disconnectCalls = [];

  /// Every write, in order.
  final List<(String, Uint8List)> writes = [];

  /// Number of [startScan] calls.
  int startScanCount = 0;

  /// Number of [stopScan] calls.
  int stopScanCount = 0;

  /// Whether a scan is running.
  bool isScanning = false;

  /// Whether [dispose] was called.
  bool isDisposed = false;

  final Set<String> _connected = {};

  /// Devices currently connected.
  Set<String> get connectedDevices => Set.unmodifiable(_connected);

  /// Whether the advertisement stream has listeners (for leak tests).
  bool get hasAdvertisementListeners => _advertisements.hasListener;

  /// Whether the notification stream has listeners (for leak tests).
  bool get hasNotificationListeners => _notifications.hasListener;

  // --- Scripting -------------------------------------------------------------

  /// Emits an advertisement (only delivered while scanning).
  void emitAdvertisement(BleAdvertisement advertisement) {
    if (isScanning) scheduleMicrotask(() => _add(_advertisements, advertisement));
  }

  /// Emits a scanner failure.
  void emitScanError(ScanFailedException error) {
    scheduleMicrotask(() {
      if (!_advertisements.isClosed) _advertisements.addError(error);
    });
  }

  /// Delivers one notification chunk.
  void emitNotification(String deviceId, List<int> value) {
    scheduleMicrotask(
      () => _add(
        _notifications,
        TransportNotification(deviceId: deviceId, value: Uint8List.fromList(value)),
      ),
    );
  }

  /// Delivers [chunks] in order.
  void emitNotifications(String deviceId, Iterable<List<int>> chunks) {
    for (final c in chunks) {
      emitNotification(deviceId, c);
    }
  }

  /// Simulates the link dropping (out of range, device powered off).
  void simulateDisconnect(String deviceId, {int gattStatus = 8}) {
    _connected.remove(deviceId);
    scheduleMicrotask(
      () => _add(
        _connections,
        TransportConnectionEvent(deviceId: deviceId, connected: false, gattStatus: gattStatus),
      ),
    );
  }

  /// Changes the adapter state and emits it.
  void setAdapterState(BluetoothAdapterState state) {
    adapterState = state;
    scheduleMicrotask(() => _add(_adapter, state));
  }

  void _add<T>(StreamController<T> controller, T value) {
    if (!controller.isClosed) controller.add(value);
  }

  // --- ColorimeterTransport ---------------------------------------------------

  @override
  Stream<BleAdvertisement> get advertisements => _advertisements.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connections.stream;

  @override
  Stream<TransportNotification> get notifications => _notifications.stream;

  @override
  Stream<BluetoothAdapterState> get adapterStateChanges => _adapter.stream;

  @override
  Future<BluetoothAdapterState> getAdapterState() async => adapterState;

  @override
  Future<BluetoothPermissionStatus> checkPermissions() async => permissionStatus;

  @override
  Future<BluetoothPermissionStatus> requestPermissions() async {
    permissionStatus = permissionStatusAfterRequest ?? permissionStatus;
    return permissionStatus;
  }

  @override
  Future<void> startScan({List<String> namePrefixes = const []}) async {
    startScanCount++;
    final error = startScanError;
    if (error != null) throw error;
    isScanning = true;
    advertisementsOnScan.forEach(emitAdvertisement);
  }

  @override
  Future<void> stopScan() async {
    stopScanCount++;
    isScanning = false;
  }

  @override
  Future<GattSession> connect(
    String deviceId, {
    int requestedMtu = Ls170Gatt.requestedMtu,
    List<GattCharacteristicPair> candidates = Ls170Gatt.candidates,
    String cccd = Ls170Gatt.cccd,
  }) async {
    connectCalls.add(deviceId);
    lastRequestedMtu = requestedMtu;
    lastCandidates = candidates;
    lastCccd = cccd;
    final behavior = connectBehaviorQueue.isNotEmpty
        ? connectBehaviorQueue.removeAt(0)
        : connectBehavior;
    switch (behavior) {
      case FakeConnectBehavior.fail:
        if (connectDelay > Duration.zero) await Future<void>.delayed(connectDelay);
        throw connectError;
      case FakeConnectBehavior.hang:
        final completer = Completer<GattSession>();
        _hanging[deviceId] = completer;
        return completer.future;
      case FakeConnectBehavior.succeed:
        if (connectDelay > Duration.zero) await Future<void>.delayed(connectDelay);
        _connected.add(deviceId);
        scheduleMicrotask(
          () => _add(_connections, TransportConnectionEvent(deviceId: deviceId, connected: true)),
        );
        return GattSession(
          deviceId: deviceId,
          mtu: negotiatedMtu,
          notifyCharacteristic: candidates.first.notifyCharacteristic,
          writeCharacteristic: candidates.first.writeCharacteristic,
        );
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls.add(deviceId);
    _hanging
        .remove(deviceId)
        ?.completeError(
          const OperationCancelledException('cancelled', operation: ColorimeterOperation.connect),
        );
    if (_connected.remove(deviceId)) {
      scheduleMicrotask(
        () => _add(_connections, TransportConnectionEvent(deviceId: deviceId, connected: false)),
      );
    }
  }

  @override
  Future<void> write(String deviceId, Uint8List data) async {
    final error = writeError;
    if (error != null) throw error;
    if (!_connected.contains(deviceId)) throw const NotConnectedException();
    writes.add((deviceId, Uint8List.fromList(data)));
    await onWrite?.call(deviceId, data);
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
    isScanning = false;
    for (final c in _hanging.values) {
      c.completeError(
        const OperationCancelledException('disposed', operation: ColorimeterOperation.connect),
      );
    }
    _hanging.clear();
    await Future.wait([
      _advertisements.close(),
      _connections.close(),
      _notifications.close(),
      _adapter.close(),
    ]);
  }
}
