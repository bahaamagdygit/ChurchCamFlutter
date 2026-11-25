import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
  /// Lets the camera screen keep its copy in sync (it persists aids/audio too).
  final ValueChanged<AppSettings>? onSettingsChanged;
  const SettingsPanel({super.key, required this.onDisconnect, this.onSettingsChanged});

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

  bool _sendingFallback = false;

  /// Pick a picture and make it the studio's camera-fallback picture. The
  /// picker shrinks it to 1080p JPEG so it travels fast over Wi-Fi.
  Future<void> _pickFallback(ConnectionService conn) async {
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1080, imageQuality: 85);
      if (file == null) return;
      setState(() => _sendingFallback = true);
      final bytes = await file.readAsBytes();
      final mime = file.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      conn.sendFallbackImage(bytes, mime: mime);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fallback picture sent to the studio')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use that picture: $e')));
    } finally {
      if (mounted) setState(() => _sendingFallback = false);
    }
  }

  Widget _fallbackSection(ConnectionService conn) {
    final connected = conn.status == ConnectionStatus.connected;
    final thumb = conn.fallbackThumb;
    return PanelSection(
      title: 'Fallback picture',
      children: [
        const Text('Shown on the projector when a camera drops — or right now, with the switch below.', style: T.caption),
        const SizedBox(height: S.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(R.md),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(color: C.surface2, border: Border.all(color: conn.fallbackOn ? C.tally : C.border, width: conn.fallbackOn ? 2 : 1), borderRadius: BorderRadius.circular(R.md)),
              child: thumb != null
                  ? Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                  : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      PhosphorIcon(PhosphorIconsRegular.imageSquare, size: 30, color: C.textFaint),
                      const SizedBox(height: 6),
                      const Text('No picture set', style: T.caption),
                    ])),
            ),
          ),
        ),
        const SizedBox(height: S.md),
        Row(children: [
          Expanded(child: SizedBox(height: 46, child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: C.accent, foregroundColor: C.accentInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md))),
            onPressed: connected && !_sendingFallback ? () => _pickFallback(conn) : null,
            icon: _sendingFallback
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: C.accentInk))
                : PhosphorIcon(PhosphorIconsBold.image, size: 18, color: C.accentInk),
            label: Text(thumb != null ? 'Change picture' : 'Choose picture', style: const TextStyle(fontWeight: FontWeight.w700)),
          ))),
          if (thumb != null) ...[
            const SizedBox(width: S.sm),
            SizedBox(height: 46, child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: C.textDim, side: const BorderSide(color: C.border), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md))),
              onPressed: connected ? () => conn.sendFallbackImage(null) : null,
              child: const Text('Remove'),
            )),
          ],
        ]),
        const SizedBox(height: S.sm),
        PanelTile(
          icon: PhosphorIconsRegular.monitorPlay,
          title: 'Show it now',
          subtitle: conn.fallbackOn ? 'On the projector instead of the camera' : 'Camera is on the projector',
          highlighted: conn.fallbackOn,
          highlightColor: C.tally,
          trailing: Switch(
            value: conn.fallbackOn,
            onChanged: connected ? (v) => conn.sendControl('cut_to_black', v) : null,
          ),
        ),
        if (!connected) ...[
          const SizedBox(height: S.xs),
          const Text('Connect to the studio to change it.', style: T.caption),
        ],
      ],
    );
  }

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
    // Always read fresh: the camera screen persists aids / audio changes too.
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
    widget.onSettingsChanged?.call(_s);
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
      _fallbackSection(conn),
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
        ],
      ),
      PanelSection(
        title: 'Video codec',
        children: [
          Wrap(spacing: S.sm, runSpacing: S.sm, children: [
            Choice(
              label: 'MJPEG · stable', icon: PhosphorIconsRegular.shieldCheck,
              selected: _s.videoCodec != 'h264',
              onTap: () async { setState(() => _s = _s.copyWith(videoCodec: 'mjpeg')); await _persist(); },
            ),
            Choice(
              label: 'H.264 · beta', icon: PhosphorIconsRegular.lightning,
              selected: _s.videoCodec == 'h264',
              onTap: () async { setState(() => _s = _s.copyWith(videoCodec: 'h264')); await _persist(); },
            ),
          ]),
          const SizedBox(height: S.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PhosphorIcon(PhosphorIconsRegular.info, size: 16, color: C.textFaint),
            const SizedBox(width: 6),
            const Expanded(child: Text(
              'H.264 gives a sharper picture on the same Wi-Fi, but some phones show green frames. '
              'Smart Zoom, steady shot and backup recording need MJPEG. Applies on the next connect.',
              style: T.caption)),
          ]),
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
        const Text('Church Cam  ·  v1.1.3', style: T.caption),
      ]),
      const SizedBox(height: S.sm),
      const BuiltByCredit(),
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
