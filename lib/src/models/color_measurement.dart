import 'package:flutter/foundation.dart';

import '../json_utils.dart';
import 'color_spaces.dart';

/// Where a measurement was triggered.
enum MeasurementSource {
  /// The app sent the Scan command (`ColorimeterClient.measure`).
  app,

  /// The user short-pressed the button on the colorimeter (unsolicited AB44).
  deviceButton,
}

/// One color reading from an LS170 / LS171 (D65 illuminant, 10° observer).
///
/// All color spaces except [cmyk] come straight from the device frame.
@immutable
final class ColorMeasurement {
  /// Creates a measurement. Usually produced by the protocol parser.
  ColorMeasurement({
    required this.lab,
    required this.luv,
    required this.lch,
    required this.yxy,
    required this.rgb,
    required this.source,
    required this.timestamp,
    Uint8List? reserved,
    Uint8List? rawFrame,
  }) : reserved = Uint8List.fromList(reserved ?? const []),
       rawFrame = rawFrame == null ? null : Uint8List.fromList(rawFrame);

  /// Restores a measurement from [toJson] output.
  factory ColorMeasurement.fromJson(JsonMap json) {
    final sourceName = readString(json, 'source');
    return ColorMeasurement(
      lab: Lab.fromJson(readMap(json, 'lab')),
      luv: Luv.fromJson(readMap(json, 'luv')),
      lch: LCh.fromJson(readMap(json, 'lch')),
      yxy: Yxy.fromJson(readMap(json, 'yxy')),
      rgb: Rgb.fromJson(readMap(json, 'rgb')),
      source: MeasurementSource.values.firstWhere(
        (s) => s.name == sourceName,
        orElse: () => MeasurementSource.app,
      ),
      timestamp: readDateTime(json, 'timestamp'),
    );
  }

  /// Illuminant used by the instrument.
  static const String illuminant = 'D65';

  /// Standard observer angle (degrees) used by the instrument.
  static const int observerDegrees = 10;

  /// CIE L\*a\*b\*.
  final Lab lab;

  /// CIE L\*u\*v\*.
  final Luv luv;

  /// CIE LCh(ab).
  final LCh lch;

  /// CIE Yxy.
  final Yxy yxy;

  /// 8-bit RGB as computed by the instrument.
  final Rgb rgb;

  /// Whether the app or the device button triggered this reading.
  final MeasurementSource source;

  /// When the reading was received by the phone.
  final DateTime timestamp;

  /// The 4 bytes at offsets 32–35 of the AB44 frame. Their meaning is not
  /// verified (possibly CMYK-related); kept for diagnostics.
  final Uint8List reserved;

  /// The complete AB44 frame, if this measurement came from the device.
  final Uint8List? rawFrame;

  /// `#RRGGBB` from [rgb].
  String get hex => rgb.hex;

  /// CMYK derived from [rgb] (see [Cmyk.fromRgb]).
  Cmyk get cmyk => Cmyk.fromRgb(rgb);

  /// JSON form (without [rawFrame] and [reserved]).
  JsonMap toJson() => {
    'lab': lab.toJson(),
    'luv': luv.toJson(),
    'lch': lch.toJson(),
    'yxy': yxy.toJson(),
    'rgb': rgb.toJson(),
    'source': source.name,
    'timestamp': timestamp.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'ColorMeasurement($lab, ${rgb.hex}, ${source.name})';
}
