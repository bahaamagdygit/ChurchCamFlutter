import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/discovery_service.dart';
import '../services/storage.dart';
import '../utils/pairing.dart';
import '../utils/permissions.dart';
import 'qr_scan_screen.dart';

const _purple = Color(0xFF818CF8);
const _purpleDark = Color(0xFF4F46E5);
const _bg = Color(0xFF07070F);
const _card = Color(0xFF111120);
const _border = Color(0xFF1E1E35);

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final DiscoveryService _discovery = DiscoveryService();
  List<SavedConnection> _saved = [];
  String? _connectingKey;

  @override
  void initState() {
    super.initState();
    _discovery.start();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await loadSavedConnections();
    if (mounted) setState(() => _saved = list);
  }

  @override
  void dispose() {
    _discovery.dispose();
    super.dispose();
  }

  // ── QR scan ─────────────────────────────────────────────────────────────────
  Future<void> _scanQr() async {
    final granted = await requestCameraPermission();
    if (!mounted) return;
    if (!granted) {
      _toast('Camera permission is required to scan QR codes.');
      return;
    }
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;
    final pairing = parsePairing(result);
    if (pairing == null) {
      _toast('QR not recognised. Scan the QR shown in the desktop app.');
      return;
    }
    _showAddDialog(prefillHost: '${pairing.host}:${pairing.controlPort}');
  }

  // ── Manual add / edit ───────────────────────────────────────────────────────
  void _showAddDialog({String prefillHost = ''}) {
    final nameCtrl = TextEditingController();
    final hostCtrl = TextEditingController(text: prefillHost);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Add Connection', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: _dec('Name (e.g. Main Stage)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: hostCtrl,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: _dec('Desktop IP  e.g. 192.168.1.42'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _purpleDark),
            onPressed: () async {
              final pairing = parsePairing(hostCtrl.text);
              if (pairing == null) {
                _toast('Enter a valid IP, e.g. 192.168.1.42');
                return;
              }
              Navigator.pop(ctx);
              await addSavedConnection(
                name: nameCtrl.text.trim().isEmpty ? 'Desktop' : nameCtrl.text.trim(),
                host: pairing.host,
                controlPort: pairing.controlPort,
                videoPort: pairing.videoPort,
              );
              await _refresh();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(SavedConnection conn) {
    final ctrl = TextEditingController(text: conn.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Rename', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: _dec('Connection name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _purpleDark),
            onPressed: () async {
              final n = ctrl.text.trim();
              Navigator.pop(ctx);
              if (n.isNotEmpty) { await renameSavedConnection(conn.id, n); await _refresh(); }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ── Connect ─────────────────────────────────────────────────────────────────
  Future<void> _connect({
    required String key,
    required String name,
    required String host,
    required int controlPort,
    required int videoPort,
    bool saveFirst = false,
  }) async {
    if (_connectingKey != null) return;
    setState(() => _connectingKey = key);
    final conn = context.read<ConnectionService>();
    final settings = await loadSettings();
    conn.configure(deviceName: settings.deviceName);
    final ok = await conn.connect(host, controlPort, videoPort);
    if (!mounted) return;
    setState(() => _connectingKey = null);
    if (!ok) {
      _toast('Could not reach "$name" at $host:$controlPort.');
      return;
    }
    if (saveFirst) {
      await addSavedConnection(name: name, host: host, controlPort: controlPort, videoPort: videoPort);
      await _refresh();
    }
    if (mounted) Navigator.of(context).pushNamed('/home');
  }

  void _confirmDelete(SavedConnection conn) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Remove Connection', style: TextStyle(color: Colors.white)),
        content: Text('Remove "${conn.name}"?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await removeSavedConnection(conn.id);
              await _refresh();
            },
            child: const Text('Remove', style: TextStyle(color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF3A3A55)),
        filled: true,
        fillColor: _bg,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _purple),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              // Header
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0x1F818CF8),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0x4D818CF8), width: 2),
                      ),
                      child: const Center(child: Text('⛪', style: TextStyle(fontSize: 38))),
                    ),
                    const SizedBox(height: 10),
                    const Text('Church Live',
                        style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900)),
                    const Text('STUDIO CAMERA',
                        style: TextStyle(color: _purple, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 2)),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // QR + Manual buttons
              Row(
                children: [
                  Expanded(
                    child: _bigButton(
                      icon: Icons.qr_code_scanner,
                      label: 'Scan QR',
                      filled: true,
                      onTap: _scanQr,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _bigButton(
                      icon: Icons.add,
                      label: 'Add Manually',
                      filled: false,
                      onTap: () => _showAddDialog(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Discovered servers (auto-found on the LAN via UDP beacons)
              AnimatedBuilder(
                animation: _discovery,
                builder: (_, __) {
                  final found = _discovery.servers;
                  if (found.isEmpty) return const SizedBox.shrink();
                  return _listCard(
                    'Found on this network',
                    found.map((s) {
                      final key = 'disc:${s.host}:${s.controlPort}';
                      return _row(
                        icon: '🟢',
                        iconBg: const Color(0x2622C55E),
                        name: s.name,
                        sub: '${s.host}:${s.controlPort}',
                        connecting: _connectingKey == key,
                        trailing: const Text('Tap to connect',
                            style: TextStyle(color: _purple, fontSize: 12, fontWeight: FontWeight.w700)),
                        onTap: () => _connect(
                          key: key, name: s.name, host: s.host,
                          controlPort: s.controlPort, videoPort: s.videoPort, saveFirst: true,
                        ),
                      );
                    }).toList(),
                  );
                },
              ),

              const SizedBox(height: 16),

              // Saved connections
              if (_saved.isEmpty)
                Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _border),
                  ),
                  child: const Column(
                    children: [
                      Text('📡', style: TextStyle(fontSize: 36)),
                      SizedBox(height: 10),
                      Text('No Cameras Added',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                      SizedBox(height: 8),
                      Text('Scan the QR code shown in the desktop app, or tap "Add Manually".',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF666666), fontSize: 13)),
                    ],
                  ),
                )
              else
                _listCard(
                  'Saved Cameras',
                  _saved.map((conn) {
                    return _row(
                      icon: '📺',
                      iconBg: const Color(0x1F818CF8),
                      name: conn.name,
                      sub: conn.url,
                      connecting: _connectingKey == conn.id,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, color: Color(0xFF888888), size: 18),
                            onPressed: () => _showRenameDialog(conn),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Color(0xFFEF4444), size: 18),
                            onPressed: () => _confirmDelete(conn),
                          ),
                        ],
                      ),
                      onTap: () => _connect(
                        key: conn.id, name: conn.name, host: conn.host,
                        controlPort: conn.controlPort, videoPort: conn.videoPort,
                      ),
                    );
                  }).toList(),
                ),

              const SizedBox(height: 24),
              const Center(
                child: Text('Church Cam · LAN Studio Camera',
                    style: TextStyle(color: Color(0xFF1E1E35), fontSize: 11)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bigButton({
    required IconData icon,
    required String label,
    required bool filled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: filled ? _purpleDark : _card,
          borderRadius: BorderRadius.circular(16),
          border: filled ? null : Border.all(color: _border, width: 1.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: filled ? Colors.white : _purple, size: 20),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    color: filled ? Colors.white : const Color(0xFFCCCCCC),
                    fontSize: 15, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  Widget _listCard(String label, List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(const Divider(height: 1, color: _border, indent: 18, endIndent: 18));
      }
      children.add(rows[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
            child: Text(label.toUpperCase(),
                style: const TextStyle(
                    color: _purple, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _row({
    required String icon,
    required Color iconBg,
    required String name,
    required String sub,
    required bool connecting,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: connecting ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(child: Text(icon, style: const TextStyle(fontSize: 20))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFF555555), fontSize: 12)),
                ],
              ),
            ),
            if (connecting)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _purple)),
              )
            else
              trailing,
          ],
        ),
      ),
    );
  }
}
