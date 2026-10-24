import 'dart:async';

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = ColorimeterConfig(
  postConnectDelay: Duration(milliseconds: 5),
  measureStartDelay: Duration(milliseconds: 1),
  measureTimeout: Duration(milliseconds: 80),
  measureRetryDelay: Duration(milliseconds: 5),
  commandTimeout: Duration(milliseconds: 80),
  calibrationTimeout: Duration(milliseconds: 80),
  disconnectTimeout: Duration(milliseconds: 100),
);

Future<void> _settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeColorimeterTransport transport;
  late SimulatedLs170 device;
  late ColorimeterClient client;

  setUp(() {
    transport = FakeColorimeterTransport();
    device = SimulatedLs170(transport, responseDelay: const Duration(milliseconds: 5));
    client = ColorimeterClient(transport: transport, config: _config);
  });

  tearDown(() => client.dispose());

  Future<void> scanAndConnect() async {
    await client
        .scan(options: const ScanOptions(timeout: Duration(milliseconds: 20)))
        .drain<void>();
    await client.connect(device.deviceId);
  }

  test('measure sends the Scan command and parses the fragmented result', () async {
    await scanAndConnect();
    final stream = <ColorMeasurement>[];
    final sub = client.measurements.listen(stream.add);
    final m = await client.measure();
    expect(m.lab, const Lab(92.59, -0.29, 0.55));
    expect(m.source, MeasurementSource.app);
    expect(transport.writes.single.$2, Ls170Commands.measure);
    await _settle();
    expect(stream.single.source, MeasurementSource.app);
    await sub.cancel();
  });

  test('device-button results are delivered while listening', () async {
    await scanAndConnect();
    final results = <ColorMeasurement>[];
    final sub = client.measurements.listen(results.add);
    device
      ..nextLab = const Lab(30, 40, 50)
      ..pressButton();
    await _settle();
    expect(results.single.lab, const Lab(30, 40, 50));
    expect(results.single.source, MeasurementSource.deviceButton);
    await sub.cancel();

    // Without a listener, unsolicited results are dropped.
    final frames = <ProtocolFrame>[];
    final rawSub = client.rawFrames.listen(frames.add);
    device.pressButton();
    await _settle();
    expect(frames.single.isColorResult, isTrue);
    expect(results, hasLength(1));
    await rawSub.cancel();
  });

  test('measure retries when no result arrives', () async {
    await scanAndConnect();
    device.muteMeasurements = true;
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 120),
        () => device.muteMeasurements = false,
      ),
    );
    final m = await client.measure();
    expect(m.lab.l, 92.59);
    expect(transport.writes.length, greaterThanOrEqualTo(2));
  });

  test('measure times out after the configured retries', () async {
    await scanAndConnect();
    device.muteMeasurements = true;
    await expectLater(
      client.measure(),
      throwsA(
        isA<ColorimeterTimeoutException>().having(
          (e) => e.operation,
          'operation',
          ColorimeterOperation.measure,
        ),
      ),
    );
    expect(transport.writes, hasLength(1 + _config.measureRetries));
  });

  test('battery, calibration and device info', () async {
    await scanAndConnect();
    final battery = await client.readBattery();
    expect(battery.percent, 87);
    final cal = await client.calibrate();
    expect(cal.status, CalibrationStatus.success);
    final info = await client.readDeviceInfo();
    expect(info.deviceId, device.deviceId);
    expect(info.model, ColorimeterModel.ls170);
    expect(info.serialNumber, 'A0001');
    expect(info.printableStrings, contains('LS170 V1.0.3'));
    expect(transport.writes.map((w) => w.$2[1]), [0x20, 0x20, 0x40]);
  });

  test('commands are serialized', () async {
    await scanAndConnect();
    final results = await Future.wait<Object>([
      client.readBattery(),
      client.measure(),
      client.calibrate(),
    ]);
    expect(results[0], isA<BatteryStatus>());
    expect(results[1], isA<ColorMeasurement>());
    expect(results[2], isA<CalibrationResult>());
  });

  test('commands require a connection', () async {
    await expectLater(client.measure(), throwsA(isA<NotConnectedException>()));
    await expectLater(client.readBattery(), throwsA(isA<NotConnectedException>()));
  });

  test('write failures are typed', () async {
    await scanAndConnect();
    transport.writeError = const WriteFailedException('busy');
    await expectLater(client.measure(), throwsA(isA<WriteFailedException>()));
  });

  test('a disconnect during measurement fails the measurement', () async {
    await scanAndConnect();
    device.muteMeasurements = true;
    final future = client.measure();
    await _settle(20);
    transport.simulateDisconnect(device.deviceId);
    await expectLater(future, throwsA(isA<DeviceDisconnectedException>()));
    expect(client.isConnected, isFalse);
  });

  test('cancelPendingOperation aborts a measurement', () async {
    await scanAndConnect();
    device.muteMeasurements = true;
    final future = client.measure();
    await _settle(10);
    client.cancelPendingOperation();
    await expectLater(
      future,
      throwsA(
        isA<OperationCancelledException>().having(
          (e) => e.operation,
          'op',
          ColorimeterOperation.measure,
        ),
      ),
    );
    device.muteMeasurements = false;
    expect((await client.measure()).lab.l, 92.59, reason: 'client still usable');
  });

  test('notifications from other devices are ignored', () async {
    await scanAndConnect();
    final results = <ColorMeasurement>[];
    final sub = client.measurements.listen(results.add);
    transport.emitNotification('OTHER', Ls170FrameEncoder.colorResult(lab: const Lab(1, 2, 3)));
    await _settle();
    expect(results, isEmpty);
    await sub.cancel();
  });

  test('connectedDevice exposes the scanned device', () async {
    await scanAndConnect();
    expect(client.connectedDevice?.name, 'LS170A0001');
    await client.disconnect();
    expect(client.connectedDevice, isNull);
  });

  test('connect stops a running scan', () async {
    final sub = client.scan().listen((_) {});
    await _settle(5);
    expect(transport.isScanning, isTrue);
    await client.connect(device.deviceId);
    expect(transport.isScanning, isFalse);
    await sub.cancel();
  });

  group('lifecycle', () {
    test('disconnectAndRestore disconnects on pause and reconnects on resume', () async {
      final c = ColorimeterClient(
        transport: transport,
        config: const ColorimeterConfig(
          postConnectDelay: Duration(milliseconds: 1),
          backgroundBehavior: BackgroundBehavior.disconnectAndRestore,
        ),
      );
      await c.connect(device.deviceId);
      await c.handleAppLifecycleState(AppLifecycleState.inactive);
      expect(c.isConnected, isTrue);
      await c.handleAppLifecycleState(AppLifecycleState.hidden);
      await c.handleAppLifecycleState(AppLifecycleState.paused);
      expect(c.isConnected, isFalse);
      await c.handleAppLifecycleState(AppLifecycleState.resumed);
      expect(c.isConnected, isTrue);
      expect(transport.connectCalls, hasLength(2));
      await c.dispose();
    });

    test('keepConnected stays connected but stops scans', () async {
      await client.connect(device.deviceId);
      final sub = client.scan().listen((_) {});
      await _settle(5);
      await client.handleAppLifecycleState(AppLifecycleState.paused);
      expect(client.isConnected, isTrue);
      expect(transport.isScanning, isFalse);
      await sub.cancel();
    });

    test('a manual disconnect while paused prevents restore', () async {
      final c = ColorimeterClient(
        transport: transport,
        config: const ColorimeterConfig(
          postConnectDelay: Duration(milliseconds: 1),
          backgroundBehavior: BackgroundBehavior.disconnectAndRestore,
        ),
      );
      await c.connect(device.deviceId);
      await c.handleAppLifecycleState(AppLifecycleState.paused);
      await c.disconnect();
      await c.handleAppLifecycleState(AppLifecycleState.resumed);
      expect(c.isConnected, isFalse);
      await c.dispose();
    });
  });

  test('dispose cleans up subscriptions, streams and the transport', () async {
    await scanAndConnect();
    final done = Completer<void>();
    client.measurements.listen(null, onDone: done.complete);
    await client.dispose();
    await done.future.timeout(const Duration(seconds: 1));
    expect(transport.isDisposed, isTrue);
    expect(transport.hasNotificationListeners, isFalse);
    expect(transport.disconnectCalls, [device.deviceId]);
    expect(() => client.scan(), throwsStateError);
    await client.dispose(); // idempotent
  });
}
