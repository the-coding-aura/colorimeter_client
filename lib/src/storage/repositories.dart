import 'dart:async';

import '../color/qc.dart';
import '../exceptions.dart';
import '../models/color_measurement.dart';
import '../models/color_spaces.dart';
import 'storage_models.dart';

/// Storage for "My Colors" (folders of saved colors).
///
/// Implement this on top of a database or files for offline persistence;
/// [InMemoryMyColorsRepository] is the default. Methods throw
/// [ColorStorageException] for unknown ids or limit violations.
abstract interface class MyColorsRepository {
  /// All folders, oldest first.
  Future<List<ColorFolder>> getFolders();

  /// Creates a folder.
  Future<ColorFolder> createFolder(String name);

  /// Renames a folder.
  Future<ColorFolder> renameFolder(String folderId, String name);

  /// Deletes folders and the colors inside them.
  Future<void> deleteFolders(Iterable<String> folderIds);

  /// Colors of a folder, oldest first.
  Future<List<MyColor>> getColors(String folderId);

  /// Saves a new color in [folderId].
  Future<MyColor> addColor(
    String folderId, {
    required String name,
    required Lab lab,
    ColorMeasurement? measurement,
    String? chartCode,
    DateTime? createdAt,
  });

  /// Renames a color.
  Future<MyColor> renameColor(String colorId, String name);

  /// Deletes colors.
  Future<void> deleteColors(Iterable<String> colorIds);

  /// Emits after every change.
  Stream<void> get changes;

  /// Releases resources.
  Future<void> dispose();
}

/// Storage for "Compare History".
abstract interface class CompareHistoryRepository {
  /// All records, newest first.
  Future<List<CompareRecord>> getRecords();

  /// Adds a record.
  Future<CompareRecord> addRecord({
    required ColorReference standard,
    required ColorReference sample,
    DateTime? timestamp,
  });

  /// Deletes records.
  Future<void> deleteRecords(Iterable<String> recordIds);

  /// Deletes every record.
  Future<void> clear();

  /// Emits after every change.
  Stream<void> get changes;

  /// Releases resources.
  Future<void> dispose();
}

String _defaultId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_seq++}';
int _seq = 0;

/// In-memory [MyColorsRepository]. Data is lost when the process ends unless
/// the app persists it (for example with `ColorDataCodec`).
final class InMemoryMyColorsRepository implements MyColorsRepository {
  /// Creates a repository, optionally pre-filled (e.g. from a saved export).
  InMemoryMyColorsRepository({
    this.maxFolders = 5,
    Iterable<ColorFolder> folders = const [],
    Iterable<MyColor> colors = const [],
    String Function()? idGenerator,
    DateTime Function()? clock,
  }) : _id = idGenerator ?? _defaultId,
       _clock = clock ?? DateTime.now {
    for (final f in folders) {
      _folders[f.id] = f;
    }
    for (final c in colors) {
      if (!_folders.containsKey(c.folderId)) {
        throw ColorStorageException('Color ${c.id} refers to unknown folder ${c.folderId}');
      }
      _colors[c.id] = c;
    }
  }

  /// Maximum number of folders (the LS170 app allows 5).
  final int maxFolders;

  final String Function() _id;
  final DateTime Function() _clock;
  final Map<String, ColorFolder> _folders = {};
  final Map<String, MyColor> _colors = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String _validName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const ColorStorageException('Name must not be empty');
    return trimmed;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<ColorFolder>> getFolders() async =>
      _folders.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<ColorFolder> createFolder(String name) async {
    if (_folders.length >= maxFolders) {
      throw ColorStorageException('At most $maxFolders folders are allowed');
    }
    final folder = ColorFolder(id: _id(), name: _validName(name), createdAt: _clock());
    _folders[folder.id] = folder;
    _changed();
    return folder;
  }

  @override
  Future<ColorFolder> renameFolder(String folderId, String name) async {
    final folder = _folders[folderId];
    if (folder == null) throw ColorStorageException('Unknown folder $folderId');
    final renamed = folder.rename(_validName(name));
    _folders[folderId] = renamed;
    _changed();
    return renamed;
  }

  @override
  Future<void> deleteFolders(Iterable<String> folderIds) async {
    final ids = folderIds.toSet();
    _folders.removeWhere((id, _) => ids.contains(id));
    _colors.removeWhere((_, c) => ids.contains(c.folderId));
    _changed();
  }

  @override
  Future<List<MyColor>> getColors(String folderId) async {
    if (!_folders.containsKey(folderId)) throw ColorStorageException('Unknown folder $folderId');
    return [
      for (final c in _colors.values)
        if (c.folderId == folderId) c,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<MyColor> addColor(
    String folderId, {
    required String name,
    required Lab lab,
    ColorMeasurement? measurement,
    String? chartCode,
    DateTime? createdAt,
  }) async {
    if (!_folders.containsKey(folderId)) throw ColorStorageException('Unknown folder $folderId');
    final color = MyColor(
      id: _id(),
      folderId: folderId,
      name: _validName(name),
      createdAt: createdAt ?? measurement?.timestamp ?? _clock(),
      lab: lab,
      measurement: measurement,
      chartCode: chartCode,
    );
    _colors[color.id] = color;
    _changed();
    return color;
  }

  @override
  Future<MyColor> renameColor(String colorId, String name) async {
    final color = _colors[colorId];
    if (color == null) throw ColorStorageException('Unknown color $colorId');
    final renamed = color.copyWith(name: _validName(name));
    _colors[colorId] = renamed;
    _changed();
    return renamed;
  }

  @override
  Future<void> deleteColors(Iterable<String> colorIds) async {
    final ids = colorIds.toSet();
    _colors.removeWhere((id, _) => ids.contains(id));
    _changed();
  }

  @override
  Future<void> dispose() => _changes.close();
}

/// In-memory [CompareHistoryRepository].
final class InMemoryCompareHistoryRepository implements CompareHistoryRepository {
  /// Creates a repository, optionally pre-filled.
  InMemoryCompareHistoryRepository({
    Iterable<CompareRecord> records = const [],
    this.maxRecords,
    String Function()? idGenerator,
    DateTime Function()? clock,
  }) : _id = idGenerator ?? _defaultId,
       _clock = clock ?? DateTime.now {
    for (final r in records) {
      _records[r.id] = r;
    }
  }

  /// When set, the oldest records are dropped beyond this count.
  final int? maxRecords;

  final String Function() _id;
  final DateTime Function() _clock;
  final Map<String, CompareRecord> _records = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  List<CompareRecord> _sorted() =>
      _records.values.toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<CompareRecord>> getRecords() async => _sorted();

  @override
  Future<CompareRecord> addRecord({
    required ColorReference standard,
    required ColorReference sample,
    DateTime? timestamp,
  }) async {
    final record = CompareRecord(
      id: _id(),
      timestamp: timestamp ?? _clock(),
      standard: standard,
      sample: sample,
    );
    _records[record.id] = record;
    final max = maxRecords;
    if (max != null && _records.length > max) {
      for (final old in _sorted().skip(max)) {
        _records.remove(old.id);
      }
    }
    _changed();
    return record;
  }

  @override
  Future<void> deleteRecords(Iterable<String> recordIds) async {
    final ids = recordIds.toSet();
    _records.removeWhere((id, _) => ids.contains(id));
    _changed();
  }

  @override
  Future<void> clear() async {
    _records.clear();
    _changed();
  }

  @override
  Future<void> dispose() => _changes.close();
}
