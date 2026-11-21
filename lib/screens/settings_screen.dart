import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/storage.dart';
import '../ui/tokens.dart';
import '../ui/components.dart';

/// Settings tab (side panel). Every change persists immediately via
/// shared_preferences — there's no Save button to forget.
class SettingsPanel extends StatefulWidget {
  final VoidCallback onDisconnect;
  const SettingsPanel({super.key, required this.onDisconnect});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  AppSettings _s = const AppSettings();
  final _nameCtrl = TextEditingController();
  final _wsCtrl = TextEditingController();
  final _tcpCtrl = TextEditingController();
  String _resolution = '1080p';
  int _fps = 30;

  static const _resolutions = ['360p', '480p', '720p', '1080p', '2K', '4K'];
  static const _fpsOptions = [30, 60];

  static int longEdgeFor(String label) {
    switch (label) {
      case '4K': return 3840;
      case '2K': return 2560;
      case '1080p': return 1920;
      case '720p': return 1280;
      case '480p': return 854;
      case '360p': return 640;
      default: return 1920;
    }
  }

  static String _labelForLongEdge(int e) {
    if (e >= 3840) return '4K';
    if (e >= 2560) return '2K';
    if (e >= 1920) return '1080p';
    if (e >= 1280) return '720p';
    if (e >= 854) return '480p';
    return '360p';
  }

  @override
  void initState() {
    super.initState();
    loadSettings().then((s) {
      if (!mounted) return;
      setState(() {
        _s = s;
        _nameCtrl.text = s.deviceName;
        _wsCtrl.text = s.wsPort.toString();
        _tcpCtrl.text = s.tcpPort.toString();
        _resolution = _labelForLongEdge(s.videoLongEdge);
        _fps = s.videoFps;
      });
    });
  }

  Future<void> _persist() async {
    _s = _s.copyWith(
      deviceName: _nameCtrl.text.trim().isEmpty ? 'Church Mobile' : _nameCtrl.text.trim(),
      wsPort: int.tryParse(_wsCtrl.text) ?? 8765,
      tcpPort: int.tryParse(_tcpCtrl.text) ?? 8766,
      videoLongEdge: longEdgeFor(_resolution),
      videoFps: _fps,
    );
    await saveSettings(_s);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _wsCtrl.dispose();
    _tcpCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionService>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PanelSection(
        title: 'This camera',
        children: [
          TextField(
            controller: _nameCtrl,
            onChanged: (_) => _persist(),
            style: const TextStyle(color: C.text),
            decoration: InputDecoration(
              labelText: 'Name shown on the desktop',
              prefixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: PhosphorIcon(PhosphorIconsRegular.tag, size: 18, color: C.textDim),
              ),
            ),
          ),
          const SizedBox(height: S.xs),
          const Text('Takes effect next time you connect.', style: T.caption),
        ],
      ),
      PanelSection(
        title: 'Video quality',
        children: [
          Wrap(spacing: S.sm, runSpacing: S.sm, children: _resolutions.map((r) => Choice(
                label: r,
                selected: _resolution == r,
                onTap: () { setState(() => _resolution = r); _persist(); },
              )).toList()),
          const SizedBox(height: S.md),
          Wrap(spacing: S.sm, children: _fpsOptions.map((f) => Choice(
                label: '$f fps',
                icon: f == 60 ? PhosphorIconsRegular.lightning : PhosphorIconsRegular.filmStrip,
                selected: _fps == f,
                onTap: () { setState(() => _fps = f); _persist(); },
              )).toList()),
          const SizedBox(height: S.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PhosphorIcon(PhosphorIconsRegular.info, size: 16, color: C.textFaint),
            const SizedBox(width: 6),
            const Expanded(child: Text('4K and 60 fps need a capable phone and strong Wi-Fi. If the picture stutters, use 1080p at 30 fps.', style: T.caption)),
          ]),
        ],
      ),
      PanelSection(
        title: 'Camera',
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.cameraRotate,
            title: 'Start with',
            subtitle: _s.preferredPosition == 'front' ? 'Front camera' : 'Back camera',
            trailing: Switch(
              value: _s.preferredPosition == 'front',
              onChanged: (v) async {
                setState(() => _s = _s.copyWith(preferredPosition: v ? 'front' : 'back'));
                await _persist();
              },
            ),
          ),
          PanelTile(
            icon: _s.audioEnabled ? PhosphorIconsRegular.microphone : PhosphorIconsRegular.microphoneSlash,
            title: 'Audio',
            subtitle: _s.audioEnabled ? 'Sending microphone audio' : 'Video only',
            trailing: Switch(
              value: _s.audioEnabled,
              onChanged: (v) async {
                setState(() => _s = _s.copyWith(audioEnabled: v));
                await _persist();
              },
            ),
          ),
        ],
      ),
      PanelSection(
        title: 'Connection',
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.desktop,
            title: conn.status == ConnectionStatus.connected ? 'Connected to studio' : 'Not connected',
            subtitle: conn.status == ConnectionStatus.connected ? 'Latency ${conn.latencyMs} ms' : null,
            highlighted: conn.status == ConnectionStatus.connected,
            highlightColor: C.ok,
          ),
          const SizedBox(height: S.xs),
          Row(children: [
            Expanded(child: _portField('Control port', _wsCtrl)),
            const SizedBox(width: S.sm),
            Expanded(child: _portField('Video port', _tcpCtrl)),
          ]),
          const SizedBox(height: S.md),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: C.tally,
                side: const BorderSide(color: Color(0x66FF3B30)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md)),
              ),
              onPressed: () => _confirmDisconnect(context),
              icon: PhosphorIcon(PhosphorIconsBold.plugs, size: 18, color: C.tally),
              label: const Text('Disconnect from studio', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      Row(children: [
        PhosphorIcon(PhosphorIconsFill.aperture, size: 16, color: C.textFaint),
        const SizedBox(width: 6),
        const Text('Church Cam  ·  v1.0.0', style: T.caption),
      ]),
    ]);
  }

  Widget _portField(String label, TextEditingController ctrl) => TextField(
        controller: ctrl,
        onChanged: (_) => _persist(),
        keyboardType: TextInputType.number,
        style: const TextStyle(color: C.text, fontFeatures: [FontFeature.tabularFigures()]),
        decoration: InputDecoration(labelText: label),
      );

  Future<void> _confirmDisconnect(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect from the studio?', style: T.title),
        content: const Text('This phone stops sending video. If it is on air, the desktop switches away from it.', style: T.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay connected')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.tally, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDisconnect();
  }
}
