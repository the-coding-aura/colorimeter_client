import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter_test/flutter_test.dart';

// Widget tests run under fake async; the client must not await futures that
// belong to another zone.
void main() {
  testWidgets('scan cancel, connect, measure and dispose complete under fake async', (
    tester,
  ) async {
    final fake = FakeColorimeterTransport();
    final device = SimulatedLs170(fake);
    final client = ColorimeterClient(transport: fake);

    final sub = client.scan().listen((_) {});
    await tester.pump(const Duration(milliseconds: 50));
    var cancelled = false;
    sub.cancel().then((_) => cancelled = true).ignore();
    await tester.pump(const Duration(milliseconds: 10));
    expect(cancelled, isTrue);
    expect(client.isScanning, isFalse);

    var connected = false;
    client.connect(device.deviceId).then((_) => connected = true).ignore();
    await tester.pump(const Duration(seconds: 1));
    expect(connected, isTrue);

    ColorMeasurement? result;
    client.measure().then((m) => result = m).ignore();
    await tester.pump(const Duration(seconds: 1));
    expect(result, isNotNull);

    var disposed = false;
    client.dispose().then((_) => disposed = true).ignore();
    await tester.pump(const Duration(seconds: 1));
    expect(disposed, isTrue);
  });
}
