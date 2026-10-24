import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client_example/app_state.dart';
import 'package:colorimeter_client_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('demo mode: scan, connect and measure with the simulated LS170', (tester) async {
    final state = await AppState.create(demo: true, persist: false);
    await tester.pumpWidget(ColorimeterExampleApp(state: state));

    await tester.tap(find.text('Scan for LS170 / LS171'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('LS170A0001'), findsOneWidget);

    await tester.tap(find.text('LS170A0001'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(state.connection.isConnected, isTrue);
    expect(state.battery?.rawValue, 87);

    await tester.tap(find.byIcon(Icons.colorize).last);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(state.lastMeasurement?.source, MeasurementSource.app);
    expect(find.text('Closest chart colors'), findsOneWidget);

    state.simulator!.pressButton();
    await tester.pump(const Duration(seconds: 1));
    expect(state.lastMeasurement?.source, MeasurementSource.deviceButton);

    await tester.tap(find.text('Compare'));
    await tester.pump();
    await tester.tap(find.text('Scan Standard'));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Scan Sample'));
    await tester.pump(const Duration(seconds: 2));
    expect(state.comparison, isNotNull);
    expect(find.textContaining('ΔE*ab'), findsWidgets);
    expect((await state.history.getRecords()).length, 1);

    await state.disconnect();
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 15));
  });
}
