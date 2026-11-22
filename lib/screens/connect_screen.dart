import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/discovery_service.dart';
import '../services/storage.dart';
import '../utils/pairing.dart';
import '../utils/permissions.dart';
import '../ui/tokens.dart';
import '../ui/components.dart';
import 'qr_scan_screen.dart';

/// First screen: pick the desktop studio to stream to.
///
/// Landscape two-column layout — what this is + the two ways to add a studio on
/// the left, the studios you can connect to (found on the network, then saved)
/// on the right, so the thing you tap most is always in reach of a thumb.
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
      _toast('Camera permission is needed to scan the studio QR code.');
      return;
    }
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;
    final pairing = parsePairing(result);
    if (pairing == null) {
      _toast('That QR code isn\'t from the studio app. Scan the one shown on the desktop.');
      return;
    }
    _showAddDialog(prefillHost: '${pairing.host}:${pairing.controlPort}');
  }

  // ── Manual add / rename / delete ────────────────────────────────────────────
  // A full page, not a dialog: in landscape the keyboard covers ~¾ of the
  // screen, so a dialog's field ended up hidden behind it. Here the field sits
  // right under a header that carries the Save action — always visible.
  Future<void> _showAddDialog({String prefillHost = ''}) async {
    final result = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _AddStudioPage(prefillHost: prefillHost)),
    );
    if (result == null) return;
    final pairing = parsePairing(result.$2);
    if (pairing == null) return;
    await addSavedConnection(
      name: result.$1.isEmpty ? 'Studio' : result.$1,
      host: pairing.host,
      controlPort: pairing.controlPort,
      videoPort: pairing.videoPort,
    );
    await _refresh();
  }

  void _showRenameDialog(SavedConnection conn) {
    final ctrl = TextEditingController(text: conn.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename studio', style: T.title),
        content: SizedBox(
          width: 360,
          child: TextField(controller: ctrl, autofocus: true, style: const TextStyle(color: C.text), decoration: const InputDecoration(labelText: 'Name')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final n = ctrl.text.trim();
              Navigator.pop(ctx);
              if (n.isNotEmpty) { await renameSavedConnection(conn.id, n); await _refresh(); }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(SavedConnection conn) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${conn.name}"?', style: T.title),
        content: const Text('You can add it again any time by scanning its QR code.', style: T.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.tally, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              await removeSavedConnection(conn.id);
              await _refresh();
            },
            child: const Text('Remove'),
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
    HapticFeedback.selectionClick();
    setState(() => _connectingKey = key);
    final conn = context.read<ConnectionService>();
    final settings = await loadSettings();
    conn.configure(deviceName: settings.deviceName);
    // MJPEG unless the operator opted into the H.264 beta in Settings. The
    // desktop picks the first codec both sides support.
    conn.setSupportedVideoCodecs(settings.videoCodec == 'h264' ? const ['h264', 'mjpeg'] : const ['mjpeg']);
    final ok = await conn.connect(host, controlPort, videoPort);
    if (!mounted) return;
    setState(() => _connectingKey = null);
    if (!ok) {
      _toast('Couldn\'t reach "$name" at $host. Check the desktop app is open and on the same Wi-Fi.');
      return;
    }
    if (saveFirst) {
      await addSavedConnection(name: name, host: host, controlPort: controlPort, videoPort: videoPort);
      await _refresh();
    }
    if (mounted) Navigator.of(context).pushNamed('/home');
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── UI ──────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(S.xl, S.lg, S.xl, S.lg),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Left: identity + add actions
            SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    // The app logo itself, so the first screen matches the
                    // launcher icon the operator just tapped.
                    Semantics(
                      label: 'Church Cam logo',
                      image: true,
                      child: Image.asset('assets/brand/app_mark.png', width: 52, height: 52, filterQuality: FilterQuality.medium),
                    ),
                    const SizedBox(width: S.md),
                    const Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Church Cam', style: TextStyle(color: C.text, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                        Text('Studio camera for the live stream', style: T.caption),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: S.xl),
                  const Text('Connect this phone to the desktop studio. Both must be on the same Wi-Fi.', style: T.body),
                  const SizedBox(height: S.lg),
                  _primaryAction(
                    icon: PhosphorIconsBold.qrCode,
                    title: 'Scan studio QR',
                    subtitle: 'Fastest — shown in the desktop app',
                    onTap: _scanQr,
                  ),
                  const SizedBox(height: S.sm),
                  _secondaryAction(
                    icon: PhosphorIconsBold.keyboard,
                    title: 'Enter IP address',
                    onTap: () => _showAddDialog(),
                  ),
                  const SizedBox(height: S.xl),
                  const BuiltByCredit(),
                ]),
              ),
            ),
            const SizedBox(width: S.xl),
            // Right: studios
            Expanded(
              child: AnimatedBuilder(
                animation: _discovery,
                builder: (_, __) {
                  final found = _discovery.servers;
                  final hasAny = found.isNotEmpty || _saved.isNotEmpty;
                  return Container(
                    decoration: BoxDecoration(color: const Color(0xFF111117), borderRadius: BorderRadius.circular(R.lg), border: Border.all(color: C.border)),
                    child: !hasAny
                        ? _emptyState()
                        : ListView(padding: const EdgeInsets.all(S.lg), children: [
                            if (found.isNotEmpty) ...[
                              _listHeader('On this network', PhosphorIconsBold.wifiHigh, live: true),
                              ...found.map((s) {
                                final key = 'disc:${s.host}:${s.controlPort}';
                                return _studioRow(
                                  icon: PhosphorIconsFill.desktop,
                                  iconColor: C.ok,
                                  name: s.name,
                                  sub: s.host,
                                  connecting: _connectingKey == key,
                                  onTap: () => _connect(key: key, name: s.name, host: s.host,
                                      controlPort: s.controlPort, videoPort: s.videoPort, saveFirst: true),
                                );
                              }),
                              const SizedBox(height: S.lg),
                            ],
                            if (_saved.isNotEmpty) ...[
                              _listHeader('Saved studios', PhosphorIconsBold.bookmarkSimple),
                              ..._saved.map((c) => _studioRow(
                                    icon: PhosphorIconsFill.desktopTower,
                                    iconColor: C.accent,
                                    name: c.name,
                                    sub: c.host,
                                    connecting: _connectingKey == c.id,
                                    onTap: () => _connect(key: c.id, name: c.name, host: c.host,
                                        controlPort: c.controlPort, videoPort: c.videoPort),
                                    menu: PopupMenuButton<String>(
                                      tooltip: 'More',
                                      color: C.surface2,
                                      icon: PhosphorIcon(PhosphorIconsBold.dotsThreeVertical, size: 20, color: C.textDim),
                                      onSelected: (v) => v == 'rename' ? _showRenameDialog(c) : _confirmDelete(c),
                                      itemBuilder: (_) => [
                                        PopupMenuItem(value: 'rename', child: Row(children: [
                                          PhosphorIcon(PhosphorIconsRegular.pencilSimple, size: 18, color: C.text),
                                          const SizedBox(width: S.sm), const Text('Rename'),
                                        ])),
                                        PopupMenuItem(value: 'remove', child: Row(children: [
                                          PhosphorIcon(PhosphorIconsRegular.trash, size: 18, color: C.tally),
                                          const SizedBox(width: S.sm), const Text('Remove', style: TextStyle(color: C.tally)),
                                        ])),
                                      ],
                                    ),
                                  )),
                            ],
                          ]),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(S.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(R.lg)),
              child: PhosphorIcon(PhosphorIconsRegular.magnifyingGlass, size: 26, color: C.textDim),
            ),
            const SizedBox(height: S.md),
            const Text('Looking for studios…', style: T.title),
            const SizedBox(height: S.xs),
            const Text('Open the desktop app on the same Wi-Fi and it appears here automatically. Or scan its QR code.',
                textAlign: TextAlign.center, style: T.body),
            const SizedBox(height: S.lg),
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent)),
          ]),
        ),
      );

  Widget _listHeader(String label, IconData icon, {bool live = false}) => Padding(
        padding: const EdgeInsets.only(bottom: S.sm, left: S.xs),
        child: Row(children: [
          PhosphorIcon(icon, size: 14, color: live ? C.ok : C.textFaint),
          const SizedBox(width: 6),
          Text(label.toUpperCase(), style: T.overline.copyWith(color: live ? C.ok : C.textFaint)),
        ]),
      );

  Widget _studioRow({
    required IconData icon,
    required Color iconColor,
    required String name,
    required String sub,
    required bool connecting,
    required VoidCallback onTap,
    Widget? menu,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: S.sm),
        child: Material(
          color: C.surface2,
          borderRadius: BorderRadius.circular(R.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(R.md),
            onTap: connecting ? null : onTap,
            child: Container(
              height: 64,
              padding: const EdgeInsets.only(left: S.md, right: S.xs),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(R.md), border: Border.all(color: C.border)),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(R.sm)),
                  child: PhosphorIcon(icon, size: 20, color: iconColor),
                ),
                const SizedBox(width: S.md),
                Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.caption.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ])),
                if (connecting)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: S.md),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent)),
                  )
                else ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: C.accentSoft, borderRadius: BorderRadius.circular(R.pill)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Connect', style: TextStyle(color: C.accent, fontSize: 13, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 4),
                      PhosphorIcon(PhosphorIconsBold.arrowRight, size: 14, color: C.accent),
                    ]),
                  ),
                  if (menu != null) menu else const SizedBox(width: S.sm),
                ],
              ]),
            ),
          ),
        ),
      );

  Widget _primaryAction({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) => Material(
        color: C.accent,
        borderRadius: BorderRadius.circular(R.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.md),
          onTap: () { HapticFeedback.selectionClick(); onTap(); },
          child: Container(
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: S.lg),
            child: Row(children: [
              PhosphorIcon(icon, size: 26, color: C.accentInk),
              const SizedBox(width: S.md),
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(color: C.accentInk, fontSize: 15, fontWeight: FontWeight.w800)),
                Text(subtitle, style: const TextStyle(color: Color(0xB30B0B14), fontSize: 12, fontWeight: FontWeight.w600)),
              ])),
            ]),
          ),
        ),
      );

  Widget _secondaryAction({required IconData icon, required String title, required VoidCallback onTap}) => Material(
        color: C.surface2,
        borderRadius: BorderRadius.circular(R.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.md),
          onTap: () { HapticFeedback.selectionClick(); onTap(); },
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: S.lg),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(R.md), border: Border.all(color: C.border)),
            child: Row(children: [
              PhosphorIcon(icon, size: 20, color: C.text),
              const SizedBox(width: S.md),
              Text(title, style: T.label),
            ]),
          ),
        ),
      );
}

class _AddStudioPage extends StatefulWidget {
  final String prefillHost;
  const _AddStudioPage({required this.prefillHost});

  @override
  State<_AddStudioPage> createState() => _AddStudioPageState();
}

class _AddStudioPageState extends State<_AddStudioPage> {
  late final _host = TextEditingController(text: widget.prefillHost);
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() { _host.dispose(); _name.dispose(); super.dispose(); }

  void _save() {
    if (parsePairing(_host.text) == null) {
      setState(() => _error = 'Enter an IP like 192.168.1.42');
      return;
    }
    Navigator.pop(context, (_name.text.trim(), _host.text.trim()));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: C.bg,
        appBar: AppBar(
          backgroundColor: C.bg,
          toolbarHeight: 52,
          title: const Text('Add a studio', style: T.title),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: S.md),
              child: FilledButton(onPressed: _save, child: const Text('Save studio')),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(S.xl, S.sm, S.xl, S.xl),
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    autofocus: widget.prefillHost.isEmpty,
                    style: const TextStyle(color: C.text),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    decoration: InputDecoration(
                      labelText: 'Desktop IP address',
                      hintText: '192.168.1.42',
                      errorText: _error,
                      prefixIcon: Padding(padding: const EdgeInsets.all(12), child: PhosphorIcon(PhosphorIconsRegular.desktop, size: 18, color: C.textDim)),
                    ),
                  ),
                ),
                const SizedBox(width: S.md),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _name,
                    style: const TextStyle(color: C.text),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    decoration: InputDecoration(
                      labelText: 'Name (optional)',
                      hintText: 'Main hall',
                      prefixIcon: Padding(padding: const EdgeInsets.all(12), child: PhosphorIcon(PhosphorIconsRegular.tag, size: 18, color: C.textDim)),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      );
}
