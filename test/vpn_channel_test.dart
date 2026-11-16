import 'package:catvp/services/vpn_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.catvpn.nord/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('an in-progress handshake never reports a protected connection',
      () async {
    for (final state in ['CONNECTING', 'DISCONNECTING']) {
      messenger.setMockMethodCallHandler(
          channel, (_) async => {'state': state});
      final status = await VpnChannel.getStatus();
      expect(status.isConnected, isFalse);
      expect(status.isTransitioning, isTrue);
      expect(status.supportsTrafficStats, isFalse);
    }
    messenger.setMockMethodCallHandler(channel, (_) async => {'state': 'UP'});
    expect((await VpnChannel.getStatus()).isConnected, isTrue);
  });

  test('a native status failure stays distinct from a disconnected tunnel',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'VPN_LOAD');
    });
    expect((await VpnChannel.getStatus()).isAvailable, isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => {'state': 'DOWN'});
    final status = await VpnChannel.getStatus();
    expect(status.isAvailable, isTrue);
    expect(status.isConnected, isFalse);
  });

  test('background API server selection is exposed to the UI', () async {
    messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
              'state': 'UP',
              'serverHostname': 'vn53.nordvpn.com',
              'countryId': 234,
            });
    final status = await VpnChannel.getStatus();
    expect(status.serverHostname, 'vn53.nordvpn.com');
    expect(status.countryId, 234);
  });

  test('connect preserves the country for later API rotation', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'connect');
      expect((call.arguments as Map)['countryId'], 234);
      return 'UP';
    });
    expect(
        await VpnChannel.connect(
            wgQuickConfig: '',
            hostname: 'vn53.nordvpn.com',
            username: 'user',
            password: 'pass',
            countryId: 234),
        'UP');
  });
}
