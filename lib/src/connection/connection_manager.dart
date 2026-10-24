import 'dart:async';

import '../exceptions.dart';
import '../protocol/ls170_protocol.dart';
import '../transport/colorimeter_transport.dart';
import '../transport/transport_types.dart';
import 'cancel_scope.dart';
import 'connection_state.dart';

/// Owns the GATT connection to one colorimeter.
///
/// * [connect] / [disconnect] with timeouts;
/// * a duplicate [connect] to the device being connected returns the same
///   future instead of starting another GATT operation;
/// * [disconnect] cancels an in-flight connect or reconnect, which then
///   fails with [OperationCancelledException];
/// * unexpected disconnects are reported on [states] and, when a
///   [ReconnectPolicy] is enabled, retried a bounded number of times.
final class ColorimeterConnectionManager {
  /// Creates a manager on `transport`.
  ///
  /// `onStateChanged` is called synchronously on every state change, before
  /// the change is delivered on [states]. `clock` is for tests.
  ColorimeterConnectionManager({
    required this._transport,
    this.connectTimeout = const Duration(seconds: 15),
    this.disconnectTimeout = const Duration(seconds: 5),
    this.postConnectDelay = const Duration(milliseconds: 400),
    this.requestedMtu = Ls170Gatt.requestedMtu,
    this.candidates = Ls170Gatt.candidates,
    this.reconnectPolicy = ReconnectPolicy.disabled,
    this._onStateChanged,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _eventSubscription = _transport.connectionEvents.listen(_onTransportEvent);
  }

  /// Time allowed for one connection attempt (GATT connect, MTU, service
  /// discovery and enabling notifications).
  final Duration connectTimeout;

  /// Time allowed for the platform to release the connection.
  final Duration disconnectTimeout;

  /// Pause after notifications are enabled before the link is reported as
  /// connected, giving the UART bridge time to settle.
  final Duration postConnectDelay;

  /// MTU requested after connecting.
  final int requestedMtu;

  /// UART characteristic layouts to look for.
  final List<GattCharacteristicPair> candidates;

  /// Automatic reconnection policy.
  final ReconnectPolicy reconnectPolicy;

  final ColorimeterTransport _transport;
  final void Function(ColorimeterConnectionState state)? _onStateChanged;
  final DateTime Function() _clock;
  final StreamController<ColorimeterConnectionState> _states =
      StreamController<ColorimeterConnectionState>.broadcast();
  late final StreamSubscription<TransportConnectionEvent> _eventSubscription;

  ColorimeterConnectionState _state = ColorimeterConnectionState.initial;
  CancelScope? _operation;
  Future<void>? _pendingConnect;
  String? _pendingConnectId;
  DateTime? _connectedAt;
  int _reconnectBudgetUsed = 0;
  int _totalAttempts = 0;
  bool _disposed = false;
  int? _mtuOverride;
  List<GattCharacteristicPair>? _candidatesOverride;
  String? _cccdOverride;

  /// Current state.
  ColorimeterConnectionState get state => _state;

  /// State changes (broadcast). Does not replay the current state; read
  /// [state] first if needed.
  Stream<ColorimeterConnectionState> get states => _states.stream;

  /// Connected (or connecting) device.
  String? get deviceId => _state.deviceId;

  /// Whether commands can be sent.
  bool get isConnected => _state.isConnected;

  /// Number of connection attempts made since creation (including
  /// reconnects).
  int get totalAttempts => _totalAttempts;

  /// Connects to [deviceId].
  ///
  /// Completes when the device is ready for commands. A previous connection
  /// to another device is closed first. [mtu], [gattCandidates] and [cccd]
  /// select the GATT layout for this device and are reused if the link drops
  /// and [ReconnectPolicy] reconnects. Omit them to use the values from the
  /// constructor.
  ///
  /// Throws [ColorimeterTimeoutException], [ColorimeterConnectionException],
  /// [GattSetupException], [BluetoothUnavailableException],
  /// [BluetoothPermissionException] or [OperationCancelledException].
  Future<void> connect(
    String deviceId, {
    Duration? timeout,
    int? mtu,
    List<GattCharacteristicPair>? gattCandidates,
    String? cccd,
  }) {
    _checkNotDisposed();
    if (_state.isConnected && _state.deviceId == deviceId) return Future<void>.value();
    final pending = _pendingConnect;
    if (pending != null && _pendingConnectId == deviceId) return pending;

    final future = _connectNew(
      deviceId,
      timeout ?? connectTimeout,
      mtu: mtu,
      gattCandidates: gattCandidates,
      cccd: cccd,
    );
    _pendingConnect = future;
    _pendingConnectId = deviceId;
    return future.whenComplete(() {
      if (identical(_pendingConnect, future)) {
        _pendingConnect = null;
        _pendingConnectId = null;
      }
    });
  }

  Future<void> _connectNew(
    String deviceId,
    Duration timeout, {
    int? mtu,
    List<GattCharacteristicPair>? gattCandidates,
    String? cccd,
  }) async {
    _mtuOverride = mtu;
    _candidatesOverride = gattCandidates;
    _cccdOverride = cccd;
    await _abortCurrent();
    final op = CancelScope();
    _operation = op;
    _reconnectBudgetUsed = 0;
    try {
      await _attempt(op, deviceId, timeout, ColorimeterConnectionStatus.connecting, 1);
    } on OperationCancelledException {
      rethrow;
    } on ColorimeterException catch (e) {
      if (!op.isCancelled) {
        _emit(
          ColorimeterConnectionState(
            status: ColorimeterConnectionStatus.disconnected,
            deviceId: deviceId,
            error: e,
          ),
        );
      }
      rethrow;
    } finally {
      if (identical(_operation, op)) _operation = null;
    }
  }

  Future<void> _attempt(
    CancelScope op,
    String deviceId,
    Duration timeout,
    ColorimeterConnectionStatus status,
    int attempt,
  ) async {
    _totalAttempts++;
    _emit(ColorimeterConnectionState(status: status, deviceId: deviceId, attempt: attempt));
    try {
      final connecting = _transport
          .connect(
            deviceId,
            requestedMtu: _mtuOverride ?? requestedMtu,
            candidates: _candidatesOverride ?? candidates,
            cccd: _cccdOverride ?? Ls170Gatt.cccd,
          )
          .timeout(
            timeout,
            onTimeout: () => throw ColorimeterTimeoutException(
              'Connection to $deviceId timed out after ${timeout.inMilliseconds} ms',
              operation: ColorimeterOperation.connect,
              timeout: timeout,
            ),
          );
      final session = await op.guard(connecting);
      await op.delay(postConnectDelay);
      _connectedAt = _clock();
      _emit(
        ColorimeterConnectionState(
          status: ColorimeterConnectionStatus.connected,
          deviceId: deviceId,
          mtu: session.mtu,
        ),
      );
    } on OperationCancelledException {
      rethrow;
    } catch (e) {
      // Release the half-open GATT client so the next attempt starts clean.
      await _safeTransportDisconnect(deviceId);
      if (e is ColorimeterException) rethrow;
      throw ColorimeterConnectionException('Connection failed', deviceId: deviceId, cause: e);
    }
  }

  void _onTransportEvent(TransportConnectionEvent event) {
    if (event.connected || event.deviceId != _state.deviceId) return;
    if (_state.status != ColorimeterConnectionStatus.connected) return;

    final error = DeviceDisconnectedException(
      'Device ${event.deviceId} disconnected unexpectedly',
      deviceId: event.deviceId,
      gattStatus: event.gattStatus,
    );
    final connectedAt = _connectedAt;
    if (connectedAt != null &&
        _clock().difference(connectedAt) >= reconnectPolicy.stableConnectionDuration) {
      _reconnectBudgetUsed = 0;
    }
    _connectedAt = null;
    if (reconnectPolicy.isEnabled && _reconnectBudgetUsed < reconnectPolicy.maxAttempts) {
      unawaited(_reconnect(event.deviceId, error));
    } else {
      _emit(
        ColorimeterConnectionState(
          status: ColorimeterConnectionStatus.disconnected,
          deviceId: event.deviceId,
          error: error,
        ),
      );
    }
  }

  Future<void> _reconnect(String deviceId, ColorimeterException cause) async {
    final op = CancelScope();
    _operation = op;
    var lastError = cause;
    try {
      while (_reconnectBudgetUsed < reconnectPolicy.maxAttempts) {
        final attempt = ++_reconnectBudgetUsed;
        _emit(
          ColorimeterConnectionState(
            status: ColorimeterConnectionStatus.reconnecting,
            deviceId: deviceId,
            attempt: attempt,
            error: lastError,
          ),
        );
        try {
          await op.delay(reconnectPolicy.delayForAttempt(attempt));
          await _attempt(
            op,
            deviceId,
            connectTimeout,
            ColorimeterConnectionStatus.reconnecting,
            attempt,
          );
          return;
        } on OperationCancelledException {
          return;
        } on ColorimeterException catch (e) {
          lastError = e;
        }
      }
      _emit(
        ColorimeterConnectionState(
          status: ColorimeterConnectionStatus.disconnected,
          deviceId: deviceId,
          error: ColorimeterConnectionException(
            'Reconnection failed after ${reconnectPolicy.maxAttempts} attempts',
            deviceId: deviceId,
            cause: lastError,
          ),
        ),
      );
    } finally {
      if (identical(_operation, op)) _operation = null;
    }
  }

  /// Disconnects the current device and cancels any connect or reconnect in
  /// progress. Completes once the state is
  /// [ColorimeterConnectionStatus.disconnected]; platform errors and
  /// timeouts while releasing are not rethrown.
  Future<void> disconnect() async {
    if (_disposed) return;
    final id = _state.deviceId;
    _cancelOperation();
    if (id == null || _state.status == ColorimeterConnectionStatus.disconnected) return;
    _emit(
      ColorimeterConnectionState(status: ColorimeterConnectionStatus.disconnecting, deviceId: id),
    );
    await _safeTransportDisconnect(id);
    _connectedAt = null;
    _emit(
      ColorimeterConnectionState(status: ColorimeterConnectionStatus.disconnected, deviceId: id),
    );
  }

  Future<void> _abortCurrent() async {
    if (_state.status != ColorimeterConnectionStatus.disconnected) {
      await disconnect();
    } else {
      _cancelOperation();
    }
  }

  void _cancelOperation() {
    final op = _operation;
    _operation = null;
    op?.cancel(
      const OperationCancelledException(
        'Connection cancelled',
        operation: ColorimeterOperation.connect,
      ),
    );
  }

  Future<void> _safeTransportDisconnect(String deviceId) async {
    try {
      await _transport.disconnect(deviceId).timeout(disconnectTimeout);
    } on Object {
      // Best effort: the link is treated as closed either way.
    }
  }

  void _emit(ColorimeterConnectionState state) {
    if (_state == state) return;
    _state = state;
    _onStateChanged?.call(state);
    if (!_states.isClosed) _states.add(state);
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('ColorimeterConnectionManager was disposed');
  }

  /// Disconnects and releases the manager. [states] is closed.
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    unawaited(_eventSubscription.cancel()); // Broadcast: takes effect immediately.
    await _states.close();
  }
}
