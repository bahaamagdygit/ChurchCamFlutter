import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../widgets/connection_badge.dart';

const _purple = Color(0xFF818CF8);
const _card = Color(0xFF111120);
const _border = Color(0xFF1E1E35);

/// Remote control of the desktop (Section 9 — Control screen).
class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  String? _selectedDesktopCam;
  double _desktopZoom = 1.0;
  bool _cutToBlack = false;
  bool _overlayVisible = false;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionService>();
    final cams = conn.desktopCameras;

    return Scaffold(
      backgroundColor: const Color(0xFF07070F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E1F),
        title: const Text('Control'),
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ConnectionBadge()))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Live cameras: tap one to put it live on the desktop ──
          _section('Live Cameras', [
            if (cams.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No cameras reported by the desktop yet.',
                    style: TextStyle(color: Color(0xFF666666))),
              )
            else
              ...cams.map((c) {
                // The desktop reports the ACTIVE camera by label; match against it,
                // and also treat a locally-tapped selection as active immediately.
                final isLive = _selectedDesktopCam == c.id ||
                    (_selectedDesktopCam == null && c.label == conn.activeCameraLabel);
                return _cameraRow(c, isLive, () {
                  setState(() => _selectedDesktopCam = c.id);
                  conn.selectDesktopCamera(c.id);
                });
              }),
            const SizedBox(height: 12),
            _labeled('Desktop zoom  ${_desktopZoom.toStringAsFixed(1)}×', Slider(
              value: _desktopZoom, min: 1, max: 4, divisions: 30, activeColor: _purple,
              onChanged: (v) => setState(() => _desktopZoom = v),
              onChangeEnd: (v) => conn.desktopZoom(v),
            )),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _chip(Icons.flip_camera_android, 'Flip', () => conn.sendControl('flip')),
              _chip(Icons.flash_on, 'Torch', () => conn.sendControl('torch')),
              _chip(Icons.center_focus_strong, 'Focus reset', () => conn.sendControl('focus_reset')),
              _toggleChip(Icons.dark_mode, 'Cut to black', _cutToBlack, () {
                setState(() => _cutToBlack = !_cutToBlack);
                conn.cutToBlack(_cutToBlack);
              }),
            ]),
          ]),

          // ── Stream ──
          _section('Stream', [
            Row(children: [
              Expanded(child: _bigBtn('● Start Stream', const Color(0xFF4F46E5), conn.streamLive, () => conn.startStream())),
              const SizedBox(width: 10),
              Expanded(child: _bigBtn('■ Stop Stream', const Color(0xFF991B1B), !conn.streamLive, () => conn.stopStream())),
            ]),
            const SizedBox(height: 6),
            Text(conn.streamLive ? '🔴 LIVE' : 'Offline',
                style: TextStyle(color: conn.streamLive ? const Color(0xFFEF4444) : const Color(0xFF666666), fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _bigBtn('⏺ Start Rec', const Color(0xFF4F46E5), conn.recording, () => conn.startRecording())),
              const SizedBox(width: 10),
              Expanded(child: _bigBtn('⏹ Stop Rec', const Color(0xFF991B1B), !conn.recording, () => conn.stopRecording())),
            ]),
            const SizedBox(height: 6),
            Text(conn.recording ? '⏺ Recording' : 'Not recording',
                style: TextStyle(color: conn.recording ? const Color(0xFFEF4444) : const Color(0xFF666666), fontWeight: FontWeight.bold)),
          ]),

          // ── Slides ──
          _section('Slides', [
            Row(children: [
              Expanded(child: _bigBtn('◀ Previous', _card, false, () => conn.prevSlide())),
              const SizedBox(width: 10),
              Expanded(child: _bigBtn('Next ▶', _card, false, () => conn.nextSlide())),
            ]),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFF07070F), borderRadius: BorderRadius.circular(12), border: Border.all(color: _border)),
              child: Text(conn.readingText.isEmpty ? '—' : conn.readingText,
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ]),

          // ── Overlay ──
          _section('Overlay', [
            _toggleChip(Icons.subtitles, _overlayVisible ? 'Reading text: ON' : 'Reading text: OFF', _overlayVisible, () {
              setState(() => _overlayVisible = !_overlayVisible);
              conn.toggleReadingOverlay(_overlayVisible);
            }),
          ]),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(18), border: Border.all(color: _border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title.toUpperCase(), style: const TextStyle(color: _purple, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
          const SizedBox(height: 12),
          ...children,
        ]),
      );

  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(label, style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 13)), child],
      );

  /// A selectable camera row — tap to put it live on the desktop.
  Widget _cameraRow(DesktopCamera c, bool isLive, VoidCallback onTap) {
    final icon = c.kind == 'ip' ? Icons.router
        : c.kind == 'mobile' ? Icons.smartphone
        : Icons.videocam;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: isLive ? const Color(0x33818CF8) : const Color(0xFF07070F),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isLive ? _purple : _border, width: isLive ? 1.5 : 1),
          ),
          child: Row(children: [
            Icon(icon, color: isLive ? _purple : Colors.white70, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(c.label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontWeight: isLive ? FontWeight.w700 : FontWeight.w500))),
            if (isLive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: const Color(0xFFEF4444), borderRadius: BorderRadius.circular(6)),
                child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
              )
            else
              const Text('Tap to go live', style: TextStyle(color: _purple, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) => ActionChip(
        backgroundColor: const Color(0xFF07070F),
        side: const BorderSide(color: _border),
        avatar: Icon(icon, color: _purple, size: 18),
        label: Text(label, style: const TextStyle(color: Colors.white)),
        onPressed: onTap,
      );

  Widget _toggleChip(IconData icon, String label, bool on, VoidCallback onTap) => ActionChip(
        backgroundColor: on ? const Color(0x33818CF8) : const Color(0xFF07070F),
        side: BorderSide(color: on ? _purple : _border),
        avatar: Icon(icon, color: on ? _purple : Colors.white70, size: 18),
        label: Text(label, style: TextStyle(color: on ? _purple : Colors.white)),
        onPressed: onTap,
      );

  Widget _bigBtn(String label, Color color, bool active, VoidCallback onTap) => ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: active ? color.withValues(alpha: 0.45) : color,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      );
}
