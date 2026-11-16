import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/nord_models.dart';
import 'screens/server_picker_sheet.dart';
import 'screens/settings_tools_sheet.dart';
import 'services/nord_api_service.dart';
import 'services/nord_seed_data.dart';
import 'services/vpn_channel.dart';
import 'widgets/cat_power_orb.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF090C18),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const CatVpnApp());
}

class CatVpnApp extends StatelessWidget {
  const CatVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CatVPN Nord',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090C18),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F5A0),
          secondary: Color(0xFF7C5CFF),
          surface: Color(0xFF13182E),
        ),
      ),
      home: const CatVpnHomeScreen(),
    );
  }
}

class CatVpnHomeScreen extends StatefulWidget {
  const CatVpnHomeScreen({super.key});

  @override
  State<CatVpnHomeScreen> createState() => _CatVpnHomeScreenState();
}

class _CatVpnHomeScreenState extends State<CatVpnHomeScreen>
    with WidgetsBindingObserver {
  VpnConnectionPhase _phase = VpnConnectionPhase.disconnected;
  String _accessToken = NordApiService.defaultAccessToken;
  bool _useCloudflareDns = false;

  NordAccountCredentials? _credentials;
  List<NordCountry> _countries = const [];
  NordCountry? _selectedCountry; // null = Smart Fastest
  NordServer? _currentServer;
  String _liveServerHostname = '';
  ExitIpInfo _exitIp = const ExitIpInfo(ip: 'Đang kiểm tra...');
  bool _refreshingIp = false;
  String? _statusHint;

  int _rxBytes = 0;
  int _txBytes = 0;
  int _rxSpeedBps = 0;
  int _txSpeedBps = 0;
  DateTime? _connectedSince;
  Timer? _telemetryTimer;
  bool _pollInFlight = false;
  bool _vpnOperationInProgress = false;
  bool _supportsTrafficStats = !VpnChannel.isIOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
    _startTelemetry();
  }

  void _startTelemetry() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollTelemetry(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _telemetryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTelemetry();
      unawaited(_pollTelemetry());
    } else {
      _telemetryTimer?.cancel();
    }
  }

  Future<void> _bootstrap() async {
    // Instant 0ms seed initialization
    final seededCountries = NordApiService.sortCountries(
      NordSeedData.getCountries(),
    );
    final seededServers = NordSeedData.getServers();
    if (mounted) {
      setState(() {
        _credentials = NordSeedData.seedCredentials;
        _countries = seededCountries;
        if (seededServers.isNotEmpty) {
          _currentServer = seededServers.first;
        }
      });
    }

    final prefs = await VpnChannel.loadPrefs();
    if (!mounted) return;
    final savedToken = prefs['nord_token'];
    if (savedToken != null && savedToken.trim().isNotEmpty) {
      _accessToken = savedToken.trim();
    }
    _useCloudflareDns = prefs['use_cf_dns'] == 'true';

    final cachedPrivKey = prefs['private_key'] ?? '';
    if (cachedPrivKey.isNotEmpty) {
      _credentials = NordAccountCredentials(
        privateKey: cachedPrivKey,
        serviceUsername: prefs['service_user'] ?? '',
        servicePassword: prefs['service_pass'] ?? '',
        expiresAt: prefs['expires_at'] ?? '',
      );
    }

    final savedCountryId = int.tryParse(prefs['selected_country_id'] ?? '');
    if (savedCountryId != null) {
      for (final c in _countries) {
        if (c.id == savedCountryId) {
          _selectedCountry = c;
          final cSrvs = NordSeedData.getServers(countryId: c.id);
          if (cSrvs.isNotEmpty) _currentServer = cSrvs.first;
          break;
        }
      }
    }

    final liveStatus = await VpnChannel.getStatus();
    if (mounted && liveStatus.isConnected) {
      setState(() {
        _syncApiServer(liveStatus);
        _phase = VpnConnectionPhase.connected;
        _connectedSince ??= DateTime.now();
        _rxBytes = liveStatus.rxBytes;
        _txBytes = liveStatus.txBytes;
      });
    }

    unawaited(_refreshExitIp());

    try {
      final creds = await NordApiService.fetchAccountCredentials(_accessToken);
      final countries = await NordApiService.fetchCountries();

      await VpnChannel.savePref('private_key', creds.privateKey);
      await VpnChannel.savePref('service_user', creds.serviceUsername);
      await VpnChannel.savePref('service_pass', creds.servicePassword);
      await VpnChannel.savePref('expires_at', creds.expiresAt);

      NordCountry? initialCountry = _selectedCountry;
      if (savedCountryId != null) {
        for (final c in countries) {
          if (c.id == savedCountryId) {
            initialCountry = c;
            break;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _credentials = creds;
        _countries = countries;
        _selectedCountry = initialCountry;
        _statusHint = null;
      });

      final servers = await NordApiService.fetchRecommendedServers(
        countryId: initialCountry?.id,
        limit: 8,
      );
      if (mounted &&
          servers.isNotEmpty &&
          _phase == VpnConnectionPhase.disconnected) {
        setState(() {
          _currentServer = servers.first;
        });
      }
    } catch (_) {
      // Seed cache is already active; keep UI clean without scary errors.
    }
  }

  Future<void> _pollTelemetry() async {
    if (_vpnOperationInProgress || _pollInFlight) return;
    _pollInFlight = true;
    late final VpnStatusSnapshot snap;
    try {
      snap = await VpnChannel.getStatus();
    } finally {
      _pollInFlight = false;
    }
    if (!mounted || _vpnOperationInProgress || !snap.isAvailable) return;
    _supportsTrafficStats = snap.supportsTrafficStats;
    if (snap.isTransitioning) {
      if (_phase != VpnConnectionPhase.connecting) {
        setState(() {
          _phase = VpnConnectionPhase.connecting;
          _statusHint = 'VPN đang chuyển trạng thái...';
        });
      }
      return;
    }

    if (snap.isConnected) {
      final connectionChanged = _phase != VpnConnectionPhase.connected ||
          (snap.serverHostname.isNotEmpty &&
              snap.serverHostname != _liveServerHostname);
      final deltaRx = max(0, snap.rxBytes - _rxBytes);
      final deltaTx = max(0, snap.txBytes - _txBytes);
      setState(() {
        _syncApiServer(snap);
        if (connectionChanged) {
          _phase = VpnConnectionPhase.connected;
          _connectedSince = DateTime.now();
          _statusHint = null;
        }
        _rxSpeedBps = _rxBytes == 0 ? 0 : deltaRx;
        _txSpeedBps = _txBytes == 0 ? 0 : deltaTx;
        _rxBytes = snap.rxBytes;
        _txBytes = snap.txBytes;
      });
      if (connectionChanged) unawaited(_refreshExitIp());
    } else if (_phase != VpnConnectionPhase.disconnected) {
      setState(() {
        _liveServerHostname = '';
        _phase = VpnConnectionPhase.disconnected;
        _connectedSince = null;
        _rxSpeedBps = 0;
        _txSpeedBps = 0;
        _rxBytes = 0;
        _txBytes = 0;
        _statusHint = null;
        if (snap.wasRevoked) {
          _statusHint =
              'VPN vừa bị dịch vụ Proxy/Relay khác trên máy chiếm quyền mạng (hãy tắt Relay trước khi bật VPN).';
        }
      });
      unawaited(_refreshExitIp());
    } else if (_connectedSince != null) {
      setState(() {});
    }
  }

  void _syncApiServer(VpnStatusSnapshot snapshot) {
    if (snapshot.serverHostname.isEmpty) return;
    _liveServerHostname = snapshot.serverHostname;
    if (_currentServer?.hostname != snapshot.serverHostname) {
      _currentServer = null;
      _selectedCountry = null;
      for (final country in _countries) {
        if (country.id == snapshot.countryId) {
          _selectedCountry = country;
          break;
        }
      }
    }
  }

  Future<void> _refreshExitIp() async {
    if (!mounted || _refreshingIp) return;
    setState(() => _refreshingIp = true);
    final info = await NordApiService.fetchCurrentExitIp();
    if (!mounted) return;
    setState(() {
      _exitIp = info;
      _refreshingIp = false;
    });
  }

  Future<void> _toggleVpn() async {
    if (_phase == VpnConnectionPhase.connecting) return;
    if (_phase == VpnConnectionPhase.connected) {
      await _disconnectVpn();
    } else {
      await _connectToServer(specificServer: _currentServer);
    }
  }

  Future<void> _disconnectVpn() async {
    if (_vpnOperationInProgress) return;
    _vpnOperationInProgress = true;
    setState(() {
      _phase = VpnConnectionPhase.connecting;
      _statusHint = 'Đang ngắt kết nối an toàn...';
    });
    try {
      await VpnChannel.disconnect();
    } catch (error) {
      if (mounted) {
        setState(() {
          _phase = VpnConnectionPhase.connected;
          _statusHint = error is PlatformException ? error.message : '$error';
        });
      }
      return;
    } finally {
      _vpnOperationInProgress = false;
    }
    if (!mounted) return;
    setState(() {
      _phase = VpnConnectionPhase.disconnected;
      _connectedSince = null;
      _rxBytes = 0;
      _txBytes = 0;
      _rxSpeedBps = 0;
      _txSpeedBps = 0;
      _statusHint = null;
    });
    await Future.delayed(const Duration(milliseconds: 800));
    unawaited(_refreshExitIp());
  }

  Future<void> _connectToServer({
    NordServer? specificServer,
    bool forceDifferentServer = false,
  }) async {
    if (!mounted || _vpnOperationInProgress) return;
    _vpnOperationInProgress = true;
    setState(() {
      _phase = VpnConnectionPhase.connecting;
      _statusHint = VpnChannel.isIOS
          ? 'Đang chuẩn bị đường hầm IKEv2...'
          : 'Đang chuẩn bị đường hầm NordLynx...';
    });

    try {
      final permitted = await VpnChannel.prepareVpn();
      if (!mounted) return;
      if (!permitted) {
        throw Exception('Bạn cần cấp quyền kết nối VPN để tiếp tục.');
      }

      NordAccountCredentials? creds = _credentials;
      if (creds == null || creds.privateKey.isEmpty) {
        if (_accessToken.trim().isEmpty) {
          setState(() {
            _phase = VpnConnectionPhase.disconnected;
            _statusHint =
                'Bấm biểu tượng Cài đặt góc trên phải để dán Nord Token.';
          });
          await _openSettingsSheet();
          return;
        }
        setState(() => _statusHint = 'Đang xác thực NordVPN Token...');
        creds = await NordApiService.fetchAccountCredentials(_accessToken);
        await VpnChannel.savePref('private_key', creds.privateKey);
        await VpnChannel.savePref('service_user', creds.serviceUsername);
        await VpnChannel.savePref('service_pass', creds.servicePassword);
        await VpnChannel.savePref('expires_at', creds.expiresAt);
        _credentials = creds;
        if (!mounted) return;
      }

      NordServer? target = specificServer;
      if (target == null || forceDifferentServer) {
        setState(() => _statusHint = 'Đang tìm máy chủ tải thấp nhất...');
        final candidates = await NordApiService.fetchRecommendedServers(
          countryId: _selectedCountry?.id,
          limit: 15,
        );
        if (!mounted) return;
        if (candidates.isEmpty) {
          throw Exception('Không tìm thấy máy chủ khả dụng cho khu vực này.');
        }
        if (forceDifferentServer && candidates.length > 1) {
          final others =
              candidates.where((s) => s.id != _currentServer?.id).toList();
          target = others[Random().nextInt(min(5, others.length))];
        } else {
          target = candidates.first;
        }
      }

      setState(() {
        _currentServer = target;
        _statusHint =
            'Đang bắt tay ${VpnChannel.isIOS ? 'IKEv2' : 'WireGuard'} tới ${target!.hostname}...';
      });

      final wgConfig = NordApiService.buildWireGuardConfig(
        privateKey: creds.privateKey,
        server: target,
        useCloudflareDns: _useCloudflareDns,
      );

      final resultState = await VpnChannel.connect(
        wgQuickConfig: wgConfig,
        hostname: target.hostname,
        username: creds.serviceUsername,
        password: creds.servicePassword,
        countryId: target.countryId,
      );
      if (!mounted) return;

      if (resultState == 'UP') {
        setState(() {
          _phase = VpnConnectionPhase.connected;
          _connectedSince = DateTime.now();
          _rxBytes = 0;
          _txBytes = 0;
          _rxSpeedBps = 0;
          _txSpeedBps = 0;
          _statusHint = null;
        });
        await Future.delayed(const Duration(milliseconds: 1100));
        unawaited(_refreshExitIp());
      } else if (resultState == 'NEED_WG_EXPORT') {
        setState(() {
          _phase = VpnConnectionPhase.disconnected;
          _statusHint =
              'Thiếu tài khoản dịch vụ IKEv2. Nhập cấu hình này vào ứng dụng WireGuard để kết nối.';
        });
        await VpnChannel.shareWireGuardConfig(
          fileName: target.hostname,
          wgQuickConfig: wgConfig,
        );
      } else {
        throw Exception('Không thể bật giao diện mạng VPN ($resultState).');
      }
    } catch (e) {
      if (!mounted) return;
      final cleanMsg = e is PlatformException
          ? (e.message ?? e.code)
          : e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _phase = VpnConnectionPhase.disconnected;
        _connectedSince = null;
        _statusHint = cleanMsg;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(cleanMsg),
          backgroundColor: const Color(0xFFBE123C),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      _vpnOperationInProgress = false;
    }
  }

  Future<void> _openServerPicker() async {
    if (_countries.isEmpty) {
      try {
        final list = await NordApiService.fetchCountries();
        if (!mounted) return;
        setState(() => _countries = list);
      } catch (_) {}
    }
    if (!mounted) return;

    final res = await showModalBottomSheet<ServerSelectionResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ServerPickerSheet(
        countries: _countries,
        selectedCountry: _selectedCountry,
        activeServer: _currentServer,
      ),
    );

    if (!mounted || res == null) return;
    setState(() {
      _selectedCountry = res.country;
      if (res.specificServer != null) {
        _currentServer = res.specificServer;
      }
    });
    await VpnChannel.savePref(
      'selected_country_id',
      res.country?.id.toString() ?? '',
    );

    await _connectToServer(
      specificServer: res.specificServer,
      forceDifferentServer: res.specificServer == null,
    );
  }

  Future<void> _openSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SettingsToolsSheet(
        currentToken: _accessToken,
        credentials: _credentials,
        currentServer: _currentServer,
        useCloudflareDns: _useCloudflareDns,
        onSaveSettings: (newToken, useCfDns) async {
          final creds = await NordApiService.fetchAccountCredentials(newToken);
          await VpnChannel.savePref('nord_token', newToken);
          await VpnChannel.savePref('use_cf_dns', useCfDns.toString());
          await VpnChannel.savePref('private_key', creds.privateKey);
          await VpnChannel.savePref('service_user', creds.serviceUsername);
          await VpnChannel.savePref('service_pass', creds.servicePassword);
          await VpnChannel.savePref('expires_at', creds.expiresAt);
          if (!mounted) return;
          setState(() {
            _accessToken = newToken;
            _useCloudflareDns = useCfDns;
            _credentials = creds;
            _statusHint = null;
          });
          if (_phase == VpnConnectionPhase.connected &&
              _currentServer != null) {
            await _connectToServer(specificServer: _currentServer);
          }
        },
      ),
    );
  }

  String _formatDuration() {
    final start = _connectedSince;
    if (start == null || _phase != VpnConnectionPhase.connected) {
      return '00:00:00';
    }
    final diff = DateTime.now().difference(start);
    final h = diff.inHours.toString().padLeft(2, '0');
    final m = (diff.inMinutes % 60).toString().padLeft(2, '0');
    final s = (diff.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatBytes(int bytes, {bool perSec = false}) {
    final suffix = perSec ? '/s' : '';
    if (bytes < 1024) return '$bytes B$suffix';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB$suffix';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB$suffix';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _phase == VpnConnectionPhase.connected;
    final statusColor = isConnected
        ? const Color(0xFF00F5A0)
        : _phase == VpnConnectionPhase.connecting
            ? const Color(0xFF38BDF8)
            : const Color(0xFF94A3B8);

    final srv = _currentServer;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.38),
            radius: 1.15,
            colors: isConnected
                ? const [Color(0xFF0E2B2A), Color(0xFF090C18)]
                : const [Color(0xFF171B36), Color(0xFF090C18)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: SizedBox(
                  height: max(
                    constraints.maxHeight,
                    680 * MediaQuery.textScalerOf(context).scale(1),
                  ),
                  child: Column(
                    children: [
                      // Top App Bar
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7C5CFF)
                                  .withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.shield_moon_rounded,
                              color: Color(0xFF00F5A0),
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'CatVPN Nord',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                                Text(
                                  VpnChannel.isIOS
                                      ? 'IKEv2 • WireGuard Export'
                                      : 'NordLynx WireGuard Engine',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cấu hình API & Proxy',
                            onPressed: _openSettingsSheet,
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF151A30),
                            ),
                            icon: const Icon(
                              Icons.tune_rounded,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // Status badge + timer
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                isConnected
                                    ? 'ĐÃ BẢO VỆ • ẨN IP THỰC'
                                    : _phase == VpnConnectionPhase.connecting
                                        ? 'ĐANG THIẾT LẬP KẾT NỐI...'
                                        : 'CHƯA KẾT NỐI VPN',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 8),
                      Text(
                        _formatDuration(),
                        style: TextStyle(
                          color: isConnected ? Colors.white : Colors.white38,
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),

                      if (_statusHint != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _statusHint!,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF38BDF8),
                              fontSize: 12,
                            ),
                          ),
                        ),

                      const Spacer(),

                      // Giant CatVPN Power Orb
                      RepaintBoundary(
                        child: CatPowerOrb(phase: _phase, onTap: _toggleVpn),
                      ),

                      const Spacer(),

                      // Live Download / Upload Speed Row
                      Row(
                        children: [
                          Expanded(
                            child: _MetricTile(
                              icon: Icons.south_rounded,
                              iconColor: const Color(0xFF00F5A0),
                              label: 'Tải xuống',
                              primaryValue: _supportsTrafficStats
                                  ? _formatBytes(_rxSpeedBps, perSec: true)
                                  : '—',
                              subValue: _supportsTrafficStats
                                  ? 'Tổng: ${_formatBytes(_rxBytes)}'
                                  : 'iOS không cung cấp',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _MetricTile(
                              icon: Icons.north_rounded,
                              iconColor: const Color(0xFF38BDF8),
                              label: 'Tải lên',
                              primaryValue: _supportsTrafficStats
                                  ? _formatBytes(_txSpeedBps, perSec: true)
                                  : '—',
                              subValue: _supportsTrafficStats
                                  ? 'Tổng: ${_formatBytes(_txBytes)}'
                                  : 'iOS không cung cấp',
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Public Exit IP Card
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF13182E),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            Text(
                              _exitIp.countryCode.isNotEmpty
                                  ? _exitIp.flag
                                  : '🛰️',
                              style: const TextStyle(fontSize: 23),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Text(
                                        'IP Hiển Thị: ',
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                      Flexible(
                                        child: Text(
                                          _exitIp.ip,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w700,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_exitIp.country.isNotEmpty ||
                                      _exitIp.isp.isNotEmpty)
                                    Text(
                                      [
                                        if (_exitIp.city.isNotEmpty)
                                          _exitIp.city,
                                        if (_exitIp.country.isNotEmpty)
                                          _exitIp.country,
                                        if (_exitIp.isp.isNotEmpty) _exitIp.isp,
                                      ].join(' • '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Kiểm tra lại IP',
                              onPressed: _refreshingIp ? null : _refreshExitIp,
                              icon: _refreshingIp
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF00F5A0),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.refresh_rounded,
                                      color: Colors.white60,
                                      size: 20,
                                    ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 10),

                      // Bottom Server Selector + Quick Rotate IP
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: _openServerPicker,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 13,
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF19203C),
                                      Color(0xFF13182E),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: const Color(0xFF7C5CFF)
                                        .withValues(alpha: 0.45),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      srv != null
                                          ? srv.flag
                                          : (_selectedCountry?.flag ?? '⚡'),
                                      style: const TextStyle(fontSize: 26),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _selectedCountry == null
                                                ? 'Smart Connect ${srv != null ? "(${srv.countryName})" : ""}'
                                                : _selectedCountry!.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            _liveServerHostname.isNotEmpty &&
                                                    isConnected
                                                ? '$_liveServerHostname • IKEv2'
                                                : srv != null
                                                    ? '${srv.hostname} • Tải ${srv.load}%'
                                                    : 'Chạm để chọn trong 150 quốc gia',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white60,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(
                                      Icons.keyboard_arrow_up_rounded,
                                      color: Colors.white70,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Tooltip(
                            message: 'Xoay IP sang node khác cùng nước',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: _phase == VpnConnectionPhase.connecting
                                  ? null
                                  : () => _connectToServer(
                                        forceDifferentServer: true,
                                      ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 15,
                                  vertical: 16,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00F5A0)
                                      .withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: const Color(0xFF00F5A0)
                                        .withValues(alpha: 0.45),
                                  ),
                                ),
                                child: const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.cached_rounded,
                                      color: Color(0xFF00F5A0),
                                      size: 20,
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Đổi IP',
                                      style: TextStyle(
                                        color: Color(0xFF00F5A0),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String primaryValue;
  final String subValue;

  const _MetricTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.primaryValue,
    required this.subValue,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFF13182E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                Text(
                  primaryValue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  subValue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
