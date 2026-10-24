import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../connection/cancel_scope.dart';
import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../device/colorimeter_device_profile.dart';
import '../exceptions.dart';
import '../models/color_measurement.dart';
import '../models/device_models.dart';
import '../protocol/ls170_protocol.dart';
import '../transport/colorimeter_transport.dart';
import '../transport/method_channel_transport.dart';
import '../transport/transport_types.dart';
import 'scanner.dart';

/// What to do with the connection when the app goes to the background.
enum BackgroundBehavior {
  /// Keep the link open (the device auto-powers off after 30 min idle).
  keepConnected,

  /// Disconnect when paused and reconnect to the same device on resume.
  disconnectAndRestore,
}

/// Timeouts, retries and policies of a [ColorimeterClient].
@immutable
final class ColorimeterConfig {
  /// Creates a configuration. The defaults match the hardware-tested Kotlin
  /// client.
  const ColorimeterConfig({
    this.connectTimeout = const Duration(seconds: 15),
    this.disconnectTimeout = const Duration(seconds: 5),
    this.postConnectDelay = const Duration(milliseconds: 400),
    this.requestedMtu = Ls170Gatt.requestedMtu,
    this.measureStartDelay = const Duration(milliseconds: 200),
    this.measureTimeout = const Duration(seconds: 6),
    this.measureRetries = 2,
    this.measureRetryDelay = const Duration(milliseconds: 300),
    this.commandTimeout = const Duration(seconds: 5),
    this.commandRetries = 1,
    this.calibrationTimeout = const Duration(seconds: 10),
    this.reconnectPolicy = ReconnectPolicy.disabled,
    this.backgroundBehavior = BackgroundBehavior.keepConnected,
    this.logger,
  });

  /// Time allowed per connection attempt.
  final Duration connectTimeout;

  /// Time allowed for the platform to release a connection.
  final Duration disconnectTimeout;

  /// Pause after enabling notifications before the first command.
  final Duration postConnectDelay;

  /// MTU requested after connecting.
  final int requestedMtu;

  /// Pause before the first Scan command of a [ColorimeterClient.measure].
  final Duration measureStartDelay;

  /// Time to wait for an AB44 result after each Scan command.
  final Duration measureTimeout;

  /// Extra Scan commands sent when no result arrives in time.
  final int measureRetries;

  /// Pause between Scan retries.
  final Duration measureRetryDelay;

  /// Time to wait for battery and device-info responses.
  final Duration commandTimeout;

  /// Extra attempts for battery and device-info queries.
  final int commandRetries;

  /// Time to wait for the calibration response.
  final Duration calibrationTimeout;

  /// Automatic reconnection after unexpected disconnects.
  final ReconnectPolicy reconnectPolicy;

  /// Behavior on app lifecycle changes, see
  /// [ColorimeterClient.handleAppLifecycleState].
  final BackgroundBehavior backgroundBehavior;

  /// Optional diagnostic logger (frames in hex, retries). `null` = silent.
  final void Function(String message)? logger;
}

class _PendingRequest<T> {
  _PendingRequest(this.decode);

  final T? Function(ProtocolFrame frame) decode;
  final Completer<T> completer = Completer<T>();
  final CancelScope scope = CancelScope();

  bool tryComplete(ProtocolFrame frame) {
    if (completer.isCompleted) return false;
    final value = decode(frame);
    if (value == null) return false;
    completer.complete(value);
    return true;
  }
}

/// Client for a BLE colorimeter.
///
/// The built-in profiles are the Linshang LS170 and LS171, which share one
/// protocol. Pass [profiles] to add a future instrument without changing the
/// scan, connect, or command flow.
///
/// ```dart
/// final client = ColorimeterClient();
/// await for (final devices in client.scan()) { ... }
/// await client.connect(devices.first.id);
/// final reading = await client.measure();
/// print(reading.lab);
/// await client.dispose();
/// ```
///
/// One client talks to one device at a time (the LS170 also accepts only one
/// central). Call [dispose] when done; it disconnects and closes all streams.
class ColorimeterClient {
  /// Creates a client. [transport] defaults to the Android implementation;
  /// pass `FakeColorimeterTransport` (from `testing.dart`) in tests.
  ///
  /// [profiles] defaults to [ColorimeterDeviceProfile.builtIn] (LS170 and LS171).
  ColorimeterClient({
    ColorimeterTransport? transport,
    this.config = const ColorimeterConfig(),
    List<ColorimeterDeviceProfile>? profiles,
  }) : _transport = transport ?? MethodChannelColorimeterTransport(),
       profiles = List.unmodifiable(profiles ?? ColorimeterDeviceProfile.builtIn) {
    if (this.profiles.isEmpty) {
      throw ArgumentError.value(profiles, 'profiles', 'at least one device profile is required');
    }
    _connection = ColorimeterConnectionManager(
      transport: _transport,
      connectTimeout: config.connectTimeout,
      disconnectTimeout: config.disconnectTimeout,
      postConnectDelay: config.postConnectDelay,
      requestedMtu: config.requestedMtu,
      reconnectPolicy: config.reconnectPolicy,
      onStateChanged: _onConnectionState,
    );
    _notificationSubscription = _transport.notifications.listen(_onNotification);
  }

  /// Configuration.
  final ColorimeterConfig config;

  /// Device families this client scans for and can talk to.
  ///
  /// The default is LS170 and LS171. Add a future instrument with another
  /// [ColorimeterDeviceProfile].
  final List<ColorimeterDeviceProfile> profiles;

  final ColorimeterTransport _transport;
  late final ColorimeterConnectionManager _connection;
  late final StreamSubscription<TransportNotification> _notificationSubscription;
  final SerialQueue _commands = SerialQueue();
  final StreamController<ColorMeasurement> _measurements =
      StreamController<ColorMeasurement>.broadcast();
  final StreamController<ProtocolFrame> _frames = StreamController<ProtocolFrame>.broadcast();
  final Map<String, DiscoveredDevice> _seen = {};
  ColorimeterDeviceProfile? _profile;
  String? _profileDeviceId;
  ProtocolDecoder? _decoder;

  CancelScope _session = CancelScope();
  _PendingRequest<Object>? _pending;
  ScanSession? _scan;
  String? _restoreDeviceId;
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Streams and state

  /// Connection state changes (broadcast).
  Stream<ColorimeterConnectionState> get connectionStates => _connection.states;

  /// Current connection state.
  ColorimeterConnectionState get connectionState => _connection.state;

  /// Whether a device is connected and ready.
  bool get isConnected => _connection.isConnected;

  /// Profile used for the current or most recent connection.
  ColorimeterDeviceProfile? get activeProfile => _profile;

  /// The connected device, if it was seen in a scan by this client.
  DiscoveredDevice? get connectedDevice {
    final id = _connection.deviceId;
    return id == null || !isConnected ? null : _seen[id];
  }

  /// Every color result: from [measure] (source [MeasurementSource.app]) and
  /// from the device button (source [MeasurementSource.deviceButton]).
  ///
  /// Device-button results are only delivered while this stream has at
  /// least one listener; cancel the subscription to stop accepting them.
  Stream<ColorMeasurement> get measurements => _measurements.stream;

  /// Every complete frame received, for diagnostics (e.g. decoding the
  /// unverified AB40 layout on hardware).
  Stream<ProtocolFrame> get rawFrames => _frames.stream;

  /// Adapter state changes.
  Stream<BluetoothAdapterState> get adapterStates => _transport.adapterStateChanges;

  /// The connection manager (attempt counters, reconnect policy).
  ColorimeterConnectionManager get connectionManager => _connection;

  // ---------------------------------------------------------------------------
  // Adapter and permissions

  /// Current adapter state.
  Future<BluetoothAdapterState> adapterState() => _transport.getAdapterState();

  /// Checks BLE runtime permissions without prompting.
  Future<BluetoothPermissionStatus> checkPermissions() => _transport.checkPermissions();

  /// Prompts for missing BLE runtime permissions.
  Future<BluetoothPermissionStatus> requestPermissions() => _transport.requestPermissions();

  // ---------------------------------------------------------------------------
  // Scanning

  /// Scans for devices whose names match [profiles].
  ///
  /// When [ScanOptions.namePrefixes] is null, the prefixes come from
  /// [profiles]. Emits the sorted, de-duplicated device list whenever a
  /// device appears or its signal changes noticeably, and completes after
  /// [ScanOptions.timeout]. Cancelling the subscription stops the scan.
  /// Starting a new scan (or connecting) ends the previous one.
  ///
  /// Emits [BluetoothUnavailableException], [BluetoothPermissionException] or
  /// [ScanFailedException] as stream errors, after which the stream closes.
  Stream<List<DiscoveredDevice>> scan({ScanOptions options = const ScanOptions()}) {
    _checkNotDisposed();
    final previous = _scan;
    if (previous != null) unawaited(previous.finish());
    final session = ScanSession(
      _transport,
      ScanOptions(
        timeout: options.timeout,
        namePrefixes:
            options.namePrefixes ?? [for (final profile in profiles) ...profile.namePrefixes],
        thresholds: options.thresholds,
        smoothingFactor: options.smoothingFactor,
        minRssi: options.minRssi,
      ),
      onFinished: (s) {
        if (identical(_scan, s)) _scan = null;
      },
    );
    _scan = session;
    return session.stream.map((devices) {
      final identified = [for (final device in devices) _identify(device)];
      for (final device in identified) {
        _seen[device.id] = device;
      }
      return identified;
    });
  }

  DiscoveredDevice _identify(DiscoveredDevice device) {
    final profile = _profileForName(device.name);
    final model = profile?.modelFor(device.name);
    return model == null ? device : device.identified(model);
  }

  /// Whether a scan is running.
  bool get isScanning => _scan != null;

  /// Stops the running scan, if any.
  Future<void> stopScan() async => _scan?.finish();

  // ---------------------------------------------------------------------------
  // Connection

  /// Connects to [deviceId] (a [DiscoveredDevice.id]). Stops any scan.
  ///
  /// The profile is [profile], or the profile whose name prefix matches the
  /// device seen in the last scan. With a single configured profile that
  /// profile is used even when the device was not scanned. GATT layout,
  /// commands and decoding then come from that profile.
  ///
  /// See [ColorimeterConnectionManager.connect] for errors.
  Future<void> connect(
    String deviceId, {
    Duration? timeout,
    ColorimeterDeviceProfile? profile,
  }) async {
    _checkNotDisposed();
    await stopScan();
    _restoreDeviceId = null;
    final selected = _selectProfile(deviceId, profile);
    _profile = selected;
    _profileDeviceId = deviceId;
    _decoder = selected.protocol.createDecoder();
    await _connection.connect(
      deviceId,
      timeout: timeout,
      mtu: selected.protocol.requestedMtu,
      gattCandidates: selected.protocol.gattCandidates,
      cccd: selected.protocol.cccd,
    );
  }

  ColorimeterDeviceProfile _selectProfile(String deviceId, ColorimeterDeviceProfile? explicit) {
    if (explicit != null) return explicit;
    final current = _profile;
    if (current != null && _profileDeviceId == deviceId) return current;
    final matched = _profileForName(_seen[deviceId]?.name);
    if (matched != null) return matched;
    if (profiles.length == 1) return profiles.single;
    throw ColorimeterConnectionException(
      'No configured device profile matches ${_seen[deviceId]?.name ?? deviceId}',
      deviceId: deviceId,
    );
  }

  ColorimeterDeviceProfile? _profileForName(String? name) {
    ColorimeterDeviceProfile? best;
    var bestLength = -1;
    for (final profile in profiles) {
      final model = profile.modelFor(name);
      if (model == null || model.namePrefix.length <= bestLength) continue;
      best = profile;
      bestLength = model.namePrefix.length;
    }
    return best;
  }

  /// Disconnects; cancels a connect, reconnect or command in progress.
  Future<void> disconnect() async {
    _restoreDeviceId = null;
    await _connection.disconnect();
  }

  void _onConnectionState(ColorimeterConnectionState state) {
    if (state.isConnected) {
      _decoder?.reset();
      _session = CancelScope();
      return;
    }
    final error = state.error is DeviceDisconnectedException
        ? state.error!
        : DeviceDisconnectedException('Device disconnected', deviceId: state.deviceId);
    _session.cancel(error);
    _decoder?.reset();
  }

  // ---------------------------------------------------------------------------
  // Commands

  /// Triggers a measurement and returns it (also emitted on [measurements]).
  ///
  /// Sends the Scan command, waits [ColorimeterConfig.measureTimeout] for the
  /// result and retries up to [ColorimeterConfig.measureRetries] times.
  /// Throws [NotConnectedException], [ColorimeterTimeoutException],
  /// [DeviceDisconnectedException], [OperationCancelledException] or
  /// [WriteFailedException].
  Future<ColorMeasurement> measure() async {
    final measurement = await _command<ColorMeasurement>(
      ColorimeterOperation.measure,
      (frame) => frame.parseColor(),
      timeout: config.measureTimeout,
      retries: config.measureRetries,
      initialDelay: config.measureStartDelay,
      retryDelay: config.measureRetryDelay,
    );
    if (!_measurements.isClosed) _measurements.add(measurement);
    return measurement;
  }

  /// Calibrates against the white tile. Close the bottom cap first.
  Future<CalibrationResult> calibrate() => _command<CalibrationResult>(
    ColorimeterOperation.calibrate,
    (frame) => frame.parseCalibration(),
    timeout: config.calibrationTimeout,
  );

  /// Reads the battery level (see [BatteryStatus] for the unverified scale).
  Future<BatteryStatus> readBattery() => _command<BatteryStatus>(
    ColorimeterOperation.battery,
    (frame) => frame.parseBattery(),
    timeout: config.commandTimeout,
    retries: config.commandRetries,
  );

  /// Reads device information.
  Future<DeviceInfo> readDeviceInfo() {
    final id = _connection.deviceId;
    return _command<DeviceInfo>(
      ColorimeterOperation.deviceInfo,
      (frame) => frame.parseDeviceInfo(
        deviceId: id ?? '',
        deviceName: id == null ? null : _seen[id]?.name,
      ),
      timeout: config.commandTimeout,
      retries: config.commandRetries,
    );
  }

  /// Cancels the command in progress (it fails with
  /// [OperationCancelledException]). Queued commands still run.
  void cancelPendingOperation() {
    final pending = _pending;
    pending?.scope.cancel(
      const OperationCancelledException(
        'Operation cancelled',
        operation: ColorimeterOperation.measure,
      ),
    );
  }

  Future<T> _command<T extends Object>(
    ColorimeterOperation operation,
    T? Function(ProtocolFrame frame) decode, {
    required Duration timeout,
    int retries = 0,
    Duration initialDelay = Duration.zero,
    Duration retryDelay = Duration.zero,
  }) {
    final profile = _profile;
    if (!isConnected || profile == null) return Future<T>.error(const NotConnectedException());
    final Uint8List command;
    try {
      command = profile.protocol.commandFor(operation);
    } on UnsupportedError catch (error) {
      return Future<T>.error(error);
    }
    return _request<T>(
      operation,
      command,
      decode,
      timeout: timeout,
      retries: retries,
      initialDelay: initialDelay,
      retryDelay: retryDelay,
    );
  }

  Future<T> _request<T extends Object>(
    ColorimeterOperation operation,
    Uint8List command,
    T? Function(ProtocolFrame frame) decode, {
    required Duration timeout,
    int retries = 0,
    Duration initialDelay = Duration.zero,
    Duration retryDelay = Duration.zero,
  }) {
    _checkNotDisposed();
    if (!isConnected) return Future<T>.error(const NotConnectedException());
    return _commands.run(() async {
      final deviceId = _connection.deviceId;
      if (!isConnected || deviceId == null) throw const NotConnectedException();
      final session = _session;
      final request = _PendingRequest<T>(decode);
      Future<R> guard<R>(Future<R> f) => request.scope.guard(session.guard(f));
      _pending = request;
      try {
        for (var attempt = 0; ; attempt++) {
          try {
            await guard(_delay(attempt == 0 ? initialDelay : retryDelay));
            _decoder?.reset();
            await guard(_transport.write(deviceId, command));
            _log('-> ${operation.name} (attempt ${attempt + 1})');
            return await guard(request.completer.future.timeout(timeout));
          } on TimeoutException {
            if (attempt >= retries) {
              throw ColorimeterTimeoutException(
                'No ${operation.name} response after ${attempt + 1} attempt(s)',
                operation: operation,
                timeout: timeout,
              );
            }
            _log('No ${operation.name} response; retrying');
          } on Object catch (e) {
            _rethrowAs(e, operation);
          }
        }
      } finally {
        if (identical(_pending, request)) _pending = null;
      }
    });
  }

  static Future<void> _delay(Duration d) =>
      d <= Duration.zero ? Future<void>.value() : Future<void>.delayed(d);

  Never _rethrowAs(Object error, ColorimeterOperation operation) {
    if (error is OperationCancelledException) {
      throw OperationCancelledException(error.message, operation: operation);
    }
    if (error is ColorimeterException) throw error;
    throw WriteFailedException('${operation.name} failed', cause: error);
  }

  // ---------------------------------------------------------------------------
  // Notifications

  void _onNotification(TransportNotification notification) {
    final decoder = _decoder;
    if (decoder == null || notification.deviceId != _connection.deviceId || !isConnected) return;
    for (final frame in decoder.add(notification.value)) {
      _onFrame(frame);
    }
  }

  void _onFrame(ProtocolFrame frame) {
    _log('<- ${frame.toHex()}');
    if (_frames.hasListener) _frames.add(frame);
    final pending = _pending;
    if (pending != null && pending.tryComplete(frame)) return;
    if (!frame.isColorResult) return;
    if (!_measurements.hasListener) {
      _log('color frame ignored: no measurement listener');
      return;
    }
    final measurement = frame.parseColor(source: MeasurementSource.deviceButton);
    if (measurement != null) _measurements.add(measurement);
  }

  void _log(String message) => config.logger?.call(message);

  // ---------------------------------------------------------------------------
  // Lifecycle

  /// Applies [ColorimeterConfig.backgroundBehavior] to an app lifecycle
  /// change. Wire it to an `AppLifecycleListener` or
  /// `WidgetsBindingObserver.didChangeAppLifecycleState`.
  ///
  /// Scans are always stopped when the app leaves the foreground.
  Future<void> handleAppLifecycleState(AppLifecycleState state) async {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        await stopScan();
        if (config.backgroundBehavior == BackgroundBehavior.disconnectAndRestore &&
            _connection.state.status != ColorimeterConnectionStatus.disconnected) {
          final id = _connection.deviceId;
          await _connection.disconnect();
          _restoreDeviceId = id;
        }
      case AppLifecycleState.resumed:
        final id = _restoreDeviceId;
        _restoreDeviceId = null;
        if (id != null) {
          try {
            await connect(id);
          } on ColorimeterException {
            // Reported on connectionStates.
          }
        }
      case AppLifecycleState.detached:
        await disconnect();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('ColorimeterClient was disposed');
  }

  /// Stops scanning, disconnects, cancels subscriptions and closes all
  /// streams. The transport is disposed too.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _scan?.finish();
    _session.cancel(const DeviceDisconnectedException('Client disposed'));
    await _connection.dispose();
    unawaited(_notificationSubscription.cancel()); // Broadcast: takes effect immediately.
    await _measurements.close();
    await _frames.close();
    await _transport.dispose();
  }
}
