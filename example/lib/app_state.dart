import 'dart:async';
import 'dart:io';

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'demo_chart.dart';

/// Which comparison slot the next reading fills.
enum CompareSlot { standard, sample }

/// App-wide state: the client, the latest readings, comparison and storage.
class AppState extends ChangeNotifier {
  AppState._(this._storageDir);

  /// Creates the state. With [persist], colors are loaded from and saved to the
  /// documents directory; otherwise they stay in memory. With [demo] the
  /// simulated LS170 is used from the start.
  static Future<AppState> create({bool demo = false, bool persist = true}) async {
    final dir = persist ? await getApplicationDocumentsDirectory() : null;
    final state = AppState._(dir);
    await state._loadStorage();
    state._createClient(demo: demo);
    return state;
  }

  final Directory? _storageDir;

  late ColorimeterClient client;
  SimulatedLs170? simulator;
  bool get demoMode => simulator != null;

  late InMemoryMyColorsRepository myColors;
  late InMemoryCompareHistoryRepository history;
  final List<ColorChart> charts = [demoChart];

  ColorimeterConnectionState connection = ColorimeterConnectionState.initial;
  List<DiscoveredDevice> devices = [];
  bool scanning = false;
  ColorMeasurement? lastMeasurement;
  BatteryStatus? battery;
  DeviceInfo? deviceInfo;
  CalibrationResult? calibration;
  bool busy = false;

  QcSettings qc = QcSettings();
  ColorReference? standard;
  ColorReference? sample;
  CompareSlot armedSlot = CompareSlot.sample;
  bool compareTabActive = false;

  ColorimeterModel model = ColorimeterModel.ls170;
  final _messages = StreamController<String>.broadcast();

  /// Snackbar messages for the UI.
  Stream<String> get messages => _messages.stream;

  StreamSubscription<ColorMeasurement>? _measurementSub;
  StreamSubscription<ColorimeterConnectionState>? _stateSub;
  StreamSubscription<List<DiscoveredDevice>>? _scanSub;
  StreamSubscription<void>? _myColorsSub;
  StreamSubscription<void>? _historySub;

  // --------------------------------------------------------------- client

  void _createClient({required bool demo}) {
    ColorimeterTransport? transport;
    if (demo) {
      final fake = FakeColorimeterTransport();
      simulator = SimulatedLs170(fake)..jitter = 1.5;
      transport = fake;
    } else {
      simulator = null;
    }
    client = ColorimeterClient(
      transport: transport,
      config: ColorimeterConfig(
        reconnectPolicy: const ReconnectPolicy(maxAttempts: 3),
        logger: kDebugMode ? debugPrint : null,
      ),
    );
    connection = client.connectionState;
    _stateSub = client.connectionStates.listen((s) {
      connection = s;
      final m = client.connectedDevice?.model;
      if (m != null) model = m;
      if (s.error != null) _message(_describe(s.error!));
      notifyListeners();
    });
    // Keeping a listener for the app's lifetime accepts device-button results.
    _measurementSub = client.measurements.listen(_onMeasurement);
  }

  Future<void> setDemoMode(bool demo) async {
    if (demo == demoMode) return;
    await _disposeClient();
    devices = [];
    battery = null;
    deviceInfo = null;
    calibration = null;
    _createClient(demo: demo);
    notifyListeners();
  }

  Future<void> _disposeClient() async {
    await _scanSub?.cancel();
    await _measurementSub?.cancel();
    await _stateSub?.cancel();
    _scanSub = _measurementSub = _stateSub = null;
    scanning = false;
    await client.dispose();
  }

  // ----------------------------------------------------------------- scan

  Future<void> scan() async {
    if (!demoMode) {
      var permissions = await client.checkPermissions();
      if (!permissions.isGranted) permissions = await client.requestPermissions();
      if (!permissions.isGranted) {
        _message(
          permissions.permanentlyDenied.isNotEmpty
              ? 'Bluetooth permission denied. Enable it in system settings.'
              : 'Bluetooth permission is required to scan.',
        );
        return;
      }
      if (!permissions.canScan) {
        _message('Turn on location services: Android 11 and lower need it for BLE scans.');
      }
    }
    await _scanSub?.cancel();
    devices = [];
    scanning = true;
    notifyListeners();
    _scanSub = client.scan().listen(
      (list) {
        devices = list;
        notifyListeners();
      },
      onError: (Object e) => _message(_describe(e)),
      onDone: () {
        scanning = false;
        if (devices.isEmpty) _message('No LS170/LS171 found. Power it on and close LScolor.');
        notifyListeners();
      },
    );
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    scanning = false;
    notifyListeners();
  }

  Future<void> connect(DiscoveredDevice device) async {
    await _scanSub?.cancel();
    scanning = false;
    await _run(() async {
      await client.connect(device.id);
      model = device.model ?? model;
      _message('Connected to ${device.name}');
      battery = await client.readBattery();
    });
  }

  Future<void> disconnect() => client.disconnect();

  // ------------------------------------------------------------- commands

  Future<void> measure({CompareSlot? slot}) async {
    if (slot != null) armedSlot = slot;
    await _run(client.measure);
  }

  Future<void> calibrate() => _run(() async {
    calibration = await client.calibrate();
    _message(calibration!.isSuccess ? 'Calibration successful' : 'Calibration failed');
  });

  Future<void> readBattery() => _run(() async => battery = await client.readBattery());

  Future<void> readDeviceInfo() => _run(() async => deviceInfo = await client.readDeviceInfo());

  Future<void> _run(Future<void> Function() body) async {
    busy = true;
    notifyListeners();
    try {
      await body();
    } on ColorimeterException catch (e) {
      _message(_describe(e));
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _onMeasurement(ColorMeasurement m) {
    lastMeasurement = m;
    if (compareTabActive) {
      final ref = ColorReference.fromMeasurement(m);
      setCompareColor(armedSlot, ref);
    }
    if (m.source == MeasurementSource.deviceButton) _message('Reading from the device button');
    notifyListeners();
  }

  // -------------------------------------------------------------- compare

  void setCompareColor(CompareSlot slot, ColorReference ref) {
    if (slot == CompareSlot.standard) {
      standard = ref;
      armedSlot = CompareSlot.sample;
    } else {
      sample = ref;
      final std = standard;
      if (std != null) unawaited(history.addRecord(standard: std, sample: ref));
    }
    notifyListeners();
  }

  ColorComparison? get comparison {
    final std = standard, smp = sample;
    if (std == null || smp == null) return null;
    return ColorComparison.compare(std, smp, settings: qc);
  }

  void setQc(QcSettings settings) {
    qc = settings;
    notifyListeners();
  }

  List<ChartMatch> matchesFor(Lab lab) => ColorChartMatcher.nearest(lab, charts);

  // -------------------------------------------------------------- storage

  File? _file(String name) => _storageDir == null ? null : File('${_storageDir.path}/$name');

  Future<void> _loadStorage() async {
    MyColorsExport? colors;
    CompareHistoryExport? records;
    final colorsFile = _file('my_colors.json');
    final historyFile = _file('compare_history.json');
    if (colorsFile != null && await colorsFile.exists()) {
      colors = _decodeAnyModel(
        await colorsFile.readAsString(),
        (s, m) => ColorDataCodec.decodeMyColors(s, expectedModel: m),
      );
    }
    if (historyFile != null && await historyFile.exists()) {
      records = _decodeAnyModel(
        await historyFile.readAsString(),
        (s, m) => ColorDataCodec.decodeCompareHistory(s, expectedModel: m),
      );
    }
    myColors = InMemoryMyColorsRepository(
      folders: colors?.folders ?? const [],
      colors: colors?.colors ?? const [],
    );
    history = InMemoryCompareHistoryRepository(records: records?.records ?? const []);
    if (colors != null) model = colors.model;
    if ((await myColors.getFolders()).isEmpty) await myColors.createFolder('My colors');
    _myColorsSub = myColors.changes.listen((_) => unawaited(_saveMyColors()));
    _historySub = history.changes.listen((_) => unawaited(_saveHistory()));
  }

  T? _decodeAnyModel<T>(String source, T Function(String, ColorimeterModel) decode) {
    for (final m in ColorimeterModel.builtIn) {
      try {
        return decode(source, m);
      } on ColorDataModelMismatchException {
        continue;
      } on ColorDataFormatException {
        return null;
      }
    }
    return null;
  }

  Future<String> exportMyColors({String? folderId}) async {
    final folders = await myColors.getFolders();
    final selected = folderId == null ? folders : folders.where((f) => f.id == folderId).toList();
    final colors = [for (final f in selected) ...await myColors.getColors(f.id)];
    return ColorDataCodec.encodeMyColors(model: model, folders: selected, colors: colors);
  }

  Future<String> exportHistory() async =>
      ColorDataCodec.encodeCompareHistory(model: model, records: await history.getRecords());

  /// Imports shared colors into [folderId]; returns how many were added.
  Future<int> importMyColors(String json, String folderId) async {
    final bundle = ColorDataCodec.decodeMyColors(json, expectedModel: model);
    for (final c in bundle.colors) {
      await myColors.addColor(
        folderId,
        name: c.name,
        lab: c.lab,
        measurement: c.measurement,
        chartCode: c.chartCode,
        createdAt: c.createdAt,
      );
    }
    return bundle.colors.length;
  }

  Future<void> _saveMyColors() async {
    final file = _file('my_colors.json');
    if (file != null) await file.writeAsString(await exportMyColors());
  }

  Future<void> _saveHistory() async {
    final file = _file('compare_history.json');
    if (file != null) await file.writeAsString(await exportHistory());
  }

  // ---------------------------------------------------------------- misc

  void _message(String text) {
    if (!_messages.isClosed) _messages.add(text);
  }

  static String _describe(Object e) => switch (e) {
    BluetoothUnavailableException(:final state) => 'Bluetooth is ${state.name}.',
    BluetoothPermissionException() => 'Bluetooth permission is missing.',
    ColorimeterTimeoutException(:final operation) =>
      operation == ColorimeterOperation.measure
          ? 'No measurement received. Hold still on the sample or press the device button.'
          : '${operation.name} timed out. Close LScolor and retry.',
    ColorimeterConnectionException(:final gattStatus) =>
      'Connection failed${gattStatus == null ? '' : ' (status $gattStatus)'}. '
          'Close LScolor and retry.',
    DeviceDisconnectedException() => 'Device disconnected.',
    ColorimeterException(:final message) => message,
    _ => '$e',
  };

  @override
  void dispose() {
    unawaited(_myColorsSub?.cancel());
    unawaited(_historySub?.cancel());
    unawaited(_disposeClient());
    unawaited(myColors.dispose());
    unawaited(history.dispose());
    unawaited(_messages.close());
    super.dispose();
  }
}
