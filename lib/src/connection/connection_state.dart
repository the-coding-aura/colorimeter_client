import 'package:flutter/foundation.dart';

import '../exceptions.dart';

/// Connection lifecycle states.
enum ColorimeterConnectionStatus {
  /// No device connected (initial and final state).
  disconnected,

  /// A user-requested connection is being established.
  connecting,

  /// Connected, notifications enabled, ready for commands.
  connected,

  /// The link dropped and the [ReconnectPolicy] is trying again.
  reconnecting,

  /// A user-requested disconnect is in progress.
  disconnecting,
}

/// Snapshot published on `ColorimeterClient.connectionStates`.
@immutable
final class ColorimeterConnectionState {
  /// Creates a state.
  const ColorimeterConnectionState({
    required this.status,
    this.deviceId,
    this.attempt = 0,
    this.error,
    this.mtu,
  });

  /// The initial state.
  static const ColorimeterConnectionState initial = ColorimeterConnectionState(
    status: ColorimeterConnectionStatus.disconnected,
  );

  /// Lifecycle state.
  final ColorimeterConnectionStatus status;

  /// Device this state refers to.
  final String? deviceId;

  /// Attempt number within the current connect or reconnect cycle (1-based),
  /// or 0 when not applicable.
  final int attempt;

  /// Why the device is disconnected / reconnecting, if it was not requested
  /// by the user.
  final ColorimeterException? error;

  /// Negotiated MTU while connected, if known.
  final int? mtu;

  /// Whether commands can be sent.
  bool get isConnected => status == ColorimeterConnectionStatus.connected;

  @override
  bool operator ==(Object other) =>
      other is ColorimeterConnectionState &&
      other.status == status &&
      other.deviceId == deviceId &&
      other.attempt == attempt &&
      other.error == error &&
      other.mtu == mtu;

  @override
  int get hashCode => Object.hash(status, deviceId, attempt, error, mtu);

  @override
  String toString() =>
      'ColorimeterConnectionState(${status.name}, $deviceId, attempt: $attempt'
      '${error == null ? '' : ', error: $error'})';
}

/// Bounded automatic reconnection after an unexpected disconnect.
///
/// Delays grow geometrically: `initialDelay * backoffFactor^(n-1)`, capped at
/// [maxDelay]. The attempt budget only refills after the link has stayed up
/// for [stableConnectionDuration], so a device that keeps dropping right
/// after connecting cannot cause an endless loop.
@immutable
final class ReconnectPolicy {
  /// Creates a policy.
  const ReconnectPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.backoffFactor = 2,
    this.maxDelay = const Duration(seconds: 10),
    this.stableConnectionDuration = const Duration(seconds: 30),
  }) : assert(maxAttempts >= 0, 'maxAttempts must be >= 0'),
       assert(backoffFactor >= 1, 'backoffFactor must be >= 1');

  /// No automatic reconnection (the default).
  static const ReconnectPolicy disabled = ReconnectPolicy(maxAttempts: 0);

  /// Maximum attempts per reconnect cycle; 0 disables reconnection.
  final int maxAttempts;

  /// Delay before the first attempt.
  final Duration initialDelay;

  /// Multiplier applied to the delay after each attempt.
  final double backoffFactor;

  /// Upper bound of the delay.
  final Duration maxDelay;

  /// How long a connection must last before the attempt budget is refilled.
  final Duration stableConnectionDuration;

  /// Whether reconnection is enabled.
  bool get isEnabled => maxAttempts > 0;

  /// Delay before attempt [attempt] (1-based).
  Duration delayForAttempt(int attempt) {
    var micros = initialDelay.inMicroseconds.toDouble();
    for (var i = 1; i < attempt; i++) {
      micros *= backoffFactor;
    }
    final capped = micros.clamp(0, maxDelay.inMicroseconds.toDouble());
    return Duration(microseconds: capped.round());
  }
}
