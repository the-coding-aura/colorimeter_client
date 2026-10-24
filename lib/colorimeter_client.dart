/// Android BLE client for colorimeters. LS170 and LS171 are built in;
/// other instruments are added with a `ColorimeterDeviceProfile`.
///
/// * `ColorimeterClient`: scan, connect, measure, calibrate, battery and
///   device info.
/// * Color math: `ColorConversions`, `DeltaE`, `QcSettings`,
///   `ColorComparison`, `ColorChartMatcher`.
/// * Storage: `MyColorsRepository`, `CompareHistoryRepository` and
///   `ColorDataCodec`.
///
/// For unit tests, use `package:colorimeter_client/testing.dart` and pass
/// a `FakeColorimeterTransport` to the client.
library;

export 'src/client/colorimeter_client.dart';
export 'src/client/scanner.dart' show ScanOptions;
export 'src/color/color_chart.dart';
export 'src/color/conversions.dart';
export 'src/color/delta_e.dart';
export 'src/color/qc.dart';
export 'src/connection/connection_manager.dart';
export 'src/connection/connection_state.dart';
export 'src/device/colorimeter_device_profile.dart';
export 'src/exceptions.dart';
export 'src/json_utils.dart' show JsonMap;
export 'src/models/color_measurement.dart';
export 'src/models/color_spaces.dart' hide normalizeHue;
export 'src/models/device_models.dart';
export 'src/protocol/frame_assembler.dart';
export 'src/protocol/ls170_parser.dart';
export 'src/protocol/ls170_protocol.dart';
export 'src/signal/rssi.dart';
export 'src/storage/color_data_codec.dart';
export 'src/storage/repositories.dart';
export 'src/storage/storage_models.dart';
export 'src/transport/colorimeter_transport.dart';
export 'src/transport/method_channel_transport.dart';
export 'src/transport/transport_types.dart';
