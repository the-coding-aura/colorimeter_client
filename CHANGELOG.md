# Changelog

## Upcoming

- Other operating systems, including iOS and desktop.
- Built-in options for other colorimeter devices.

## 0.1.0

Initial release (Android, BLE only).

- `ColorimeterClient`:
  - Scanning with a timeout, LS170/LS171 name filtering, de-duplication by address, and RSSI
    smoothing with configurable signal-quality thresholds.
  - Connect and disconnect with timeouts, a connection-state stream, typed exceptions,
    cancellation, and bounded optional auto-reconnect.
  - App-lifecycle handling.
- LS170 protocol: measure, calibrate, battery and device-info commands (CRC-16/MODBUS), frame
  reassembly, and parsers for AB44, AB20 and AB40. App-triggered and device-button readings share
  one `measurements` stream.
- Models: `ColorMeasurement`, `Lab`, `Luv`, `LCh`, `Yxy`, `Xyz`, `Rgb`, `Cmyk`, `BatteryStatus`,
  `DeviceInfo`, `CalibrationResult`.
- Color math: conversions with a configurable white point (default D65/10°), ΔE\*ab, ΔE\*uv,
  ΔE\*94, ΔE\*cmc (2:1, 1:1, 1.4:1) and ΔE\*00, QC PASS/NG (threshold 0.1–50), and nearest-3 chart
  matching.
- Storage: `MyColorsRepository` and `CompareHistoryRepository` interfaces with in-memory
  implementations, plus JSON import/export restricted to the same colorimeter model.
- Native Kotlin GATT transport and `package:colorimeter_client/testing.dart` (fake transport,
  simulated LS170, frame encoder).
- Example app with a demo mode.
- Device profiles: LS170 and LS171 are the built-in family (one shared protocol). Another
  instrument can be added with `ColorimeterDeviceProfile` and `ColorimeterProtocol` without
  changing scan, connect, or the command flow.
