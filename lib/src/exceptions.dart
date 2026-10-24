import 'transport/transport_types.dart';

/// Operations that can time out or be cancelled.
enum ColorimeterOperation {
  /// BLE discovery.
  scan,

  /// Establishing a GATT connection.
  connect,

  /// Tearing down a GATT connection.
  disconnect,

  /// A color measurement (AB44).
  measure,

  /// White-tile calibration (AB20 2E).
  calibrate,

  /// Battery query (AB20 0B).
  battery,

  /// Device information query (AB40).
  deviceInfo,
}

/// Base class of every exception thrown by this package.
///
/// The hierarchy is sealed so that callers can `switch` exhaustively over the
/// failure kinds.
sealed class ColorimeterException implements Exception {
  const ColorimeterException(this.message, {this.cause});

  /// Human-readable description of the failure.
  final String message;

  /// The underlying error, if any (for example a `PlatformException`).
  final Object? cause;

  @override
  String toString() {
    final name = switch (this) {
      BluetoothUnavailableException() => 'BluetoothUnavailableException',
      BluetoothPermissionException() => 'BluetoothPermissionException',
      ScanFailedException() => 'ScanFailedException',
      ColorimeterConnectionException() => 'ColorimeterConnectionException',
      GattSetupException() => 'GattSetupException',
      DeviceDisconnectedException() => 'DeviceDisconnectedException',
      NotConnectedException() => 'NotConnectedException',
      ColorimeterTimeoutException() => 'ColorimeterTimeoutException',
      OperationCancelledException() => 'OperationCancelledException',
      WriteFailedException() => 'WriteFailedException',
      ColorimeterProtocolException() => 'ColorimeterProtocolException',
      ColorDataFormatException() => 'ColorDataFormatException',
      ColorDataModelMismatchException() => 'ColorDataModelMismatchException',
      ColorStorageException() => 'ColorStorageException',
    };
    return cause == null ? '$name: $message' : '$name: $message ($cause)';
  }
}

/// Bluetooth is missing, switched off or not usable on this device.
final class BluetoothUnavailableException extends ColorimeterException {
  /// Creates the exception for the given adapter [state].
  const BluetoothUnavailableException(super.message, {required this.state, super.cause});

  /// Adapter state observed when the operation was attempted.
  final BluetoothAdapterState state;
}

/// Required runtime permissions are not granted.
final class BluetoothPermissionException extends ColorimeterException {
  /// Creates the exception listing the [missingPermissions].
  const BluetoothPermissionException(
    super.message, {
    this.missingPermissions = const [],
    super.cause,
  });

  /// Android permission names that are not granted.
  final List<String> missingPermissions;
}

/// The platform BLE scanner reported a failure.
final class ScanFailedException extends ColorimeterException {
  /// Creates the exception with the Android `ScanCallback` [errorCode].
  const ScanFailedException(super.message, {this.errorCode, super.cause});

  /// Android `ScanCallback.SCAN_FAILED_*` code, when available.
  final int? errorCode;
}

/// A GATT connection could not be established or was refused.
final class ColorimeterConnectionException extends ColorimeterException {
  /// Creates the exception for [deviceId].
  const ColorimeterConnectionException(
    super.message, {
    this.deviceId,
    this.gattStatus,
    super.cause,
  });

  /// The device that failed to connect.
  final String? deviceId;

  /// Android GATT status code (for example 133), when available.
  final int? gattStatus;
}

/// The device connected but its UART characteristics or notifications could
/// not be set up.
final class GattSetupException extends ColorimeterException {
  /// Creates the exception.
  const GattSetupException(super.message, {super.cause});
}

/// The device disconnected while an operation was in progress, or
/// unexpectedly while connected.
final class DeviceDisconnectedException extends ColorimeterException {
  /// Creates the exception for [deviceId].
  const DeviceDisconnectedException(super.message, {this.deviceId, this.gattStatus, super.cause});

  /// The device that disconnected.
  final String? deviceId;

  /// Android GATT status code reported with the disconnect, when available.
  final int? gattStatus;
}

/// An operation that needs a connected device was called while disconnected.
final class NotConnectedException extends ColorimeterException {
  /// Creates the exception.
  const NotConnectedException([super.message = 'No colorimeter is connected']);
}

/// An operation did not complete within its time limit.
final class ColorimeterTimeoutException extends ColorimeterException {
  /// Creates the exception for [operation] after [timeout].
  const ColorimeterTimeoutException(
    super.message, {
    required this.operation,
    required this.timeout,
  });

  /// The operation that timed out.
  final ColorimeterOperation operation;

  /// The time limit that was exceeded.
  final Duration timeout;
}

/// An operation was cancelled by the caller (for example by `disconnect()`
/// while connecting, or `cancelPendingOperation()` during a measurement).
final class OperationCancelledException extends ColorimeterException {
  /// Creates the exception for [operation].
  const OperationCancelledException(super.message, {required this.operation});

  /// The cancelled operation.
  final ColorimeterOperation operation;
}

/// Writing a command to the device failed.
final class WriteFailedException extends ColorimeterException {
  /// Creates the exception.
  const WriteFailedException(super.message, {super.cause});
}

/// A frame from the device could not be decoded.
final class ColorimeterProtocolException extends ColorimeterException {
  /// Creates the exception.
  const ColorimeterProtocolException(super.message, {super.cause});
}

/// Imported color data is not valid JSON or does not follow the export
/// schema.
final class ColorDataFormatException extends ColorimeterException {
  /// Creates the exception.
  const ColorDataFormatException(super.message, {super.cause});
}

/// Imported color data was measured with a different colorimeter model.
final class ColorDataModelMismatchException extends ColorimeterException {
  /// Creates the exception.
  const ColorDataModelMismatchException(
    super.message, {
    required this.expectedModel,
    required this.actualModel,
  });

  /// The model the import was restricted to.
  final String expectedModel;

  /// The model recorded in the imported data.
  final String actualModel;
}

/// A storage repository rejected an operation (for example the folder limit
/// was reached or an id does not exist).
final class ColorStorageException extends ColorimeterException {
  /// Creates the exception.
  const ColorStorageException(super.message, {super.cause});
}
