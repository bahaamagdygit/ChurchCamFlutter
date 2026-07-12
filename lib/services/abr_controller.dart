import 'package:flutter/foundation.dart';

/// One rung of the adaptive ladder (matches H264_MIGRATION_PLAN §5).
class AbrTier {
  final int width;
  final int height;
  final int fps;
  final int bitrate; // bps
  final String label;
  const AbrTier(this.label, this.width, this.height, this.fps, this.bitrate);
}

const List<AbrTier> kAbrLadder = [
  AbrTier('4K60',   3840, 2160, 60, 30000000), // T0 — highest (needs strong link)
  AbrTier('4K30',   3840, 2160, 30, 20000000), // T1
  AbrTier('2K60',   2560, 1440, 60, 18000000), // T2
  AbrTier('2K30',   2560, 1440, 30, 12000000), // T3
  AbrTier('1080p60', 1920, 1080, 60, 8000000), // T4
  AbrTier('1080p30', 1920, 1080, 30, 6000000), // T5
  AbrTier('720p60', 1280, 720, 60, 4500000), //  T6
  AbrTier('720p30', 1280, 720, 30, 3000000), //  T7
  AbrTier('480p30', 854, 480, 30, 1500000), //   T8
  AbrTier('360p30', 640, 360, 30, 900000), //    T9
];

/// Ladder index for a given (longEdge, fps) — the user's Settings choice becomes
/// the starting tier. ABR only steps DOWN from here under congestion.
int _tierIndexFor(int longEdge, int fps) {
  final want60 = fps >= 60;
  int best = kAbrLadder.length - 1;
  for (int i = 0; i < kAbrLadder.length; i++) {
    final t = kAbrLadder[i];
    if (t.width <= longEdge && (t.fps >= 60) == want60) { best = i; break; }
    if (t.width <= longEdge) best = i; // fps fallback if exact 60/30 not found
  }
  return best;
}

/// Receive-side stats the desktop reports over the WS (`rx_stats`).
class RxStats {
  final double decodeFps;
  final int queueDepth; // decoder.decodeQueueSize
  final double frameAgeMs; // mean displayed-frame age
  const RxStats({this.decodeFps = 0, this.queueDepth = 0, this.frameAgeMs = 0});
}

/// Fuses local socket backlog with desktop receive stats to pick a ladder tier.
/// Fast down (one window), slow up (3 clear windows). Bitrate-only moves are
/// applied live; resolution/fps moves require an encoder restart, signalled via
/// [onTierChange] (the camera service restarts the encoder), while pure-bitrate
/// nudges go through [onBitrate].
class AbrController extends ChangeNotifier {
  AbrController({
    required this.onTierChange,
    required this.onBitrate,
    int startTier = 1, // default 720p30
  }) : _tierIndex = startTier.clamp(0, kAbrLadder.length - 1);

  /// Ladder index matching the user's Settings choice (starting tier).
  static int tierForLongEdge(int longEdge, int fps) => _tierIndexFor(longEdge, fps);

  /// Restart encoder at a new resolution/fps tier.
  final void Function(AbrTier tier) onTierChange;

  /// Apply a live bitrate change within the current tier.
  final void Function(int bitrate) onBitrate;

  int _tierIndex;
  int _clearStreak = 0;
  RxStats _lastRx = const RxStats();

  AbrTier get tier => kAbrLadder[_tierIndex];
  int get tierIndex => _tierIndex;
  RxStats get lastRx => _lastRx;

  void updateRxStats(RxStats rx) {
    _lastRx = rx;
  }

  /// Called every ~1s with the phone's current send backlog (un-flushed bytes).
  /// Returns true if a tier (resolution) change happened.
  bool tick({required int pendingBytes, required int targetFps}) {
    final rx = _lastRx;

    // Congestion signals (any one trips a step-down):
    //  • local socket backlog over ~1 frame worth
    //  • desktop decode FPS far below target (can't keep up)
    //  • desktop decoder queue building (frames arriving faster than decode)
    //  • displayed-frame age climbing (latency growing)
    final backlogHigh = pendingBytes > 200 * 1024;
    final decodeStarved = rx.decodeFps > 0 && rx.decodeFps < targetFps * 0.6;
    final queueBuilding = rx.queueDepth > 3;
    final ageHigh = rx.frameAgeMs > 350;

    final congested = backlogHigh || decodeStarved || queueBuilding || ageHigh;
    final allClear = pendingBytes < 50 * 1024 &&
        (rx.decodeFps == 0 || rx.decodeFps >= targetFps * 0.9) &&
        rx.queueDepth <= 1 &&
        (rx.frameAgeMs == 0 || rx.frameAgeMs < 200);

    if (congested) {
      _clearStreak = 0;
      if (_tierIndex < kAbrLadder.length - 1) {
        _tierIndex++;
        debugPrint('[ABR] step DOWN → ${tier.label} '
            '(backlog=${(pendingBytes / 1024).round()}KB decFps=${rx.decodeFps.toStringAsFixed(1)} '
            'q=${rx.queueDepth} age=${rx.frameAgeMs.toStringAsFixed(0)}ms)');
        onTierChange(tier);
        notifyListeners();
        return true;
      }
      // Already at the floor — shave bitrate further as a last resort.
      final reduced = (tier.bitrate * 0.85).round();
      onBitrate(reduced);
      return false;
    }

    if (allClear) {
      _clearStreak++;
      if (_clearStreak >= 3 && _tierIndex > 0) {
        _clearStreak = 0;
        _tierIndex--;
        debugPrint('[ABR] step UP → ${tier.label} (link clear)');
        onTierChange(tier);
        notifyListeners();
        return true;
      }
    } else {
      _clearStreak = 0;
    }
    return false;
  }
}
