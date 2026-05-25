import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/storage.dart';
import '../widgets/connection_badge.dart';

const _purple = Color(0xFF818CF8);
const _card = Color(0xFF111120);
const _border = Color(0xFF1E1E35);

/// Settings (Section 9). Persists via shared_preferences.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings _s = const AppSettings();
  final _nameCtrl = TextEditingController();
  final _wsCtrl = TextEditingController();
  final _tcpCtrl = TextEditingController();
  String _resolution = '720p';

  static const _resolutions = ['480p', '720p', '1080p', '4K'];

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
      });
    });
  }

  Future<void> _persist() async {
    _s = _s.copyWith(
      deviceName: _nameCtrl.text.trim().isEmpty ? 'Church Mobile' : _nameCtrl.text.trim(),
      wsPort: int.tryParse(_wsCtrl.text) ?? 8765,
      tcpPort: int.tryParse(_tcpCtrl.text) ?? 8766,
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
    final conn = context.read<ConnectionService>();
    return Scaffold(
      backgroundColor: const Color(0xFF07070F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E1F),
        title: const Text('Settings'),
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ConnectionBadge()))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Device', [
            _field('Device name', _nameCtrl, onChanged: (_) => _persist()),
          ]),

          _section('Camera', [
            _labeled('Resolution', DropdownButton<String>(
              value: _resolution, isExpanded: true, dropdownColor: _card,
              style: const TextStyle(color: Colors.white),
              items: _resolutions.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
              onChanged: (v) => setState(() => _resolution = v ?? '720p'),
            )),
            const SizedBox(height: 8),
            _toggleRow('Preferred camera: ${_s.preferredPosition == 'front' ? 'Front' : 'Back'}',
                _s.preferredPosition == 'front', (v) async {
              setState(() => _s = _s.copyWith(preferredPosition: v ? 'front' : 'back'));
              await _persist();
            }),
            _toggleRow('Enable audio', _s.audioEnabled, (v) async {
              setState(() => _s = _s.copyWith(audioEnabled: v));
              await _persist();
            }),
          ]),

          _section('Connection ports', [
            Row(children: [
              Expanded(child: _field('WebSocket', _wsCtrl, number: true, onChanged: (_) => _persist())),
              const SizedBox(width: 12),
              Expanded(child: _field('TCP video', _tcpCtrl, number: true, onChanged: (_) => _persist())),
            ]),
          ]),

          const SizedBox(height: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF991B1B), padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const Icon(Icons.link_off),
            label: const Text('Disconnect'),
            onPressed: () {
              conn.disconnect();
              Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
            },
          ),

          const SizedBox(height: 24),
          _section('About', const [
            Text('Church Cam · Flutter', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            SizedBox(height: 4),
            Text('Version 1.0.0  ·  LAN Studio Camera', style: TextStyle(color: Color(0xFF666666), fontSize: 13)),
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

  Widget _field(String label, TextEditingController ctrl, {bool number = false, ValueChanged<String>? onChanged}) => _labeled(
        label,
        TextField(
          controller: ctrl,
          onChanged: onChanged,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            isDense: true,
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _border)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _purple)),
          ),
        ),
      );

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.white))),
          Switch(value: value, activeColor: _purple, onChanged: onChanged),
        ],
      );
}
