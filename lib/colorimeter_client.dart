
import 'colorimeter_client_platform_interface.dart';

class ColorimeterClient {
  Future<String?> getPlatformVersion() {
    return ColorimeterClientPlatform.instance.getPlatformVersion();
  }
}
