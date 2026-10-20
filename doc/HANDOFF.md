# Handoff: build `colorimeter_client`

Paste the prompt below into a new chat opened on `D:\ICR_APP\colorimeter_client`.

---

## Prompt for the new chat

Build the Flutter package `colorimeter_client` in this folder. It was scaffolded with
`flutter create --template=plugin --platforms=android --org com.icrpaints`.

Scope: **Android only**, BLE only, Linshang **LS170 / LS171** colorimeter.

Read first:

- `doc/requirements.md`: the full checklist (BLE core, connection manager, code quality, tests, docs, pub.dev score, LS170 features).
- `doc/reference/Ls170BleManager.kt.txt`: a working Kotlin implementation from the ICR Paints app, tested on real hardware. Port its behavior.
- `doc/reference/LS170_Kotlin_BLE_Read_Lab_Steps.txt`: protocol summary.
- `doc/reference/LS170_manual_and_BLE_protocol_extract.txt` and the PDFs: the user manual and the RF-star BLE bridge protocol.

Deliverables:

1. A BLE transport abstraction (`ColorimeterTransport`) with a real implementation and a fake for tests. The real one can use `flutter_blue_plus` or a native Kotlin method/event channel; pick one and justify it in the README.
2. `ColorimeterClient` and a connection manager. Provide scan with a timeout, name filtering (LS170/LS171), de-duplication by address, and RSSI with configurable thresholds and smoothing. Connect and disconnect with timeouts, a connection-state stream, typed exceptions, cancellation, and optional bounded auto-reconnect.
3. A protocol layer: command builders, notify-frame reassembly, and AB44/AB20/AB40 parsers. Expose typed models (`ColorMeasurement`, `Lab`, `Luv`, `LCh`, `Yxy`, `Rgb`, `Cmyk`, `BatteryStatus`, `DeviceInfo`, `CalibrationResult`).
4. Pure-Dart color math: conversions, every ΔE formula (ab, uv, 94, cmc 2:1 / 1:1 / 1.4:1, 2000), QC PASS/NG with a threshold from 0.1 to 50, and nearest-3 chart matching.
5. Storage interfaces for My Colors and Compare History, with an in-memory default. Add import/export of JSON that is restricted to the same model.
6. An example app with scan, connect, measure (app button and device button), calibrate, battery, device info, compare/QC, and history.
7. Tests using a fake transport, plus `analysis_options.yaml` with strict modes, README, CHANGELOG, LICENSE, a CI workflow, and clean `flutter analyze`, `flutter test`, `dart doc`, and `flutter pub publish --dry-run`.

---

## LS170 protocol facts (verified in the Kotlin app)

### Discovery

- The device advertises a name that starts with `LS170` or `LS171` (for example `LS170` plus the serial number).
- Only one app can be connected at a time. The official **LScolor** app must be closed first.
- The Kotlin app scans in low-latency mode with a 12 s discovery timeout.

### GATT

| Role | Service | Characteristic |
| --- | --- | --- |
| Notify (primary) | `0000FFE0-0000-1000-8000-00805F9B34FB` | `0000FFE4-...` |
| Write (primary) | `0000FFE5-0000-1000-8000-00805F9B34FB` | `0000FFE9-...` |
| Alternate (same char for both roles) | `00001001-...` | `00001002-...` |
| Alternate (same char for both roles) | `0000FFF0-...` | `0000FFF1-...` |
| CCCD | | `00002902-0000-1000-8000-00805F9B34FB` |

Connection sequence:

1. Connect with `TRANSPORT_LE` and `autoConnect = false`.
2. Request MTU 247. Fragmented frames still have to be reassembled.
3. Discover services and pick the first UUID pair that exists.
4. Enable notifications and write the CCCD.
5. Wait about 400 ms before the first command.

Write with `WRITE_TYPE_NO_RESPONSE` when the characteristic supports it.

### Commands (hex)

| Action | Bytes |
| --- | --- |
| Scan / measure | `AB 44 00 00 00 00 36 00 18 64` |
| Calibrate (white cap closed) | `AB 20 2E 00 02 00 90 4F` |
| Battery | `AB 20 0B 00 02 00 9B 43` |
| Device info | `AB 40 00 00 00 00 14 00 45 04` |

### Frame reassembly

- Every frame starts with `0xAB`. When a chunk starts with `0xAB`, reset the buffer.
- The frame type is byte 1: `0x44` is a color result, `0x20` is a status/battery/calibration response, and `0x40` is device info.
- Bytes 6–7 hold a little-endian length.
  - For `0x44`: if the length is between 30 and 200, the total size is length + 8. Otherwise use the 39-byte minimum. The total is always at least 39.
  - For `0x20`, the total size is 10 bytes.
  - For `0x40`, the total size is 40 bytes.
  - For other types, if the length is between 4 and 200, the total size is length + 8.
- Leftover bytes after a complete frame stay in the buffer.

### AB44 color result layout

All values from offset 8 onward are int16 little-endian divided by 100.0:

| Offset | Field |
| --- | --- |
| 8, 10, 12 | L*, a*, b* (Lab) |
| 14, 16, 18 | L, u, v (Luv) |
| 20, 22, 24 | L, C, h (LCh) |
| 26, 28, 30 | Y, x, y (Yxy) |
| 32–35 | 4 bytes, unused/CMYK-related (unverified) |
| 36, 37, 38 | R, G, B as unsigned bytes |

Example reading: L = 92.59, a = -0.29, b = 0.55. Hex is `#RRGGBB` from the RGB bytes.

### Other responses

- `AB 20 0B ...`: battery. The value is an int16 at bytes 6..7. The scale is unverified; confirm on hardware.
- `AB 20 2E ...`: calibration response (success). Failure semantics are unverified.
- `AB 40 ...`: device info block (model, serial number, dates, firmware). The field layout is unverified; log raw frames on hardware and decode.

### Measurement behavior

- An app-triggered scan uses a 6 s timeout per attempt with up to 2 retries (300 ms between retries).
- A short press on the device button sends an **unsolicited** AB44 frame. Accept it whenever a result listener is active and deliver it on the same stream, tagged with `source: app | deviceButton`.
- Measurement uses D65 illuminant and 10° observer.

### Color math reminders

- ΔE*ab = √(ΔL² + Δa² + Δb²)
- RGB distance = √(ΔR² + ΔG² + ΔB²). This is not perceptual and should be offered only as a helper.
- sRGB → XYZ → Lab: standard sRGB uses D65/2° (Xn = 95.047, Yn = 100.0, Zn = 108.883). The device reports D65/10° (Xn = 94.811, Yn = 100.0, Zn = 107.304). Make the white point configurable and document which one is the default.
