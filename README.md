# colorimeter_client

Flutter package for the **Linshang LS170 / LS171** colorimeter over **Bluetooth Low Energy**.
It scans for the device, manages the connection, sends the LS170 commands, decodes the replies
into typed models, and provides the color math an app needs around a reading: conversions, every
ΔE formula of the instrument, PASS/NG quality control, nearest-color chart matching, and
"My Colors" / "Compare History" storage with same-model JSON import/export.

| Platform | Supported |
| --- | --- |
| Android (API 24+) | Yes, BLE only |
| iOS, web, desktop | No (not declared in `pubspec.yaml`) |

## Contents

- [Installation](#installation)
- [Android permissions](#android-permissions)
- [BLE versus Bluetooth Classic](#ble-versus-bluetooth-classic)
- [Quick start](#quick-start)
- [Scanning and RSSI](#scanning-and-rssi)
- [Connection management](#connection-management)
- [Measurements and commands](#measurements-and-commands)
- [Color math and QC](#color-math-and-qc)
- [Storage, import and export](#storage-import-and-export)
- [Testing without hardware](#testing-without-hardware)
- [Why a native Kotlin transport](#why-a-native-kotlin-transport)
- [Device compatibility](#device-compatibility)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Stream disposal](#stream-disposal)

## Installation

```yaml
dependencies:
  colorimeter_client: ^0.1.0
```

```dart
import 'package:colorimeter_client/colorimeter_client.dart';

final client = ColorimeterClient();
```

The plugin's `minSdk` is 24. No other setup is needed: the plugin manifest merges the permissions
below into your app.

## Android permissions

| Android version | Permissions the plugin declares | Runtime request |
| --- | --- | --- |
| 12+ (API 31+) | `BLUETOOTH_SCAN` (with `neverForLocation`), `BLUETOOTH_CONNECT` | Both |
| 6–11 (API 23–30) | `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` (all `maxSdkVersion="30"`) | `ACCESS_FINE_LOCATION` |

`<uses-feature android:name="android.hardware.bluetooth_le" android:required="false"/>` is also
declared so the app stays installable on devices without BLE; `adapterState()` then reports
`BluetoothAdapterState.unavailable`.

Request permissions from the UI before scanning:

```dart
var status = await client.checkPermissions();
if (!status.isGranted) status = await client.requestPermissions();
if (!status.isGranted) {
  // status.permanentlyDenied lists permissions the user blocked: send them to system settings.
}
if (!status.canScan) {
  // Android 11 and lower: location services must be on or scans return nothing.
}
```

Because `BLUETOOTH_SCAN` uses `neverForLocation`, scan results can't be used to derive location.
If your app does need location from BLE scans, override the permission in your own manifest with
`tools:remove="android:usesPermissionFlags"`.

**iOS** is out of scope. When iOS support is added, the app will need
`NSBluetoothAlwaysUsageDescription` in `Info.plist`.

## BLE versus Bluetooth Classic

The LS170/LS171 talk to phones over **Bluetooth Low Energy** using a UART-style GATT service:
commands are written to one characteristic and replies arrive as notifications on another. BLE
devices don't pair through Android's Bluetooth settings like Classic (BR/EDR) headsets do. The
app discovers them by scanning advertisements and connects directly. This package doesn't use or
claim support for Bluetooth Classic (RFCOMM/SPP).

## Quick start

```dart
final client = ColorimeterClient();

// 1. Scan (completes after ScanOptions.timeout, default 12 s).
final devices = await client.scan().last;
final device = devices.first;

// 2. Connect (TRANSPORT_LE, MTU 247, notifications enabled, 400 ms settle).
await client.connect(device.id);

// 3. Every reading arrives here, whether the app or the device button started it.
final sub = client.measurements.listen((m) {
  print('${m.source.name}: L*${m.lab.l} a*${m.lab.a} b*${m.lab.b} ${m.hex}');
});

// 4. Start a reading from the app ("Scan" command).
final reading = await client.measure();

await sub.cancel();
await client.disconnect();
await client.dispose();
```

The `example/` app shows the full flow: scan, connect, measure (app and device button),
calibrate, battery, device info, compare/QC, My Colors, Compare History, chart search, sharing and
import. It has a **Demo mode** that runs the same UI against a simulated LS170.

## Scanning and RSSI

`scan()` returns a stream of snapshots: the full list of matching devices, sorted by name. A new
snapshot is emitted only when something visible changes (a new device, its name, its signal
quality, or its rounded smoothed RSSI). Repeated advertisements are merged by device address.

```dart
final scan = client.scan(
  options: const ScanOptions(
    timeout: Duration(seconds: 10),
    namePrefixes: ['LS170', 'LS171'], // the default; [] accepts every name
    thresholds: RssiThresholds(excellent: -55, good: -67, fair: -78),
    smoothingFactor: 0.3, // EMA alpha; 1.0 disables smoothing
    minRssi: -90, // hide devices weaker than this
  ),
);

final sub = scan.listen(
  (devices) {
    for (final d in devices) {
      print('${d.name} ${d.id} raw=${d.rssi} smoothed=${d.smoothedRssi?.round()} '
          '${d.signalQuality.name} (${d.advertisementCount} adverts)');
    }
  },
  onError: (Object e) {
    // BluetoothUnavailableException, BluetoothPermissionException or ScanFailedException.
  },
  onDone: () => print('scan finished'),
);

// Stop early: cancel the subscription or call client.stopScan().
```

**Signal quality thresholds** (dBm, applied to the smoothed RSSI):

| Quality | Default rule |
| --- | --- |
| `excellent` | ≥ −60 |
| `good` | ≥ −70 |
| `fair` | ≥ −80 |
| `weak` | < −80 |
| `unknown` | No valid sample yet |

**RSSI limitations.** RSSI is a noisy, uncalibrated estimate. The same distance can read 10–20
dB differently across phones, Android versions, phone cases, body position and the colorimeter's
orientation. Use it to rank nearby devices or to hint "move closer", never as a distance. That is
why the thresholds are configurable and why smoothing (an exponential moving average) is applied.
Values outside −127..−1 (for example the 127 "not available" marker) are treated as missing and
don't move the average. Android also throttles scans: more than 5 scan starts within 30 seconds
silently return no results.

## Connection management

```dart
client.connectionStates.listen((s) {
  // s.status: disconnected, connecting, connected, reconnecting, disconnecting
  // s.attempt, s.deviceId, s.mtu, s.error (a ColorimeterException)
});

try {
  await client.connect(device.id, timeout: const Duration(seconds: 10));
} on ColorimeterTimeoutException {
  // no connection within the timeout
} on ColorimeterConnectionException catch (e) {
  // e.gattStatus, e.g. 133 = GATT_ERROR (often another app holds the device)
} on GattSetupException {
  // connected but the UART service / CCCD could not be set up
} on OperationCancelledException {
  // disconnect() was called while connecting
}
```

- `connect()` stops any running scan. Calling it again for the same device while a connect is in
  progress returns the same future instead of starting a second one. Connecting to another device
  first disconnects the current one.
- `disconnect()` cancels whatever is in flight (connect, reconnect or a command).
- **Automatic reconnection** is opt-in and bounded:

  ```dart
  final client = ColorimeterClient(
    config: const ColorimeterConfig(
      reconnectPolicy: ReconnectPolicy(
        maxAttempts: 3, // per link loss, never endless
        initialDelay: Duration(seconds: 1),
        backoffFactor: 2,
        maxDelay: Duration(seconds: 10),
        // The budget refills only after the link stayed up this long.
        stableConnectionDuration: Duration(seconds: 30),
      ),
    ),
  );
  ```

  A user-initiated `disconnect()` never triggers a reconnect. When the budget is exhausted, the
  state becomes `disconnected` with a `DeviceDisconnectedException`.
- **App lifecycle:** forward lifecycle changes so scans stop in the background:

  ```dart
  final listener = AppLifecycleListener(
    onStateChange: (s) => unawaited(client.handleAppLifecycleState(s)),
  );
  ```

  With `BackgroundBehavior.disconnectAndRestore`, the client disconnects when the app is paused
  and reconnects on resume. The default, `keepConnected`, only stops scans.

All errors are subclasses of the sealed `ColorimeterException`, so a `switch` over them is
exhaustive.

## Measurements and commands

| Call | Command sent | Returns |
| --- | --- | --- |
| `measure()` | `AB 44 00 00 00 00 36 00 18 64` | `ColorMeasurement` |
| `calibrate()` | `AB 20 2E 00 02 00 90 4F` | `CalibrationResult` |
| `readBattery()` | `AB 20 0B 00 02 00 9B 43` | `BatteryStatus` |
| `readDeviceInfo()` | `AB 40 00 00 00 00 14 00 45 04` | `DeviceInfo` |

Commands run one at a time; a second call waits for the first. `measure()` waits 6 s for the AB44
reply and retries twice, 300 ms apart (configurable in `ColorimeterConfig`).
`cancelPendingOperation()` aborts the running command with `OperationCancelledException`.

A `ColorMeasurement` carries `lab`, `luv`, `lch`, `yxy`, `rgb`, plus the derived `hex` and `cmyk`.
It also has `source` (`MeasurementSource.app` or `deviceButton`), a `timestamp`, and the
`rawFrame`. A short press on the device button sends an unsolicited AB44 frame, which is
published on `measurements` with `source == deviceButton`. Keep a listener on `measurements` to
receive these; they aren't buffered.

`rawFrames` exposes every reassembled frame for diagnostics. Frames are rebuilt from 20-byte
notification chunks; a chunk starting with `0xAB` starts a new frame.

**Calibration:** put the white-tile bottom cap on the instrument before calling `calibrate()`.

## Color math and QC

Everything below is pure Dart and works offline.

```dart
// Conversions (default white point: D65 / 10°, matching the instrument).
final xyz = ColorConversions.labToXyz(lab);
final rgb = ColorConversions.labToRgb(lab);
final lab2 = ColorConversions.rgbToLab(const Rgb(200, 30, 40));

// Color difference: sample minus standard.
final d = DeltaE.difference(standard, sample, formula: DeltaEFormula.cie2000);
print('ΔL ${d.dL} Δa ${d.da} Δb ${d.db} ΔC ${d.dC} ΔH ${d.dH} ΔE ${d.deltaE}');

// QC: PASS when ΔE <= threshold. Thresholds outside 0.1..50 throw RangeError.
final qc = QcSettings(formula: DeltaEFormula.cmc2To1, threshold: 1.5);
final result = ColorComparison.compare(
  ColorReference(lab: const Lab(50, 10, 10), name: 'Typed standard'),
  ColorReference.fromMeasurement(reading),
  settings: qc,
);
print(result.verdict); // QcVerdict.pass or QcVerdict.ng

// Up to three nearest chart colors (ΔE*00 by default).
final matches = ColorChartMatcher.nearest(reading.lab, [myChart]);
```

Formulas: ΔE\*ab (CIE76), ΔE\*uv, ΔE\*94 (graphic arts), ΔE\*cmc 2:1, 1:1, 1.4:1, and ΔE\*00
(CIEDE2000, verified against Sharma's test data).

**White point.** The LS170 reports Lab under **D65 with the 10° observer**
(X<sub>n</sub> 94.811, Y<sub>n</sub> 100, Z<sub>n</sub> 107.304), so that is the default
everywhere (`WhitePoint.d65TenDegree`). sRGB is defined for D65/2° (95.047, 100, 108.883). Pass
`whitePoint: WhitePoint.d65TwoDegree` to the conversion functions to match software that uses
the 2° white point. RGB and CMYK are display approximations, not measured values.

## Storage, import and export

`MyColorsRepository` (folders of named colors, at most 5 folders by default) and
`CompareHistoryRepository` (standard, sample and time; ΔE and the verdict are recomputed with the
current settings) are interfaces. The in-memory implementations work out of the box. Persist them
with the codec, or implement the interfaces on top of a database.

```dart
final json = ColorDataCodec.encodeMyColors(
  model: ColorimeterModel.ls170,
  folders: await repo.getFolders(),
  colors: [for (final f in await repo.getFolders()) ...await repo.getColors(f.id)],
);

try {
  final bundle = ColorDataCodec.decodeMyColors(json, expectedModel: ColorimeterModel.ls170);
} on ColorDataModelMismatchException {
  // "Unmatched device model": the data came from another colorimeter model.
} on ColorDataFormatException {
  // not a colorimeter_client export
}
```

## Testing without hardware

`package:colorimeter_client/testing.dart` provides:

- `FakeColorimeterTransport`: a scriptable transport for scan results, connect success, failure
  or hang, unexpected disconnects, permission and adapter states, and recorded writes.
- `SimulatedLs170`: answers commands on a fake transport with realistic, chunked frames and can
  simulate a device-button press.
- `Ls170FrameEncoder`: builds valid LS170 frames.

```dart
final transport = FakeColorimeterTransport();
final device = SimulatedLs170(transport);
final client = ColorimeterClient(transport: transport);
await client.connect(device.deviceId);
final m = await client.measure();
```

## Why a native Kotlin transport

The real transport (`MethodChannelColorimeterTransport`) is a small Kotlin GATT bridge in this
plugin, not `flutter_blue_plus`:

- It ports the connection sequence of the hardware-tested Kotlin app one to one: `TRANSPORT_LE`
  with `autoConnect=false`, MTU 247, service discovery, the three known UART layouts, CCCD writes
  using the API 33 overloads, and write-without-response.
- No third-party BLE dependency, so there's no version or license churn, and the plugin requests
  only the permissions it needs.
- The Kotlin side only moves bytes. Everything LS170-specific (commands, reassembly, parsing,
  retries, timeouts, reconnection) lives in Dart behind the `ColorimeterTransport` interface,
  where it is unit-tested with the fake transport.

You can supply your own `ColorimeterTransport` (for example one built on another BLE plugin) to
`ColorimeterClient(transport: ...)`.

## Device compatibility

Built in today: **Linshang LS170 and LS171**. They advertise names that start with `LS170` or
`LS171` (for example `LS170A0001`; the suffix is `serialNumber`) and share one BLE protocol, so
they are one [device profile](#adding-another-instrument).

- **GATT layouts tried in order:** `FFE0` service with notify `FFE4` and write `FFE9` (on `FFE5`);
  `1001` with shared characteristic `1002`; `FFF0` with shared characteristic `FFF1`.
- **Android:** 7.0 (API 24) and newer. The permission handling covers both the pre-12 location
  model and the Android 12+ nearby-devices model.

## Adding another instrument

Scan, connect, measure, calibrate, battery and device info all go through the profile of the
connected device. LS170 and LS171 are `ColorimeterDeviceProfile.linshangLs170`. A later instrument
is another profile: name prefixes, GATT layout, command bytes, and a frame decoder. The client
does not need a new connection or command flow.

```dart
const xr100 = ColorimeterModel('XR100');

final client = ColorimeterClient(
  profiles: [
    ColorimeterDeviceProfile.linshangLs170,
    ColorimeterDeviceProfile(
      id: 'xr100',
      models: [xr100],
      protocol: Xr100Protocol(), // implements ColorimeterProtocol
    ),
  ],
);
```

`scan()` then accepts both families. `connect` picks the profile from the advertised name (or
from the `profile` argument). Commands and notification parsing use that profile. Import and
export stay restricted to the same `ColorimeterModel`.

`ColorimeterProtocol` supplies the MTU, CCCD, GATT characteristics, `commandFor`, and a
`ProtocolDecoder`. Throw `UnsupportedError` from `commandFor` for operations the instrument does
not have.

## Known limitations

These are not yet verified on hardware:

- **Battery scale:** the raw 16-bit value is exposed as `BatteryStatus.rawValue`; `percent` is
  filled only when the value lies in 0–100.
- **Calibration failure:** the device answers the calibration command, but a failure reply hasn't
  been observed, so any reply is reported as success.
- **Device info (AB40):** the field layout is undocumented. `DeviceInfo` returns the raw frame,
  printable text runs, and the model and serial number taken from the advertised name. Firmware
  version, manufacture date, calibration date and device status stay `null` until the layout is
  confirmed.
- **CMYK** is derived from RGB (naive conversion, no ICC profile).
- **Bytes 32–35 of AB44** are kept as `ColorMeasurement.reserved`.
- One connection at a time per client.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Scan finds nothing | Close the LScolor app (the device accepts one connection and stops advertising while connected). Wake the colorimeter. On Android 11 and lower, turn on location services (`status.canScan`). Avoid restarting scans more than 5 times in 30 s. |
| `BluetoothPermissionException` | Request permissions from the UI first. If `permanentlyDenied` isn't empty, the user has to enable the permission in app settings. |
| `ColorimeterConnectionException` with `gattStatus` 133 | Generic Android GATT error. Close LScolor, toggle Bluetooth, move closer, and retry. A bounded `ReconnectPolicy` helps with transient failures. |
| `GattSetupException` | The device connected but exposes none of the known UART layouts: it isn't an LS170/LS171, or its firmware uses another layout. |
| `ColorimeterTimeoutException` on `measure()` | Keep the aperture flat on the sample. The device may be busy with a button-press reading. Increase `measureTimeout` if needed. |
| Device-button readings are missing | Listen to `client.measurements` while connected. |

## Stream disposal

- Cancel your `scan()` subscription, or call `stopScan()`, when the screen closes. Cancelling
  stops the Android scan.
- Cancel subscriptions to `measurements`, `connectionStates`, `rawFrames` and `adapterStates`
  when you're done with them. The client keeps working.
- `client.dispose()` disconnects, stops scanning, closes every stream it exposes, and releases the
  platform GATT client. The client can't be used afterwards.
- Repositories have `dispose()` to close their `changes` streams.

## Generating API docs

```bash
dart pub global activate dartdoc 9.0.11
dart pub global run dartdoc --no-generate-docs
```

That command is what CI runs. Dart SDK 3.12's `dart doc` is dartdoc 9.0.4, which crashes
with a `RangeError` in `_stripDocImports` when the Flutter SDK checkout uses CRLF line
endings (typical on Windows). The crash is fixed in dartdoc 9.0.8. dartdoc cannot be a
dev dependency of this package: it needs a newer `meta` than the Flutter SDK pins.

## License

MIT, see [LICENSE](LICENSE).
