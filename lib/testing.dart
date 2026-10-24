/// Test doubles for `colorimeter_client`.
///
/// * `FakeColorimeterTransport`: scriptable in-memory transport.
/// * `SimulatedLs170`: a virtual LS170 that answers commands over the fake.
/// * `Ls170FrameEncoder`: builds response frames.
///
/// ```dart
/// final transport = FakeColorimeterTransport();
/// final device = SimulatedLs170(transport);
/// final client = ColorimeterClient(transport: transport);
/// await client.connect(device.deviceId);
/// final reading = await client.measure();
/// ```
library;

export 'src/testing/fake_transport.dart';
export 'src/testing/frame_encoder.dart';
export 'src/testing/simulated_ls170.dart';
