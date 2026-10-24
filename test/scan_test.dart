import 'dart:async';

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _short = ScanOptions(timeout: Duration(milliseconds: 100));

void main() {
  late FakeColorimeterTransport transport;
  late ColorimeterClient client;

  setUp(() {
    transport = FakeColorimeterTransport();
    client = ColorimeterClient(transport: transport);
  });

  tearDown(() => client.dispose());

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('filters by LS170/LS171 name prefix and de-duplicates by address', () async {
    transport.advertisementsOnScan = const [
      BleAdvertisement(deviceId: 'A', name: 'LS170A1', rssi: -50),
      BleAdvertisement(deviceId: 'B', name: 'Mi Band', rssi: -40),
      BleAdvertisement(deviceId: 'C', name: null, rssi: -40),
      BleAdvertisement(deviceId: 'D', name: 'ls171b2', rssi: -75),
      BleAdvertisement(deviceId: 'A', name: 'LS170A1', rssi: -52),
      BleAdvertisement(deviceId: 'A', name: 'LS170A1', rssi: -54),
    ];
    final snapshots = await client.scan(options: _short).toList();
    final last = snapshots.last;
    expect(last.map((d) => d.id), ['A', 'D']);
    final a = last.first;
    expect(a.advertisementCount, 3);
    expect(a.rssi, -54);
    expect(a.model, ColorimeterModel.ls170);
    expect(a.serialNumber, 'A1');
    expect(last[1].model, ColorimeterModel.ls171);
    expect(transport.startScanCount, 1);
    expect(transport.isScanning, isFalse, reason: 'stopped on timeout');
  });

  test('RSSI is smoothed and classified with configurable thresholds', () async {
    transport.advertisementsOnScan = const [
      BleAdvertisement(deviceId: 'A', name: 'LS170', rssi: -60),
      BleAdvertisement(deviceId: 'A', name: 'LS170', rssi: -80),
      BleAdvertisement(deviceId: 'A', name: 'LS170', rssi: null),
    ];
    final devices = await client
        .scan(
          options: const ScanOptions(
            timeout: Duration(milliseconds: 50),
            smoothingFactor: 0.5,
            thresholds: RssiThresholds(excellent: -50, good: -65, fair: -75),
          ),
        )
        .last;
    final d = devices.single;
    expect(d.smoothedRssi, -70);
    expect(d.rssi, -80, reason: 'invalid sample keeps the last valid raw value');
    expect(d.signalQuality, SignalQuality.fair);
  });

  test('device with only invalid RSSI has unknown quality', () async {
    transport.advertisementsOnScan = const [
      BleAdvertisement(deviceId: 'A', name: 'LS170', rssi: null),
    ];
    final d = (await client.scan(options: _short).last).single;
    expect(d.rssi, isNull);
    expect(d.signalQuality, SignalQuality.unknown);
  });

  test('minRssi hides distant devices', () async {
    transport.advertisementsOnScan = const [
      BleAdvertisement(deviceId: 'A', name: 'LS170A', rssi: -50),
      BleAdvertisement(deviceId: 'B', name: 'LS170B', rssi: -95),
    ];
    final devices = await client
        .scan(options: const ScanOptions(timeout: Duration(milliseconds: 50), minRssi: -90))
        .last;
    expect(devices.map((d) => d.id), ['A']);
  });

  test('repeated identical advertisements do not flood the stream', () async {
    transport.advertisementsOnScan = [
      for (var i = 0; i < 20; i++) const BleAdvertisement(deviceId: 'A', name: 'LS170', rssi: -60),
    ];
    final snapshots = await client.scan(options: _short).toList();
    expect(snapshots, hasLength(1));
    expect(snapshots.single.single.advertisementCount, 1);
  });

  test('completes with no devices after the timeout', () async {
    final snapshots = await client.scan(options: _short).toList();
    expect(snapshots, isEmpty);
    expect(client.isScanning, isFalse);
  });

  test('cancelling the subscription stops the scan and releases listeners', () async {
    final sub = client.scan().listen((_) {});
    await pump();
    await pump();
    expect(transport.isScanning, isTrue);
    expect(transport.hasAdvertisementListeners, isTrue);
    await sub.cancel();
    await pump();
    expect(transport.isScanning, isFalse);
    expect(transport.hasAdvertisementListeners, isFalse);
    expect(client.isScanning, isFalse);
  });

  test('a new scan ends the previous one', () async {
    final first = client.scan(options: const ScanOptions(timeout: Duration(seconds: 10)));
    final done = Completer<void>();
    first.listen((_) {}, onDone: done.complete);
    await pump();
    await pump();
    final second = client.scan(options: _short).toList();
    await done.future.timeout(const Duration(seconds: 1));
    await second;
  });

  test('permission denied is reported as a typed error', () async {
    transport.permissionStatus = const BluetoothPermissionStatus(
      missingPermissions: ['android.permission.BLUETOOTH_SCAN'],
    );
    await expectLater(
      client.scan(options: _short),
      emitsInOrder([
        emitsError(
          isA<BluetoothPermissionException>().having((e) => e.missingPermissions, 'missing', [
            'android.permission.BLUETOOTH_SCAN',
          ]),
        ),
        emitsDone,
      ]),
    );
    expect(transport.startScanCount, 0);
  });

  test('requestPermissions returns the updated status', () async {
    transport
      ..permissionStatus = const BluetoothPermissionStatus(missingPermissions: ['x'])
      ..permissionStatusAfterRequest = BluetoothPermissionStatus.granted;
    expect((await client.checkPermissions()).isGranted, isFalse);
    expect((await client.requestPermissions()).isGranted, isTrue);
  });

  test('Bluetooth off is reported as a typed error', () async {
    transport.adapterState = BluetoothAdapterState.off;
    await expectLater(
      client.scan(options: _short),
      emitsInOrder([
        emitsError(
          isA<BluetoothUnavailableException>().having(
            (e) => e.state,
            'state',
            BluetoothAdapterState.off,
          ),
        ),
        emitsDone,
      ]),
    );
  });

  test('scanner failures end the scan with ScanFailedException', () async {
    final stream = client.scan(options: const ScanOptions(timeout: Duration(seconds: 5)));
    final errors = <Object>[];
    final done = Completer<void>();
    stream.listen((_) {}, onError: errors.add, onDone: done.complete);
    await pump();
    await pump();
    transport.emitScanError(const ScanFailedException('failed', errorCode: 2));
    await done.future.timeout(const Duration(seconds: 1));
    expect(errors.single, isA<ScanFailedException>().having((e) => e.errorCode, 'code', 2));
    expect(transport.isScanning, isFalse);
  });

  test('startScan failure is reported', () async {
    transport.startScanError = const ScanFailedException('throttled', errorCode: 6);
    await expectLater(
      client.scan(options: _short),
      emitsInOrder([emitsError(isA<ScanFailedException>()), emitsDone]),
    );
  });
}
