import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemoryMyColorsRepository', () {
    late InMemoryMyColorsRepository repo;
    var t = DateTime.utc(2026, 1, 1);
    var n = 0;

    setUp(() {
      t = DateTime.utc(2026, 1, 1);
      n = 0;
      repo = InMemoryMyColorsRepository(
        idGenerator: () => 'id${n++}',
        clock: () => t = t.add(const Duration(seconds: 1)),
      );
    });

    tearDown(() => repo.dispose());

    test('folders: create, rename, limit, delete cascades', () async {
      final a = await repo.createFolder(' Paints ');
      expect(a.name, 'Paints');
      for (var i = 0; i < 4; i++) {
        await repo.createFolder('F$i');
      }
      await expectLater(repo.createFolder('sixth'), throwsA(isA<ColorStorageException>()));
      await expectLater(repo.createFolder('  '), throwsA(isA<ColorStorageException>()));

      expect((await repo.renameFolder(a.id, 'Walls')).name, 'Walls');
      await repo.addColor(a.id, name: 'White', lab: const Lab(95, 0, 1));
      await repo.deleteFolders([a.id]);
      expect(await repo.getFolders(), hasLength(4));
      await expectLater(repo.getColors(a.id), throwsA(isA<ColorStorageException>()));
    });

    test('colors: add, rename, delete, ordering and change events', () async {
      final f = await repo.createFolder('F');
      var changes = 0;
      final sub = repo.changes.listen((_) => changes++);
      final m = Ls170Parser.parseColorResult(
        Ls170Frame(Ls170FrameEncoder.colorResult(lab: const Lab(50, 1, 2))),
        timestamp: DateTime.utc(2025),
      )!;
      final c1 = await repo.addColor(f.id, name: 'Measured', lab: m.lab, measurement: m);
      final c2 = await repo.addColor(
        f.id,
        name: 'Chart',
        lab: const Lab(60, 0, 0),
        chartCode: 'G-60',
      );
      expect(c1.createdAt, DateTime.utc(2025), reason: 'defaults to the measurement time');
      expect((await repo.getColors(f.id)).map((c) => c.id), [c1.id, c2.id]);
      expect((await repo.renameColor(c2.id, 'Grey')).name, 'Grey');
      await repo.deleteColors([c1.id]);
      expect((await repo.getColors(f.id)).single.name, 'Grey');
      await expectLater(
        repo.addColor('nope', name: 'x', lab: const Lab(0, 0, 0)),
        throwsA(isA<ColorStorageException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, 4);
      await sub.cancel();
    });
  });

  group('InMemoryCompareHistoryRepository', () {
    test('newest first, recomputed with the current settings, bounded', () async {
      final repo = InMemoryCompareHistoryRepository(maxRecords: 2);
      const std = ColorReference(lab: Lab(50, 0, 0), name: 'Std');
      await repo.addRecord(
        standard: std,
        sample: const ColorReference(lab: Lab(51, 0, 0)),
        timestamp: DateTime.utc(2026, 1, 1),
      );
      await repo.addRecord(
        standard: std,
        sample: const ColorReference(lab: Lab(53, 0, 0)),
        timestamp: DateTime.utc(2026, 1, 3),
      );
      await repo.addRecord(
        standard: std,
        sample: const ColorReference(lab: Lab(52, 0, 0)),
        timestamp: DateTime.utc(2026, 1, 2),
      );
      final records = await repo.getRecords();
      expect(records.map((r) => r.sample.lab.l), [53, 52]);

      final strict = QcSettings(threshold: 2.5);
      expect(records.map((r) => r.evaluate(strict).verdict), [QcVerdict.ng, QcVerdict.pass]);
      final cmc = QcSettings(formula: DeltaEFormula.cmc2To1, threshold: 5);
      expect(records.first.evaluate(cmc).deltaE, isNot(closeTo(3, 1e-6)));

      await repo.deleteRecords([records.first.id]);
      expect(await repo.getRecords(), hasLength(1));
      await repo.clear();
      expect(await repo.getRecords(), isEmpty);
      await repo.dispose();
    });
  });

  group('ColorDataCodec', () {
    final folder = ColorFolder(id: 'f1', name: 'Walls', createdAt: DateTime.utc(2026));
    final measurement = Ls170Parser.parseColorResult(
      Ls170Frame(Ls170FrameEncoder.colorResult(lab: const Lab(92.59, -0.29, 0.55))),
      timestamp: DateTime.utc(2026, 2, 3, 4, 5, 6),
    )!;
    final color = MyColor(
      id: 'c1',
      folderId: 'f1',
      name: 'Ivory',
      createdAt: DateTime.utc(2026, 2, 3),
      lab: measurement.lab,
      measurement: measurement,
    );

    test('My Colors round trip', () {
      final json = ColorDataCodec.encodeMyColors(
        model: ColorimeterModel.ls170,
        folders: [folder],
        colors: [color],
        exportedAt: DateTime.utc(2026, 3),
      );
      final decoded = ColorDataCodec.decodeMyColors(json, expectedModel: ColorimeterModel.ls170);
      expect(decoded.model, ColorimeterModel.ls170);
      expect(decoded.exportedAt, DateTime.utc(2026, 3));
      expect(decoded.folders.single.name, 'Walls');
      final c = decoded.colors.single;
      expect(c.name, 'Ivory');
      expect(c.lab, measurement.lab);
      expect(c.measurement!.luv, measurement.luv);
      expect(c.measurement!.rgb, measurement.rgb);
      expect(c.measurement!.timestamp, measurement.timestamp);
    });

    test('Compare History round trip', () {
      final record = CompareRecord(
        id: 'r1',
        timestamp: DateTime.utc(2026, 5),
        standard: ColorReference.fromMeasurement(measurement, name: 'Std'),
        sample: const ColorReference(lab: Lab(90, 0, 0)),
      );
      final json = ColorDataCodec.encodeCompareHistory(
        model: ColorimeterModel.ls171,
        records: [record],
      );
      final decoded = ColorDataCodec.decodeCompareHistory(
        json,
        expectedModel: ColorimeterModel.ls171,
      );
      final r = decoded.records.single;
      expect(r.standard.name, 'Std');
      expect(r.standard.measurement, isNotNull);
      expect(r.sample.lab, const Lab(90, 0, 0));
      expect(r.evaluate(QcSettings()).deltaE, closeTo(record.evaluate(QcSettings()).deltaE, 1e-12));
    });

    test('rejects data from another model', () {
      final json = ColorDataCodec.encodeMyColors(
        model: ColorimeterModel.ls171,
        folders: [folder],
        colors: [color],
      );
      expect(
        () => ColorDataCodec.decodeMyColors(json, expectedModel: ColorimeterModel.ls170),
        throwsA(
          isA<ColorDataModelMismatchException>()
              .having((e) => e.expectedModel, 'expected', 'LS170')
              .having((e) => e.actualModel, 'actual', 'LS171'),
        ),
      );
    });

    test('rejects malformed input', () {
      final Matcher fmt = throwsA(isA<ColorDataFormatException>());
      void decode(String s) =>
          ColorDataCodec.decodeMyColors(s, expectedModel: ColorimeterModel.ls170);
      expect(() => decode('not json'), fmt);
      expect(() => decode('[]'), fmt);
      expect(() => decode('{"format":"other","version":1}'), fmt);
      expect(() => decode('{"format":"colorimeter_client/my_colors","version":99}'), fmt);
      expect(
        () => decode(
          '{"format":"colorimeter_client/my_colors","version":1,"model":"LS170",'
          '"exportedAt":"2026-01-01T00:00:00Z","folders":[],"colors":[{"id":1}]}',
        ),
        fmt,
      );
      expect(
        () => ColorDataCodec.decodeCompareHistory(
          ColorDataCodec.encodeMyColors(model: ColorimeterModel.ls170, folders: [], colors: []),
          expectedModel: ColorimeterModel.ls170,
        ),
        fmt,
        reason: 'a My Colors file is not a Compare History file',
      );
    });

    test('imported data restores into an in-memory repository', () async {
      final json = ColorDataCodec.encodeMyColors(
        model: ColorimeterModel.ls170,
        folders: [folder],
        colors: [color],
      );
      final bundle = ColorDataCodec.decodeMyColors(json, expectedModel: ColorimeterModel.ls170);
      final repo = InMemoryMyColorsRepository(folders: bundle.folders, colors: bundle.colors);
      expect((await repo.getColors('f1')).single.name, 'Ivory');
      expect(
        () => InMemoryMyColorsRepository(colors: bundle.colors),
        throwsA(isA<ColorStorageException>()),
      );
      await repo.dispose();
    });
  });
}
