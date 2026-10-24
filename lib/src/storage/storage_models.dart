import 'package:flutter/foundation.dart';

import '../color/conversions.dart';
import '../color/qc.dart';
import '../json_utils.dart';
import '../models/color_measurement.dart';
import '../models/color_spaces.dart';

/// A "My Colors" folder.
@immutable
final class ColorFolder {
  /// Creates a folder.
  const ColorFolder({required this.id, required this.name, required this.createdAt});

  /// Restores a folder from [toJson] output.
  factory ColorFolder.fromJson(JsonMap json) => ColorFolder(
    id: readString(json, 'id'),
    name: readString(json, 'name'),
    createdAt: readDateTime(json, 'createdAt'),
  );

  /// Unique id.
  final String id;

  /// Display name.
  final String name;

  /// Creation time.
  final DateTime createdAt;

  /// Copy with a new name.
  ColorFolder rename(String name) => ColorFolder(id: id, name: name, createdAt: createdAt);

  /// JSON form.
  JsonMap toJson() => {'id': id, 'name': name, 'createdAt': createdAt.toUtc().toIso8601String()};
}

/// A saved color in "My Colors".
@immutable
final class MyColor {
  /// Creates a saved color.
  const MyColor({
    required this.id,
    required this.folderId,
    required this.name,
    required this.createdAt,
    required this.lab,
    this.measurement,
    this.chartCode,
  });

  /// Restores a color from [toJson] output.
  factory MyColor.fromJson(JsonMap json) {
    final m = readOptionalMap(json, 'measurement');
    return MyColor(
      id: readString(json, 'id'),
      folderId: readString(json, 'folderId'),
      name: readString(json, 'name'),
      createdAt: readDateTime(json, 'createdAt'),
      lab: Lab.fromJson(readMap(json, 'lab')),
      measurement: m == null ? null : ColorMeasurement.fromJson(m),
      chartCode: readOptionalString(json, 'chartCode'),
    );
  }

  /// Unique id.
  final String id;

  /// Folder the color belongs to.
  final String folderId;

  /// Display name.
  final String name;

  /// When it was measured / saved.
  final DateTime createdAt;

  /// Lab value.
  final Lab lab;

  /// Full measurement when saved from the device.
  final ColorMeasurement? measurement;

  /// Chart code when saved from a standard color chart.
  final String? chartCode;

  /// sRGB preview: the measured RGB when available, else converted from
  /// [lab].
  Rgb get previewRgb => measurement?.rgb ?? ColorConversions.labToRgb(lab);

  /// Copy with changes.
  MyColor copyWith({String? folderId, String? name}) => MyColor(
    id: id,
    folderId: folderId ?? this.folderId,
    name: name ?? this.name,
    createdAt: createdAt,
    lab: lab,
    measurement: measurement,
    chartCode: chartCode,
  );

  /// Uses this color as a comparison standard or sample.
  ColorReference toReference() => ColorReference(lab: lab, name: name, measurement: measurement);

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'folderId': folderId,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lab': lab.toJson(),
    if (measurement != null) 'measurement': measurement!.toJson(),
    if (chartCode != null) 'chartCode': chartCode,
  };
}

/// One "Compare History" entry.
///
/// Only the two colors and the time are stored; ΔE and the QC verdict are
/// computed by [evaluate], so the history follows the currently selected
/// formula and threshold (as the LS170 manual requires).
@immutable
final class CompareRecord {
  /// Creates a record.
  const CompareRecord({
    required this.id,
    required this.timestamp,
    required this.standard,
    required this.sample,
  });

  /// Restores a record from [toJson] output.
  factory CompareRecord.fromJson(JsonMap json) => CompareRecord(
    id: readString(json, 'id'),
    timestamp: readDateTime(json, 'timestamp'),
    standard: ColorReference.fromJson(readMap(json, 'standard')),
    sample: ColorReference.fromJson(readMap(json, 'sample')),
  );

  /// Unique id.
  final String id;

  /// Comparison time.
  final DateTime timestamp;

  /// Standard color.
  final ColorReference standard;

  /// Sample color.
  final ColorReference sample;

  /// Computes ΔE and the QC verdict with [settings].
  ColorComparison evaluate(
    QcSettings settings, {
    WhitePoint whitePoint = WhitePoint.d65TenDegree,
  }) => ColorComparison.compare(standard, sample, settings: settings, whitePoint: whitePoint);

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'standard': standard.toJson(),
    'sample': sample.toJson(),
  };
}
