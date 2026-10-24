import 'dart:typed_data';

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in for an instrument that is not an LS170 or LS171.
final class _XrProtocol implements ColorimeterProtocol {
  const _XrProtocol();

  static final Uint8List measureCommand = Uint8List.fromList([0xEE, 0x01]);

  @override
  int get requestedMtu => 185;

  @override
  String get cccd => Ls170Gatt.cccd;

  @override
  List<GattCharacteristicPair> get gattCandidates => Ls170Gatt.candidates;

  @override
  Uint8List commandFor(ColorimeterOperation operation) {
    if (operation == ColorimeterOperation.measure) return measureCommand;
    throw UnsupportedError('${operation.name} is not an XR100 command');
  }

  @override
  ProtocolDecoder createDecoder() => _XrDecoder();
}

final class _XrDecoder implements ProtocolDecoder {
  @override
  void reset() {}

  @override
  List<ProtocolFrame> add(List<int> chunk) => chunk.isEmpty ? const [] : [_XrFrame(chunk)];
}

final class _XrFrame implements ProtocolFrame {
  _XrFrame(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  @override
  final Uint8List bytes;

  @override
  String toHex() => bytes.map((b) => b.toRadixString(16)).join(' ');

  @override
  bool get isColorResult => bytes.isNotEmpty && bytes[0] == 0xEE;

  @override
  ColorMeasurement? parseColor({
    MeasurementSource source = MeasurementSource.app,
    DateTime? timestamp,
  }) {
    if (!isColorResult) return null;
    return ColorMeasurement(
      lab: const Lab(1, 2, 3),
      luv: const Luv(1, 0, 0),
      lch: const LCh(1, 0, 0),
      yxy: const Yxy(1, 0, 0),
      rgb: Rgb(1, 2, 3),
      source: source,
      timestamp: timestamp ?? DateTime.utc(2026),
    );
  }

  @override
  BatteryStatus? parseBattery({DateTime? timestamp}) => null;

  @override
  CalibrationResult? parseCalibration({DateTime? timestamp}) => null;

  @override
  DeviceInfo? parseDeviceInfo({
    required String deviceId,
    String? deviceName,
    DateTime? timestamp,
  }) => null;
}

void main() {
  const xr100 = ColorimeterModel('XR100');
  const xrProfile = ColorimeterDeviceProfile(
    id: 'xr100',
    models: [xr100],
    protocol: _XrProtocol(),
  );

  test('a configured profile is scanned, connected and measured on its own protocol', () async {
    final transport = FakeColorimeterTransport();
    final client = ColorimeterClient(
      transport: transport,
      profiles: [ColorimeterDeviceProfile.linshangLs170, xrProfile],
    );
    addTearDown(client.dispose);

    transport.advertisementsOnScan = const [
      BleAdvertisement(deviceId: 'LS', name: 'LS170A1', rssi: -40),
      BleAdvertisement(deviceId: 'XR', name: 'XR100-9', rssi: -45),
      BleAdvertisement(deviceId: 'OTHER', name: 'Headphones', rssi: -30),
    ];
    final found = await client
        .scan(options: const ScanOptions(timeout: Duration(milliseconds: 40)))
        .last;
    expect(found.map((d) => d.id), ['LS', 'XR']);
    expect(found.first.model, ColorimeterModel.ls170);
    expect(found.last.model, xr100);
    expect(found.last.serialNumber, '-9');

    transport.onWrite = (id, data) {
      if (data.length == 2 && data[0] == 0xEE) {
        transport.emitNotification(id, [0xEE, 0x10]);
      }
    };
    await client.connect('XR');
    expect(client.activeProfile?.id, 'xr100');
    expect(transport.lastRequestedMtu, 185);

    final reading = await client.measure();
    expect(reading.lab, const Lab(1, 2, 3));
    expect(transport.writes.single.$2, _XrProtocol.measureCommand);
    await expectLater(client.readBattery(), throwsA(isA<UnsupportedError>()));
  });

  test('the default client only accepts LS170 and LS171', () async {
    final transport = FakeColorimeterTransport();
    final client = ColorimeterClient(transport: transport);
    addTearDown(client.dispose);
    transport.advertisementsOnScan = const [
      BleAdvertisement(deviceId: 'XR', name: 'XR100-1', rssi: -40),
      BleAdvertisement(deviceId: 'LS', name: 'LS171ZZ', rssi: -40),
    ];
    final found = await client
        .scan(options: const ScanOptions(timeout: Duration(milliseconds: 40)))
        .last;
    expect(found.single.model, ColorimeterModel.ls171);
    expect(client.profiles.single.id, ColorimeterDeviceProfile.linshangLs170.id);
  });

  test('custom model JSON is accepted only for that model', () {
    const model = ColorimeterModel('XR100');
    final json = ColorDataCodec.encodeMyColors(model: model, folders: const [], colors: const []);
    expect(ColorDataCodec.decodeMyColors(json, expectedModel: model).model, model);
    expect(
      () => ColorDataCodec.decodeMyColors(json, expectedModel: ColorimeterModel.ls170),
      throwsA(isA<ColorDataModelMismatchException>()),
    );
  });
}
