import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class VpnStatusSnapshot {
  final bool isConnected;
  final int rxBytes;
  final int txBytes;
  final bool wasRevoked;
  final bool isTransitioning;
  final bool isAvailable;
  final bool supportsTrafficStats;
  final String serverHostname;
  final int? countryId;

  const VpnStatusSnapshot({
    required this.isConnected,
    required this.rxBytes,
    required this.txBytes,
    this.wasRevoked = false,
    this.isTransitioning = false,
    this.isAvailable = true,
    this.supportsTrafficStats = true,
    this.serverHostname = '',
    this.countryId,
  });
}

class VpnChannel {
  static const MethodChannel _channel = MethodChannel('com.catvpn.nord/vpn');
  static final Map<String, String> _memoryPrefs = {};

  static bool get isMobileSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static bool get isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<bool> prepareVpn() async {
    if (!isMobileSupported) return false;
    final granted = await _channel.invokeMethod<bool>('prepareVpn');
    return granted ?? false;
  }

  static Future<String> connect({
    required String wgQuickConfig,
    String hostname = '',
    String username = '',
    String password = '',
    int? countryId,
  }) async {
    if (!isMobileSupported) {
      throw PlatformException(
        code: 'UNSUPPORTED',
        message: 'Kết nối VPN trực tiếp hỗ trợ trên Android và iOS.',
      );
    }
    final state = await _channel.invokeMethod<String>(
      'connect',
      {
        'config': wgQuickConfig,
        'hostname': hostname,
        'username': username,
        'password': password,
        if (countryId != null) 'countryId': countryId,
      },
    );
    return state ?? 'DOWN';
  }

  static Future<bool> shareWireGuardConfig({
    required String fileName,
    required String wgQuickConfig,
  }) async {
    if (!isIOS) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'shareWireGuardFile',
        {
          'fileName': fileName,
          'config': wgQuickConfig,
        },
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> disconnect() async {
    if (!isMobileSupported) return 'DOWN';
    final state = await _channel.invokeMethod<String>('disconnect');
    return state ?? 'DOWN';
  }

  static Future<VpnStatusSnapshot> getStatus() async {
    if (!isMobileSupported) {
      return const VpnStatusSnapshot(
          isConnected: false, rxBytes: 0, txBytes: 0);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (raw == null) {
        return const VpnStatusSnapshot(
            isConnected: false, rxBytes: 0, txBytes: 0, isAvailable: false);
      }
      final state = (raw['state'] as String?) ?? 'DOWN';
      final rx = (raw['rxBytes'] as num?)?.toInt() ?? 0;
      final tx = (raw['txBytes'] as num?)?.toInt() ?? 0;
      final revoked = (raw['revoked'] as bool?) ?? false;
      return VpnStatusSnapshot(
        isConnected: state == 'UP',
        rxBytes: rx,
        txBytes: tx,
        wasRevoked: revoked,
        isTransitioning: state == 'CONNECTING' || state == 'DISCONNECTING',
        supportsTrafficStats: (raw['supportsTrafficStats'] as bool?) ?? !isIOS,
        serverHostname: (raw['serverHostname'] as String?) ?? '',
        countryId: (raw['countryId'] as num?)?.toInt(),
      );
    } catch (_) {
      return const VpnStatusSnapshot(
          isConnected: false, rxBytes: 0, txBytes: 0, isAvailable: false);
    }
  }

  static Future<void> savePref(String key, String value) async {
    _memoryPrefs[key] = value;
    if (!isMobileSupported) return;
    try {
      await _channel.invokeMethod('savePref', {'key': key, 'value': value});
    } catch (_) {}
  }

  static Future<Map<String, String>> loadPrefs() async {
    if (!isMobileSupported) return Map<String, String>.from(_memoryPrefs);
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('loadPrefs');
      if (raw == null) return {};
      return raw.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    } catch (_) {
      return {};
    }
  }
}
