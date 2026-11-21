import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../ui/tokens.dart';
import '../ui/components.dart';

/// Studio tab: remote control of the desktop (stream, recording, slides,
/// reading text, cut to black, live camera zoom). Lives in the camera screen's
/// side panel so the operator never leaves the viewfinder.
class StudioPanel extends StatefulWidget {
  const StudioPanel({super.key});

  @override
  State<StudioPanel> createState() => _StudioPanelState();
}

class _StudioPanelState extends State<StudioPanel> {
  double _liveZoom = 1.0;
  bool _cutToBlack = false;
  bool _overlayVisible = false;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionService>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PanelSection(
        title: 'Output',
        children: [
          Row(children: [
            Expanded(child: _BigAction(
              icon: PhosphorIconsFill.broadcast,
              label: conn.streamLive ? 'Stop stream' : 'Go live',
              status: conn.streamLive ? 'LIVE' : 'Offline',
              active: conn.streamLive,
              onTap: () => conn.streamLive ? _confirm(context, 'Stop the live stream?', 'Viewers will see the stream end.', conn.stopStream) : conn.startStream(),
            )),
            const SizedBox(width: S.sm),
            Expanded(child: _BigAction(
              icon: PhosphorIconsFill.record,
              label: conn.recording ? 'Stop recording' : 'Record',
              status: conn.recording ? 'REC' : 'Not recording',
              active: conn.recording,
              onTap: () => conn.recording ? conn.stopRecording() : conn.startRecording(),
            )),
          ]),
          const SizedBox(height: S.sm),
          PanelTile(
            icon: PhosphorIconsRegular.monitor,
            title: 'Cut to black',
            subtitle: _cutToBlack ? 'Fallback picture on air' : 'Live camera on air',
            highlighted: _cutToBlack, highlightColor: C.warn,
            trailing: Switch(value: _cutToBlack, onChanged: (v) {
              setState(() => _cutToBlack = v);
              conn.cutToBlack(v);
            }),
          ),
        ],
      ),
      PanelSection(
        title: 'Slides & reading',
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(S.md),
            decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(R.md), border: Border.all(color: C.border)),
            child: Text(
              conn.readingText.isEmpty ? 'No reading text is showing right now.' : conn.readingText,
              textAlign: TextAlign.center,
              style: conn.readingText.isEmpty ? T.body : const TextStyle(color: C.text, fontSize: 15, fontWeight: FontWeight.w600, height: 1.35),
            ),
          ),
          const SizedBox(height: S.sm),
          Row(children: [
            Expanded(child: _StepButton(icon: PhosphorIconsBold.caretLeft, label: 'Previous', onTap: conn.prevSlide)),
            const SizedBox(width: S.sm),
            Expanded(child: _StepButton(icon: PhosphorIconsBold.caretRight, label: 'Next', onTap: conn.nextSlide, trailingIcon: true)),
          ]),
          const SizedBox(height: S.sm),
          PanelTile(
            icon: PhosphorIconsRegular.textAa,
            title: 'Show reading text',
            subtitle: _overlayVisible ? 'Visible to viewers' : 'Hidden',
            highlighted: _overlayVisible,
            trailing: Switch(value: _overlayVisible, onChanged: (v) {
              setState(() => _overlayVisible = v);
              conn.toggleReadingOverlay(v);
            }),
          ),
        ],
      ),
      PanelSection(
        title: 'On-air camera zoom',
        children: [
          ValueSlider(
            icon: PhosphorIconsRegular.magnifyingGlassPlus,
            label: 'Zoom', value: _liveZoom, min: 1, max: 4, neutral: 1,
            format: (v) => '${v.toStringAsFixed(1)}×',
            onChanged: (v) => setState(() => _liveZoom = v),
          ),
          const Text('Applies to whichever camera is on air (USB, IP or a phone).', style: T.body),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => conn.desktopZoom(_liveZoom), child: const Text('Apply', style: TextStyle(color: C.accent, fontWeight: FontWeight.w700))),
          ),
        ],
      ),
    ]);
  }

  Future<void> _confirm(BuildContext context, String title, String body, VoidCallback action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: T.title),
        content: Text(body, style: T.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep streaming')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.tally, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Stop stream'),
          ),
        ],
      ),
    );
    if (ok == true) action();
  }
}

/// Tall toggle button for stream / record: big icon, verb label, live status.
class _BigAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String status;
  final bool active;
  final VoidCallback onTap;
  const _BigAction({required this.icon, required this.label, required this.status, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true, label: label,
        child: Material(
          color: active ? C.tally : C.surface2,
          borderRadius: BorderRadius.circular(R.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(R.md),
            onTap: () { HapticFeedback.mediumImpact(); onTap(); },
            child: Container(
              height: 92,
              padding: const EdgeInsets.all(S.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(R.md),
                border: Border.all(color: active ? C.tally : C.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                PhosphorIcon(icon, size: 24, color: active ? Colors.white : C.tally),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: T.label.copyWith(color: active ? Colors.white : C.text)),
                  Text(status, style: T.caption.copyWith(color: active ? Colors.white70 : C.textFaint)),
                ]),
              ]),
            ),
          ),
        ),
      );
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool trailingIcon;
  const _StepButton({required this.icon, required this.label, required this.onTap, this.trailingIcon = false});

  @override
  Widget build(BuildContext context) {
    final ic = PhosphorIcon(icon, size: 18, color: C.text);
    return Material(
      color: C.surface2,
      borderRadius: BorderRadius.circular(R.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.md),
        onTap: () { HapticFeedback.selectionClick(); onTap(); },
        child: Container(
          height: 52,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(R.md), border: Border.all(color: C.border)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (!trailingIcon) ...[ic, const SizedBox(width: 6)],
            Text(label, style: T.label),
            if (trailingIcon) ...[const SizedBox(width: 6), ic],
          ]),
        ),
      ),
    );
  }
}
