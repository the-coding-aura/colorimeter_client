import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'pages/compare_page.dart';
import 'pages/device_page.dart';
import 'pages/history_page.dart';
import 'pages/measure_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.create();
  runApp(ColorimeterExampleApp(state: state));
}

/// Provides [AppState] to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class ColorimeterExampleApp extends StatelessWidget {
  const ColorimeterExampleApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => AppScope(
    state: state,
    child: MaterialApp(
      title: 'LS170 Colorimeter',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF00796B), useMaterial3: true),
      home: const HomePage(),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  StreamSubscription<String>? _messages;
  AppLifecycleListener? _lifecycle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    _messages ??= state.messages.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
    _lifecycle ??= AppLifecycleListener(
      onStateChange: (s) => unawaited(state.client.handleAppLifecycleState(s)),
    );
  }

  @override
  void dispose() {
    unawaited(_messages?.cancel());
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final connected = state.connection.isConnected;
    final pages = const [DevicePage(), MeasurePage(), ComparePage(), HistoryPage()];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          connected
              ? state.client.connectedDevice?.name ?? 'Connected'
              : state.connection.status.name,
        ),
        actions: [
          if (state.battery != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const Icon(Icons.battery_std, size: 20),
                  Text(
                    state.battery!.percent != null
                        ? '${state.battery!.percent}%'
                        : 'raw ${state.battery!.rawValue}',
                  ),
                ],
              ),
            ),
          Icon(
            connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: connected ? Colors.teal : null,
          ),
          const SizedBox(width: 12),
        ],
        bottom: state.busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          state.compareTabActive = i == 2;
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bluetooth_searching), label: 'Device'),
          NavigationDestination(icon: Icon(Icons.colorize), label: 'Scan'),
          NavigationDestination(icon: Icon(Icons.compare), label: 'Compare'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}
