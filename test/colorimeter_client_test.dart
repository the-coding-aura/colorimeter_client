import 'package:flutter_test/flutter_test.dart';
import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:colorimeter_client/colorimeter_client_platform_interface.dart';
import 'package:colorimeter_client/colorimeter_client_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockColorimeterClientPlatform
    with MockPlatformInterfaceMixin
    implements ColorimeterClientPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final ColorimeterClientPlatform initialPlatform = ColorimeterClientPlatform.instance;

  test('$MethodChannelColorimeterClient is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelColorimeterClient>());
  });

  test('getPlatformVersion', () async {
    ColorimeterClient colorimeterClientPlugin = ColorimeterClient();
    MockColorimeterClientPlatform fakePlatform = MockColorimeterClientPlatform();
    ColorimeterClientPlatform.instance = fakePlatform;

    expect(await colorimeterClientPlugin.getPlatformVersion(), '42');
  });
}
