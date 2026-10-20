# colorimeter_client — Requirements

Flutter package for the Linshang **LS170 / LS171** colorimeter over Bluetooth Low Energy.
**Platform scope: Android only** (do not declare iOS, web, desktop, or Bluetooth Classic).

## 1. Core Bluetooth features

- Scan for nearby Bluetooth devices.
- Support Bluetooth Low Energy (BLE).
- Connect to and disconnect from devices.
- Monitor connection state.
- Handle scan timeouts.
- Handle connection timeouts.
- Handle connection failures.
- Handle device disconnections.
- Decode incoming IoT sensor data.

Make thresholds configurable because RSSI values do not map reliably to the same quality categories for every device or environment.

## 3. Connection and device management

- Create a reusable BLE client.
- Create a device model.
- Create a connection manager.
- Expose connection-state streams.
- Support multiple discovered devices.
- Handle repeated advertisements.
- Track connection attempts.
- Prevent duplicate connection operations where appropriate.
- Support operation cancellation.
- Provide connection error types.
- Clean up subscriptions on disconnect.
- Handle application lifecycle changes.
- Support optional automatic reconnection.
- Avoid endless reconnection loops.

## 6. Dart code quality and analysis

- Enable sound null safety.
- Use strict casts, inference, and raw-type analysis where appropriate.
- Include Flutter or Dart lint rules.
- Enforce consistent formatting.
- Document all public APIs.
- Avoid unnecessary `dynamic`.
- Use typed models instead of unstructured maps.
- Use enums for connection and signal states.
- Handle asynchronous errors.
- Avoid unawaited futures.
- Cancel stream subscriptions correctly.
- Prevent resource leaks.
- Avoid excessive logging.
- Use meaningful exception classes.
- Keep public APIs stable and minimal.
- Resolve analyzer errors and warnings.
- Add static analysis to CI.

Recommended commands:

```bash
dart format .
flutter analyze
flutter test
dart doc
flutter pub outdated
flutter pub publish --dry-run
```

## 7. Testing requirements

- Test device scanning.
- Test device filtering.
- Test RSSI parsing and signal models.
- Test signal smoothing.
- Test signal threshold detection.
- Test missing or invalid signal values.
- Test stream cancellation.
- Test connection and disconnection.
- Test connection failures and timeouts.
- Test duplicate advertisements.
- Test unexpected device disconnections.
- Test permission-denied scenarios.
- Test cleanup and disposal.
- Test reconnection policies.
- Mock the Bluetooth transport for unit tests.
- Test on real BLE hardware.
- Test supported Android versions (iOS out of scope for now).
- Test platform-specific lifecycle behavior.

## 8. Documentation requirements

- Explain the package purpose.
- Provide installation instructions.
- Document Android permissions.
- (iOS Bluetooth usage descriptions: out of scope until iOS is supported; note this in README.)
- Explain BLE versus Bluetooth Classic.
- Include a scanning example.
- Include a connection example.
- Include an RSSI monitoring example.
- Explain RSSI limitations.
- Document signal quality thresholds.
- Document all public APIs.
- List supported platforms.
- Explain device compatibility.
- Document known limitations.
- Include troubleshooting for scanning and connection failures.
- Explain stream disposal.
- Include a working example app.
- Maintain a changelog.
- Generate API documentation.
- Include a license.

## 9. pub.dev package score

- Use valid `pubspec.yaml` metadata.
- Provide a clear package description.
- Include a README and license.
- Include a changelog.
- Document public APIs.
- Follow Dart conventions.
- Resolve `flutter analyze` findings.
- Test platform compatibility.
- Keep dependencies maintained.
- Run `pana` to identify scoring issues.
- Review the package publishing dry run.
- Verify the example application.
- Avoid declaring unsupported platforms.

For a package intended specifically for BLE, don't claim web, desktop, or Bluetooth Classic support unless the implementation genuinely supports it.

## 10. LS170 colorimeter features to implement

The colorimeter returns one measurement at a time (D65 illuminant, 10° observer) over BLE. The app/package uses that reading for matching, comparison, and QC.

### Data fetched from the device

- **Lab** — L*, a*, b*
- **Luv** — L, u, v
- **LCh** — L, C, h
- **Yxy** — Y, x, y
- **RGB** and **Hex**
- **CMYK** (listed as a color space in the manual; derive from RGB if not in the frame)
- **Battery level**
- **Device info** — model, serial number, manufacture date, calibration date, device status, firmware version
- **Calibration result** — success or failure after the white-tile cap is closed
- **Color difference** (computed in Dart from two readings, not a sensor value): ΔL, Δa, Δb and ΔE using ΔE*ab, ΔE*uv, ΔE*94, ΔE*cmc(2:1), ΔE*cmc(1:1), ΔE*cmc(1.4:1), ΔE*00

A reading can be started from the app (**Scan** command) or by a **short press** on the colorimeter button (unsolicited AB44 notify). Both must be delivered on the same measurement stream.

### Use cases to support

- Measure a sample color and expose it in all spaces above.
- Match the reading to the closest colors in a color chart (up to three nearest by ΔE).
- Compare a standard color with a sample color.
- QC check: configurable ΔE threshold (0.1–50) returning **PASS** or **NG**.
- Accept a typed Lab or LCh as a standard instead of measuring it.
- Save readings in **My Colors** (folders, name, timestamp).
- Keep **Compare History** (time, ΔE, QC result).
- Search standard color charts and save a chart color.
- Share a result as data (and as an image in the example app).
- Import shared color data, only from the same colorimeter model.
- Calibrate with the bottom cap closed.
- Browse saved history without the device connected (offline storage).
