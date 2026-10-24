import 'dart:async';

import 'package:flutter/foundation.dart';

import '../exceptions.dart';
import '../models/device_models.dart';
import '../signal/rssi.dart';
import '../transport/colorimeter_transport.dart';
import '../transport/transport_types.dart';

/// Options for `ColorimeterClient.scan`.
@immutable
final class ScanOptions {
  /// Creates scan options.
  const ScanOptions({
    this.timeout = const Duration(seconds: 12),
    this.namePrefixes,
    this.thresholds = const RssiThresholds(),
    this.smoothingFactor = 0.3,
    this.minRssi,
  });

  /// How long to scan before the stream completes.
  final Duration timeout;

  /// Accepted advertised-name prefixes (case-insensitive).
  ///
  /// `null` means the prefixes of the client's device profiles (LS170 and
  /// LS171 unless more profiles were configured). An empty list accepts every
  /// named device.
  final List<String>? namePrefixes;

  /// Signal-quality thresholds.
  final RssiThresholds thresholds;

  /// EMA weight of the newest RSSI sample, in `(0, 1]`.
  final double smoothingFactor;

  /// Devices whose smoothed RSSI is below this value are hidden (but still
  /// tracked, so they reappear when they get closer).
  final int? minRssi;

  /// Whether [name] passes the [namePrefixes] filter.
  bool acceptsName(String? name) {
    if (name == null || name.trim().isEmpty) return false;
    final prefixes = namePrefixes;
    if (prefixes == null || prefixes.isEmpty) return prefixes == null ? false : true;
    final upper = name.trim().toUpperCase();
    return prefixes.any((p) => upper.startsWith(p.toUpperCase()));
  }
}

class _Tracked {
  _Tracked(this.device, double alpha) : smoother = RssiSmoother(alpha: alpha);

  DiscoveredDevice device;
  final RssiSmoother smoother;
}

/// One scan session; see `ColorimeterClient.scan`.
final class ScanSession {
  /// Starts a session when the returned stream is listened to.
  ScanSession(this._transport, this.options, {required this.onFinished}) {
    options.thresholds.validate();
    // Fail fast on a bad smoothing factor.
    RssiSmoother(alpha: options.smoothingFactor);
    _controller = StreamController<List<DiscoveredDevice>>(
      onListen: () => unawaited(_start()),
      onCancel: finish,
    );
  }

  final ColorimeterTransport _transport;

  /// Options of this session.
  final ScanOptions options;

  /// Called once when the session ends.
  final void Function(ScanSession session) onFinished;

  late final StreamController<List<DiscoveredDevice>> _controller;
  final Map<String, _Tracked> _devices = {};
  StreamSubscription<BleAdvertisement>? _subscription;
  Timer? _timer;
  bool _finished = false;
  bool _scanStarted = false;

  /// Snapshot stream; completes on timeout or [finish].
  Stream<List<DiscoveredDevice>> get stream => _controller.stream;

  /// Devices discovered so far, sorted by name.
  List<DiscoveredDevice> get devices => _visible();

  Future<void> _start() async {
    try {
      final adapter = await _transport.getAdapterState();
      if (adapter != BluetoothAdapterState.on) {
        throw BluetoothUnavailableException('Bluetooth is ${adapter.name}', state: adapter);
      }
      final permissions = await _transport.checkPermissions();
      if (!permissions.isGranted) {
        throw BluetoothPermissionException(
          'Bluetooth permissions not granted',
          missingPermissions: permissions.missingPermissions,
        );
      }
      if (_finished) return;
      _subscription = _transport.advertisements.listen(_onAdvertisement, onError: _fail);
      _timer = Timer(options.timeout, () => unawaited(finish()));
      _scanStarted = true;
      await _transport.startScan(namePrefixes: options.namePrefixes ?? const <String>[]);
    } on Object catch (e) {
      _fail(e);
    }
  }

  void _onAdvertisement(BleAdvertisement adv) {
    if (_finished || !options.acceptsName(adv.name)) return;
    final now = adv.timestamp ?? DateTime.now();
    final tracked = _devices[adv.deviceId];
    final rssi = Rssi.isValid(adv.rssi) ? adv.rssi : null;
    if (tracked == null) {
      final t = _Tracked(
        DiscoveredDevice(id: adv.deviceId, name: adv.name!.trim(), firstSeen: now, lastSeen: now),
        options.smoothingFactor,
      );
      final smoothed = t.smoother.add(rssi);
      t.device = _update(t.device, rssi, smoothed, now, count: 1);
      _devices[adv.deviceId] = t;
      _publish();
      return;
    }
    final previous = tracked.device;
    final smoothed = tracked.smoother.add(rssi);
    tracked.device = _update(
      previous,
      rssi ?? previous.rssi,
      smoothed,
      now,
      count: previous.advertisementCount + 1,
      name: adv.name!.trim(),
    );
    // Repeated advertisements only produce a new snapshot when something a
    // UI would show has changed.
    final changed =
        previous.name != tracked.device.name ||
        previous.signalQuality != tracked.device.signalQuality ||
        previous.smoothedRssi?.round() != smoothed?.round();
    if (changed) _publish();
  }

  DiscoveredDevice _update(
    DiscoveredDevice d,
    int? rssi,
    double? smoothed,
    DateTime now, {
    required int count,
    String? name,
  }) => DiscoveredDevice(
    id: d.id,
    name: name ?? d.name,
    rssi: rssi,
    smoothedRssi: smoothed,
    signalQuality: options.thresholds.classify(smoothed),
    firstSeen: d.firstSeen,
    lastSeen: now,
    advertisementCount: count,
  );

  List<DiscoveredDevice> _visible() {
    final min = options.minRssi;
    return [
      for (final t in _devices.values)
        if (min == null || (t.device.smoothedRssi ?? -1000) >= min) t.device,
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  void _publish() {
    if (!_controller.isClosed) _controller.add(_visible());
  }

  void _fail(Object error) {
    if (_finished) return;
    if (!_controller.isClosed) {
      _controller.addError(
        error is ColorimeterException
            ? error
            : ScanFailedException('BLE scan failed', cause: error),
      );
    }
    unawaited(finish());
  }

  /// Stops scanning and completes the stream.
  Future<void> finish() async {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    // Cancelling a broadcast subscription takes effect immediately. Its future
    // belongs to the root zone, so awaiting it would hang under fake async.
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (_scanStarted) {
      try {
        await _transport.stopScan();
      } on ColorimeterException {
        // Stopping a scan that already failed is not an error.
      }
    }
    onFinished(this);
    // Not awaited: when called from onCancel, the done future waits for
    // onCancel itself to complete.
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
