import 'dart:async';

/// Lets pending awaits be aborted from outside.
final class CancelScope {
  /// Creates an active scope.
  CancelScope() {
    // Keeps a cancellation with nobody awaiting from becoming an unhandled
    // error.
    _cancelled.future.ignore();
  }

  final Completer<Never> _cancelled = Completer<Never>();

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled.isCompleted;

  /// Fails every current and future [guard] call with [error].
  void cancel(Object error) {
    if (!_cancelled.isCompleted) _cancelled.completeError(error);
  }

  /// Completes like [future], unless the scope is cancelled first.
  Future<T> guard<T>(Future<T> future) {
    if (isCancelled) {
      future.ignore();
      return _cancelled.future;
    }
    return Future.any<T>([future, _cancelled.future]);
  }

  /// A cancellable delay.
  Future<void> delay(Duration duration) {
    if (duration <= Duration.zero) return guard(Future<void>.value());
    final completer = Completer<void>();
    final timer = Timer(duration, completer.complete);
    return guard(completer.future).whenComplete(timer.cancel);
  }
}

/// Runs async tasks one at a time, in call order.
final class SerialQueue {
  Future<void> _tail = Future<void>.value();

  /// Schedules [task] after every previously scheduled task.
  Future<T> run<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
