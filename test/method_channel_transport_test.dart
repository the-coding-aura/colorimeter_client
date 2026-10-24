import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(MethodChannelColorimeterTransport.methodChannelName);
  const events = EventChannel(MethodChannelColorimeterTransport.eventChannelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late MockStreamHandlerEventSink sink;
  late MethodChannelColorimeterTransport transport;
  Object? Function(MethodCall call) respond = (_) => null;

  setUp(() {
    calls = [];
    respond = (_) => null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return respond(call);
    });
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, s) => sink = s));
    transport = MethodChannelColorimeterTransport();
  });

  tearDown(() async {
    await transport.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('decodes platform events into typed models', () async {
    final ads = <BleAdvertisement>[];
    final conns = <TransportConnectionEvent>[];
    final notes = <TransportNotification>[];
    final states = <BluetoothAdapterState>[];
    final errors = <Object>[];
    final subs = [
      transport.advertisements.listen(ads.add, onError: errors.add),
      transport.connectionEvents.listen(conns.add),
      transport.notifications.listen(notes.add),
      transport.adapterStateChanges.listen(states.add),
    ];
    await pumpEventQueue();
    sink
      ..success({'event': 'advertisement', 'id': 'A', 'name': 'LS170', 'rssi': -61, 'timestamp': 0})
      ..success({'event': 'advertisement', 'id': 'B', 'name': null, 'rssi': 127})
      ..success({'event': 'scanFailed', 'code': 2})
      ..success({'event': 'connection', 'id': 'A', 'connected': false, 'status': 8})
      ..success({
        'event': 'notification',
        'id': 'A',
        'value': Uint8List.fromList([0xAB, 0x20]),
      })
      ..success({'event': 'adapterState', 'state': 'off'})
      ..success({'event': 'unknown'})
      ..success('garbage');
    await pumpEventQueue();

    expect(ads.map((a) => (a.deviceId, a.name, a.rssi)), [('A', 'LS170', -61), ('B', null, null)]);
    expect(errors.single, isA<ScanFailedException>().having((e) => e.errorCode, 'code', 2));
    expect(conns.single.gattStatus, 8);
    expect(conns.single.connected, isFalse);
    expect(notes.single.value, [0xAB, 0x20]);
    expect(states, [BluetoothAdapterState.off]);
    for (final s in subs) {
      await s.cancel();
    }
  });

  test('passes arguments and decodes results', () async {
    respond = (call) => switch (call.method) {
      'getAdapterState' => 'on',
      'checkPermissions' => {
        'missing': ['android.permission.BLUETOOTH_SCAN'],
        'permanentlyDenied': <String>[],
        'locationServicesRequired': true,
        'locationServicesEnabled': false,
      },
      'connect' => {'mtu': 185, 'writeWithoutResponse': true},
      _ => null,
    };
    expect(await transport.getAdapterState(), BluetoothAdapterState.on);
    final p = await transport.checkPermissions();
    expect(p.missingPermissions, ['android.permission.BLUETOOTH_SCAN']);
    expect(p.canScan, isFalse);
    final session = await transport.connect('A');
    expect(session.mtu, 185);
    await transport.write('A', Uint8List.fromList([1, 2]));
    await transport.startScan(namePrefixes: ['LS170']);

    final connect = calls.firstWhere((c) => c.method == 'connect');
    final args = (connect.arguments as Map).cast<String, Object?>();
    expect(args['id'], 'A');
    expect(args['mtu'], 247);
    expect(args['candidates'], hasLength(3));
    final write = calls.firstWhere((c) => c.method == 'write');
    expect((write.arguments as Map)['value'], [1, 2]);
    expect((calls.last.arguments as Map)['namePrefixes'], ['LS170']);
  });

  test('maps platform errors to typed exceptions', () async {
    final cases = <String, Matcher>{
      'bluetooth_off': isA<BluetoothUnavailableException>(),
      'permission_denied': isA<BluetoothPermissionException>().having(
        (e) => e.missingPermissions,
        'missing',
        ['p'],
      ),
      'gatt_setup_failed': isA<GattSetupException>(),
      'not_connected': isA<NotConnectedException>(),
      'write_failed': isA<WriteFailedException>(),
      'cancelled': isA<OperationCancelledException>(),
      'connect_failed': isA<ColorimeterConnectionException>().having(
        (e) => e.gattStatus,
        'status',
        133,
      ),
    };
    for (final MapEntry(key: code, value: matcher) in cases.entries) {
      respond = (_) => throw PlatformException(
        code: code,
        message: code,
        details: {
          'status': 133,
          'missing': ['p'],
        },
      );
      await expectLater(transport.connect('A'), throwsA(matcher), reason: code);
    }
  });

  test('missing plugin is reported as Bluetooth unavailable', () async {
    messenger.setMockMethodCallHandler(methods, null);
    await expectLater(transport.getAdapterState(), throwsA(isA<BluetoothUnavailableException>()));
  });
}
