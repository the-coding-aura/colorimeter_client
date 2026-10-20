import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'colorimeter_client_method_channel.dart';

abstract class ColorimeterClientPlatform extends PlatformInterface {
  /// Constructs a ColorimeterClientPlatform.
  ColorimeterClientPlatform() : super(token: _token);

  static final Object _token = Object();

  static ColorimeterClientPlatform _instance = MethodChannelColorimeterClient();

  /// The default instance of [ColorimeterClientPlatform] to use.
  ///
  /// Defaults to [MethodChannelColorimeterClient].
  static ColorimeterClientPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ColorimeterClientPlatform] when
  /// they register themselves.
  static set instance(ColorimeterClientPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
