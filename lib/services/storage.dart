import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/camera_filters.dart';

/// App-wide settings persisted across launches (Settings screen + Section 10).
class AppSettings {
  final String deviceName;
  final String preferredPosition; // 'back' | 'front'
  final bool audioEnabled;
  final int wsPort;
  final int tcpPort;

  const AppSettings({
    this.deviceName = 'Church Mobile',
    this.preferredPosition = 'back',
    this.audioEnabled = false,
    this.wsPort = 8765,
    this.tcpPort = 8766,
  });

  AppSettings copyWith({
    String? deviceName, String? preferredPosition, bool? audioEnabled,
    int? wsPort, int? tcpPort,
  }) => AppSettings(
        deviceName: deviceName ?? this.deviceName,
        preferredPosition: preferredPosition ?? this.preferredPosition,
        audioEnabled: audioEnabled ?? this.audioEnabled,
        wsPort: wsPort ?? this.wsPort,
        tcpPort: tcpPort ?? this.tcpPort,
      );

  Map<String, dynamic> toJson() => {
        'deviceName': deviceName, 'preferredPosition': preferredPosition,
        'audioEnabled': audioEnabled, 'wsPort': wsPort, 'tcpPort': tcpPort,
      };

  factory AppSettings.fromJson(Map j) => AppSettings(
        deviceName: (j['deviceName'] ?? 'Church Mobile').toString(),
        preferredPosition: (j['preferredPosition'] ?? 'back').toString(),
        audioEnabled: j['audioEnabled'] == true,
        wsPort: (j['wsPort'] is int) ? j['wsPort'] as int : 8765,
        tcpPort: (j['tcpPort'] is int) ? j['tcpPort'] as int : 8766,
      );
}

const _settingsKey = 'churchcam.settings';
const _filtersKey = 'churchcam.filters'; // per-cameraId filter map

Future<AppSettings> loadSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_settingsKey);
  if (raw == null) return const AppSettings();
  try { return AppSettings.fromJson(jsonDecode(raw) as Map); } catch (_) { return const AppSettings(); }
}

Future<void> saveSettings(AppSettings s) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_settingsKey, jsonEncode(s.toJson()));
}

/// Per-camera filters: keyed by a camera identifier (e.g. lens name).
Future<CameraFilters> loadFilters(String cameraId) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_filtersKey);
  if (raw == null) return CameraFilters.none;
  try {
    final map = jsonDecode(raw) as Map;
    final entry = map[cameraId];
    if (entry is Map) return CameraFilters.fromJson(entry);
  } catch (_) {}
  return CameraFilters.none;
}

Future<void> saveFilters(String cameraId, CameraFilters f) async {
  final prefs = await SharedPreferences.getInstance();
  Map<String, dynamic> map = {};
  final raw = prefs.getString(_filtersKey);
  if (raw != null) {
    try { map = Map<String, dynamic>.from(jsonDecode(raw) as Map); } catch (_) {}
  }
  map[cameraId] = f.toJson();
  await prefs.setString(_filtersKey, jsonEncode(map));
}

class SavedConnection {
  final String id;
  final String name;
  final String host;
  final int controlPort;
  final int videoPort;
  const SavedConnection({
    required this.id,
    required this.name,
    required this.host,
    required this.controlPort,
    required this.videoPort,
  });

  String get url => 'ws://$host:$controlPort';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'controlPort': controlPort,
        'videoPort': videoPort,
      };

  factory SavedConnection.fromJson(Map<String, dynamic> j) => SavedConnection(
        id: j['id'].toString(),
        name: (j['name'] ?? 'Desktop').toString(),
        host: (j['host'] ?? '').toString(),
        controlPort: (j['controlPort'] is int) ? j['controlPort'] as int : 8765,
        videoPort: (j['videoPort'] is int) ? j['videoPort'] as int : 8766,
      );
}

const _key = 'churchcam.savedConnections';

Future<List<SavedConnection>> loadSavedConnections() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_key);
  if (raw == null || raw.isEmpty) return [];
  try {
    final list = jsonDecode(raw);
    if (list is List) {
      return list
          .whereType<Map>()
          .map((m) => SavedConnection.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    }
  } catch (_) {}
  return [];
}

Future<void> _save(List<SavedConnection> list) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_key, jsonEncode(list.map((c) => c.toJson()).toList()));
}

Future<List<SavedConnection>> addSavedConnection({
  required String name,
  required String host,
  required int controlPort,
  required int videoPort,
}) async {
  final list = await loadSavedConnections();
  // De-dupe by host:controlPort — update the name if it already exists.
  list.removeWhere((c) => c.host == host && c.controlPort == controlPort);
  list.insert(
    0,
    SavedConnection(
      id: 'conn_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      host: host,
      controlPort: controlPort,
      videoPort: videoPort,
    ),
  );
  await _save(list);
  return list;
}

Future<List<SavedConnection>> removeSavedConnection(String id) async {
  final list = await loadSavedConnections();
  list.removeWhere((c) => c.id == id);
  await _save(list);
  return list;
}

Future<List<SavedConnection>> renameSavedConnection(String id, String name) async {
  final list = await loadSavedConnections();
  final idx = list.indexWhere((c) => c.id == id);
  if (idx >= 0) {
    final c = list[idx];
    list[idx] = SavedConnection(
      id: c.id, name: name, host: c.host,
      controlPort: c.controlPort, videoPort: c.videoPort,
    );
    await _save(list);
  }
  return list;
}
