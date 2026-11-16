import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/nord_models.dart';
import '../services/nord_api_service.dart';
import '../services/vpn_channel.dart';

class SettingsToolsSheet extends StatefulWidget {
  final String currentToken;
  final NordAccountCredentials? credentials;
  final NordServer? currentServer;
  final bool useCloudflareDns;
  final Future<void> Function(String newToken, bool useCfDns) onSaveSettings;

  const SettingsToolsSheet({
    super.key,
    required this.currentToken,
    required this.credentials,
    required this.currentServer,
    required this.useCloudflareDns,
    required this.onSaveSettings,
  });

  @override
  State<SettingsToolsSheet> createState() => _SettingsToolsSheetState();
}

class _SettingsToolsSheetState extends State<SettingsToolsSheet> {
  late final TextEditingController _tokenCtrl;
  late bool _cfDns;
  bool _obscureToken = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tokenCtrl = TextEditingController(text: widget.currentToken);
    _cfDns = widget.useCloudflareDns;
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _copyText(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã sao chép $label vào bộ nhớ tạm!'),
        backgroundColor: const Color(0xFF15803D),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final creds = widget.credentials;
    final srv = widget.currentServer;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0E1222),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.tune, color: Color(0xFF00F5A0)),
                  const SizedBox(width: 8),
                  const Text(
                    'Cấu Hình NordAPI & Xuất Proxy',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  if (creds != null && creds.expiresAt.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00F5A0).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'Hạn: ${creds.expiresAt.split(" ").first}',
                        style: const TextStyle(
                          color: Color(0xFF00F5A0),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                'NordVPN Access Token (64 ký tự hex)',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _tokenCtrl,
                obscureText: _obscureToken,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF171C33),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureToken ? Icons.visibility : Icons.visibility_off,
                      color: Colors.white54,
                    ),
                    onPressed: () =>
                        setState(() => _obscureToken = !_obscureToken),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: const Color(0xFF00F5A0),
                title: const Text(
                  'Dùng Cloudflare DNS (1.1.1.1)',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: const Text(
                  'Mặc định tắt sẽ dùng Nord Threat Protection DNS (103.86.96.100)',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value: _cfDns,
                onChanged: (v) => setState(() => _cfDns = v),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C5CFF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  onPressed: _saving
                      ? null
                      : () async {
                          setState(() => _saving = true);
                          try {
                            await widget.onSaveSettings(
                              _tokenCtrl.text.trim(),
                              _cfDns,
                            );
                            if (context.mounted) Navigator.of(context).pop();
                          } finally {
                            if (mounted) setState(() => _saving = false);
                          }
                        },
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.sync, size: 18),
                  label: Text(
                    _saving
                        ? 'Đang đồng bộ Token...'
                        : 'Lưu & Đồng Bộ Khóa NordLynx',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (VpnChannel.isIOS) ...[
                const SizedBox(height: 18),
                const Divider(color: Colors.white12),
                const Text('API đổi IP trên iPhone',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const SelectableText('http://127.0.0.1:8787/changeip',
                    style: TextStyle(color: Color(0xFF00F5A0), fontSize: 13)),
                const SizedBox(height: 6),
                const Text(
                  'Kết nối VPN một lần, sau đó gọi URL này từ script hoặc Phím tắt. '
                  'Không cần khóa; chỉ gọi được ngay trên iPhone. Dịch vụ tiếp tục chạy '
                  'khi đóng giao diện, trong lúc jailbreak đang hoạt động.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                TextButton.icon(
                  onPressed: () =>
                      _copyText('http://127.0.0.1:8787/changeip', 'URL đổi IP'),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy URL đổi IP'),
                ),
              ],
              if (creds != null) ...[
                const SizedBox(height: 20),
                const Divider(color: Colors.white12),
                const SizedBox(height: 8),
                const Text(
                  'Xuất nhanh Cấu hình WireGuard / Proxy cho PC & Tool',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (srv != null && VpnChannel.isIOS)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFC084FC),
                          side: const BorderSide(color: Color(0xFFC084FC)),
                        ),
                        onPressed: () {
                          final wg = NordApiService.buildWireGuardConfig(
                            privateKey: creds.privateKey,
                            server: srv,
                            useCloudflareDns: _cfDns,
                          );
                          VpnChannel.shareWireGuardConfig(
                            fileName: srv.hostname,
                            wgQuickConfig: wg,
                          );
                        },
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text('Mở sang App WireGuard (.conf)'),
                      ),
                    if (srv != null)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF00F5A0),
                          side: const BorderSide(color: Color(0xFF00F5A0)),
                        ),
                        onPressed: () {
                          final wg = NordApiService.buildWireGuardConfig(
                            privateKey: creds.privateKey,
                            server: srv,
                            useCloudflareDns: _cfDns,
                          );
                          _copyText(
                              wg, 'file cấu hình WireGuard (${srv.hostname})');
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy WireGuard .conf'),
                      ),
                    if (srv != null && creds.serviceUsername.isNotEmpty)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          side: const BorderSide(color: Color(0xFF38BDF8)),
                        ),
                        onPressed: () {
                          final proxyLine =
                              '${srv.hostname}:89:${creds.serviceUsername}:${creds.servicePassword}';
                          _copyText(proxyLine,
                              'HTTPS SSL Proxy (${srv.hostname}:89)');
                        },
                        icon: const Icon(Icons.lan_outlined, size: 16),
                        label: const Text('Copy HTTPS Proxy (:89)'),
                      ),
                    if (creds.serviceUsername.isNotEmpty)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFFBBF24),
                          side: const BorderSide(color: Color(0xFFFBBF24)),
                        ),
                        onPressed: () {
                          final socksLine =
                              'socks-nl1.nordvpn.com:1080:${creds.serviceUsername}:${creds.servicePassword}';
                          _copyText(socksLine, 'Nord SOCKS5 Proxy');
                        },
                        icon: const Icon(Icons.hub_outlined, size: 16),
                        label: const Text('Copy SOCKS5 (:1080)'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
