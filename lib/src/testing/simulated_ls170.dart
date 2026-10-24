import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/color_spaces.dart';
import '../transport/transport_types.dart';
import 'fake_transport.dart';
import 'frame_encoder.dart';

/// A simulated LS170 attached to a [FakeColorimeterTransport].
///
/// It advertises while the fake is scanning, answers the Scan, Calibrate,
/// Battery and Device-info commands with realistic (fragmented) frames and
/// can simulate a press of the device button. Used by the tests and by the
/// example app's demo mode.
final class SimulatedLs170 {
  /// Attaches a simulated device to [transport].
  SimulatedLs170(
    this.transport, {
    this.deviceId = 'C0:FF:EE:17:00:01',
    this.name = 'LS170A0001',
    this.rssi = -58,
    this.responseDelay = const Duration(milliseconds: 300),
    this.chunkSize = 20,
    this.batteryValue = 87,
    Lab? nextLab,
    math.Random? random,
  }) : nextLab = nextLab ?? const Lab(92.59, -0.29, 0.55),
       _random = random ?? math.Random(170) {
    transport
      ..advertisementsOnScan = [BleAdvertisement(deviceId: deviceId, name: name, rssi: rssi)]
      ..onWrite = _onWrite;
  }

  /// The fake transport.
  final FakeColorimeterTransport transport;

  /// Bluetooth address.
  final String deviceId;

  /// Advertised name.
  final String name;

  /// Advertised RSSI.
  final int rssi;

  /// Time between a command and its response.
  final Duration responseDelay;

  /// Notification size used to fragment responses.
  final int chunkSize;

  /// Value reported by the battery response.
  int batteryValue;

  /// Lab value of the next measurement. When [jitter] is non-zero, each
  /// reading varies randomly around it.
  Lab nextLab;

  /// Maximum random deviation added to each Lab channel.
  double jitter = 0;

  /// When `true`, Scan commands are ignored (to exercise timeouts).
  bool muteMeasurements = false;

  final math.Random _random;

  Future<void> _onWrite(String id, Uint8List data) async {
    if (id != deviceId || data.length < 3 || data[0] != 0xAB) return;
    Uint8List? response;
    switch (data[1]) {
      case 0x44:
        if (!muteMeasurements) response = _colorFrame();
      case 0x20 when data[2] == 0x0B:
        response = Ls170FrameEncoder.battery(batteryValue);
      case 0x20 when data[2] == 0x2E:
        response = Ls170FrameEncoder.calibration();
      case 0x40:
        response = Ls170FrameEncoder.deviceInfo(payload: 'LS170 V1.0.3'.codeUnits);
    }
    if (response == null) return;
    final frame = response;
    unawaited(
      Future<void>.delayed(responseDelay, () {
        if (transport.connectedDevices.contains(deviceId)) {
          transport.emitNotifications(deviceId, Ls170FrameEncoder.chunk(frame, size: chunkSize));
        }
      }),
    );
  }

  Uint8List _colorFrame() {
    double j() => jitter == 0 ? 0 : (_random.nextDouble() * 2 - 1) * jitter;
    final lab = Lab((nextLab.l + j()).clamp(0, 100).toDouble(), nextLab.a + j(), nextLab.b + j());
    return Ls170FrameEncoder.colorResult(lab: lab);
  }

  /// Simulates a short press of the device button (unsolicited AB44).
  void pressButton() {
    if (!transport.connectedDevices.contains(deviceId)) return;
    transport.emitNotifications(deviceId, Ls170FrameEncoder.chunk(_colorFrame(), size: chunkSize));
  }
}
