import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../exceptions.dart';
import '../json_utils.dart';
import '../models/device_models.dart';
import 'storage_models.dart';

/// Decoded "My Colors" export.
@immutable
final class MyColorsExport {
  /// Creates an export bundle.
  MyColorsExport({
    required this.model,
    required this.exportedAt,
    required List<ColorFolder> folders,
    required List<MyColor> colors,
  }) : folders = List.unmodifiable(folders),
       colors = List.unmodifiable(colors);

  /// Model the colors were measured with.
  final ColorimeterModel model;

  /// Export time.
  final DateTime exportedAt;

  /// Exported folders.
  final List<ColorFolder> folders;

  /// Exported colors.
  final List<MyColor> colors;
}

/// Decoded "Compare History" export.
@immutable
final class CompareHistoryExport {
  /// Creates an export bundle.
  CompareHistoryExport({
    required this.model,
    required this.exportedAt,
    required List<CompareRecord> records,
  }) : records = List.unmodifiable(records);

  /// Model the colors were measured with.
  final ColorimeterModel model;

  /// Export time.
  final DateTime exportedAt;

  /// Exported records.
  final List<CompareRecord> records;
}

/// JSON export / import of shared color data.
///
/// Imports are restricted to data measured with the same colorimeter model
/// (as in the LS170 app, which rejects "Unmatched device model").
abstract final class ColorDataCodec {
  /// `format` value of My Colors exports.
  static const String myColorsFormat = 'colorimeter_client/my_colors';

  /// `format` value of Compare History exports.
  static const String compareHistoryFormat = 'colorimeter_client/compare_history';

  /// Schema version written by this package.
  static const int schemaVersion = 1;

  /// Encodes folders and colors measured with [model].
  static String encodeMyColors({
    required ColorimeterModel model,
    required List<ColorFolder> folders,
    required List<MyColor> colors,
    DateTime? exportedAt,
  }) => const JsonEncoder.withIndent('  ').convert({
    ..._header(myColorsFormat, model, exportedAt),
    'folders': [for (final f in folders) f.toJson()],
    'colors': [for (final c in colors) c.toJson()],
  });

  /// Decodes a My Colors export, accepting only [expectedModel].
  ///
  /// Throws [ColorDataFormatException] or [ColorDataModelMismatchException].
  static MyColorsExport decodeMyColors(String source, {required ColorimeterModel expectedModel}) {
    final json = _decode(source, myColorsFormat);
    final model = _checkModel(json, expectedModel);
    return _guard(
      () => MyColorsExport(
        model: model,
        exportedAt: readDateTime(json, 'exportedAt'),
        folders: [for (final f in readMapList(json, 'folders')) ColorFolder.fromJson(f)],
        colors: [for (final c in readMapList(json, 'colors')) MyColor.fromJson(c)],
      ),
    );
  }

  /// Encodes compare records measured with [model].
  static String encodeCompareHistory({
    required ColorimeterModel model,
    required List<CompareRecord> records,
    DateTime? exportedAt,
  }) => const JsonEncoder.withIndent('  ').convert({
    ..._header(compareHistoryFormat, model, exportedAt),
    'records': [for (final r in records) r.toJson()],
  });

  /// Decodes a Compare History export, accepting only [expectedModel].
  static CompareHistoryExport decodeCompareHistory(
    String source, {
    required ColorimeterModel expectedModel,
  }) {
    final json = _decode(source, compareHistoryFormat);
    final model = _checkModel(json, expectedModel);
    return _guard(
      () => CompareHistoryExport(
        model: model,
        exportedAt: readDateTime(json, 'exportedAt'),
        records: [for (final r in readMapList(json, 'records')) CompareRecord.fromJson(r)],
      ),
    );
  }

  static JsonMap _header(String format, ColorimeterModel model, DateTime? exportedAt) => {
    'format': format,
    'version': schemaVersion,
    'model': model.namePrefix,
    'illuminant': 'D65',
    'observer': 10,
    'exportedAt': (exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
  };

  static JsonMap _decode(String source, String format) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw ColorDataFormatException('Not valid JSON', cause: e);
    }
    if (decoded is! Map) throw const ColorDataFormatException('Expected a JSON object');
    final json = decoded.cast<String, Object?>();
    if (json['format'] != format) {
      throw ColorDataFormatException('Expected format "$format", got "${json['format']}"');
    }
    final version = json['version'];
    if (version is! int || version > schemaVersion) {
      throw ColorDataFormatException('Unsupported schema version $version');
    }
    return json;
  }

  static ColorimeterModel _checkModel(JsonMap json, ColorimeterModel expected) {
    final label = _guard(() => readString(json, 'model'));
    if (label.trim().toUpperCase() != expected.namePrefix.toUpperCase()) {
      throw ColorDataModelMismatchException(
        'Unmatched device model: data is from $label, expected ${expected.namePrefix}',
        expectedModel: expected.namePrefix,
        actualModel: label,
      );
    }
    return expected;
  }

  static T _guard<T>(T Function() body) {
    try {
      return body();
    } on ColorimeterException {
      rethrow;
    } on Object catch (e) {
      throw ColorDataFormatException('Invalid color data', cause: e);
    }
  }
}
