import 'dart:async';

import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'C0:FF:EE:17:00:01';

ColorimeterConnectionManager _manager(
  FakeColorimeterTransport transport, {
  Duration connectTimeout = const Duration(seconds: 2),
  ReconnectPolicy policy = ReconnectPolicy.disabled,
  DateTime Function()? clock,
}) => ColorimeterConnectionManager(
  transport: transport,
  connectTimeout: connectTimeout,
  postConnectDelay: const Duration(milliseconds: 5),
  disconnectTimeout: const Duration(milliseconds: 200),
  reconnectPolicy: policy,
  clock: clock,
);

const _fastPolicy = ReconnectPolicy(
  maxAttempts: 3,
  initialDelay: Duration(milliseconds: 5),
  maxDelay: Duration(milliseconds: 20),
);

Future<void> _settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Subscribes to [ColorimeterConnectionManager.states] before returning so the
/// caller can trigger an action without missing the event. The current state
/// is not replayed.
Future<ColorimeterConnectionState> _nextState(
  ColorimeterConnectionManager m,
  bool Function(ColorimeterConnectionState state) match, {
  Object? reason,
}) => m.states
    .firstWhere(match)
    .timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TestFailure('${reason ?? 'state'} not reached; still ${m.state}'),
    );

void main() {
  late FakeColorimeterTransport transport;
  late List<ColorimeterConnectionStatus> statuses;

  setUp(() {
    transport = FakeColorimeterTransport();
    statuses = [];
  });

  ColorimeterConnectionManager track(ColorimeterConnectionManager m) {
    m.states.listen((s) => statuses.add(s.status));
    return m;
  }

  test('connect then disconnect', () async {
    final m = track(_manager(transport));
    await m.connect(_id);
    expect(m.isConnected, isTrue);
    expect(m.state.mtu, 247);
    expect(m.deviceId, _id);
    await m.disconnect();
    await _settle();
    expect(statuses, [
      ColorimeterConnectionStatus.connecting,
      ColorimeterConnectionStatus.connected,
      ColorimeterConnectionStatus.disconnecting,
      ColorimeterConnectionStatus.disconnected,
    ]);
    expect(transport.disconnectCalls, [_id]);
    await m.dispose();
  });

  test('duplicate connect calls share one GATT operation', () async {
    transport.connectDelay = const Duration(milliseconds: 20);
    final m = _manager(transport);
    final a = m.connect(_id);
    final b = m.connect(_id);
    await Future.wait([a, b]);
    expect(transport.connectCalls, [_id]);
    await m.connect(_id);
    expect(transport.connectCalls, [_id], reason: 'already connected');
    expect(m.totalAttempts, 1);
    await m.dispose();
  });

  test('connection timeout', () async {
    transport.connectBehavior = FakeConnectBehavior.hang;
    final m = _manager(transport, connectTimeout: const Duration(milliseconds: 50));
    await expectLater(
      m.connect(_id),
      throwsA(
        isA<ColorimeterTimeoutException>().having(
          (e) => e.operation,
          'operation',
          ColorimeterOperation.connect,
        ),
      ),
    );
    expect(m.state.status, ColorimeterConnectionStatus.disconnected);
    expect(m.state.error, isA<ColorimeterTimeoutException>());
    expect(transport.disconnectCalls, [_id], reason: 'half-open GATT released');
    await m.dispose();
  });

  test('connection failure', () async {
    transport.connectBehavior = FakeConnectBehavior.fail;
    final m = _manager(transport);
    await expectLater(
      m.connect(_id),
      throwsA(isA<ColorimeterConnectionException>().having((e) => e.gattStatus, 'status', 133)),
    );
    expect(m.state.error, isA<ColorimeterConnectionException>());
    await m.dispose();
  });

  test('disconnect cancels a pending connect', () async {
    transport.connectBehavior = FakeConnectBehavior.hang;
    final m = _manager(transport);
    final cancelled = expectLater(m.connect(_id), throwsA(isA<OperationCancelledException>()));
    await _settle(5);
    await m.disconnect();
    await cancelled;
    expect(m.state.status, ColorimeterConnectionStatus.disconnected);
    await m.dispose();
  });

  test('connecting to another device closes the first', () async {
    final m = _manager(transport);
    await m.connect('A');
    await m.connect('B');
    expect(transport.disconnectCalls, ['A']);
    expect(m.deviceId, 'B');
    await m.dispose();
  });

  test('unexpected disconnect without reconnect policy', () async {
    final m = track(_manager(transport));
    await m.connect(_id);
    final gone = _nextState(m, (s) => s.status == ColorimeterConnectionStatus.disconnected);
    transport.simulateDisconnect(_id, gattStatus: 8);
    await gone;
    expect(
      m.state.error,
      isA<DeviceDisconnectedException>().having((e) => e.gattStatus, 'status', 8),
    );
    expect(transport.connectCalls, hasLength(1));
    await m.dispose();
  });

  test('reconnects after an unexpected disconnect', () async {
    final m = track(_manager(transport, policy: _fastPolicy));
    await m.connect(_id);
    transport.connectBehaviorQueue.addAll([FakeConnectBehavior.fail]);
    final reconnected = _nextState(m, (s) => s.isConnected);
    transport.simulateDisconnect(_id);
    await reconnected;
    expect(transport.connectCalls, hasLength(3));
    expect(statuses, contains(ColorimeterConnectionStatus.reconnecting));
    await m.dispose();
  });

  test('reconnection is bounded', () async {
    final m = _manager(transport, policy: _fastPolicy);
    await m.connect(_id);
    transport.connectBehavior = FakeConnectBehavior.fail;
    final gone = _nextState(m, (s) => s.status == ColorimeterConnectionStatus.disconnected);
    transport.simulateDisconnect(_id);
    await gone;
    expect(m.state.error, isA<ColorimeterConnectionException>());
    expect(transport.connectCalls, hasLength(1 + 3));
    await m.dispose();
  });

  test('a flapping link cannot reconnect forever', () async {
    final m = _manager(transport, policy: _fastPolicy);
    await m.connect(_id);
    for (var i = 0; i < 6; i++) {
      if (m.state.status == ColorimeterConnectionStatus.disconnected) break;
      final settled = _nextState(
        m,
        (s) => s.isConnected || s.status == ColorimeterConnectionStatus.disconnected,
        reason: 'flap $i',
      );
      transport.simulateDisconnect(_id);
      await settled;
    }
    expect(m.state.status, ColorimeterConnectionStatus.disconnected);
    expect(transport.connectCalls, hasLength(1 + 3));
    await m.dispose();
  });

  test('the budget refills after a stable connection', () async {
    var now = DateTime(2026);
    final m = _manager(transport, policy: _fastPolicy, clock: () => now);
    await m.connect(_id);
    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(minutes: 1));
      final reconnected = _nextState(m, (s) => s.isConnected, reason: 'cycle $i');
      transport.simulateDisconnect(_id);
      await reconnected;
    }
    expect(transport.connectCalls, hasLength(1 + 5));
    await m.dispose();
  });

  test('disconnect stops a reconnect loop', () async {
    final m = _manager(
      transport,
      policy: const ReconnectPolicy(maxAttempts: 5, initialDelay: Duration(milliseconds: 50)),
    );
    await m.connect(_id);
    final reconnecting = _nextState(m, (s) => s.status == ColorimeterConnectionStatus.reconnecting);
    transport.simulateDisconnect(_id);
    await reconnecting;
    await m.disconnect();
    expect(m.state.status, ColorimeterConnectionStatus.disconnected);
    expect(transport.connectCalls, hasLength(1));
    await m.dispose();
  });

  test('backoff delays are capped', () {
    const p = ReconnectPolicy(
      initialDelay: Duration(seconds: 1),
      backoffFactor: 2,
      maxDelay: Duration(seconds: 5),
    );
    expect(p.delayForAttempt(1), const Duration(seconds: 1));
    expect(p.delayForAttempt(2), const Duration(seconds: 2));
    expect(p.delayForAttempt(3), const Duration(seconds: 4));
    expect(p.delayForAttempt(4), const Duration(seconds: 5));
    expect(ReconnectPolicy.disabled.isEnabled, isFalse);
  });

  test('dispose disconnects, closes the stream and rejects new connects', () async {
    final m = _manager(transport);
    await m.connect(_id);
    final done = Completer<void>();
    m.states.listen(null, onDone: done.complete);
    await m.dispose();
    await done.future.timeout(const Duration(seconds: 1));
    expect(transport.disconnectCalls, [_id]);
    expect(() => m.connect(_id), throwsStateError);
  });
}
