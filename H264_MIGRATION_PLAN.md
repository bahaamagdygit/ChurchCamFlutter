# Church Cam (Flutter) — H.264 Hardware Camera Pipeline Migration Plan

**Goal:** turn the phone into a broadcast-grade wireless studio camera over LAN —
1080p30, <150–250 ms latency, smooth fallback, drop-old-not-stale, full remote
control retained — **fully offline, no cloud**.

**Decisions (locked):** H.264 via Android **MediaCodec** over the existing **TCP**
video channel. **Flutter app only** (`ChurchCamFlutter`). Desktop decodes with
**WebCodecs `VideoDecoder`** (Chromium/Electron 28 ships it) and falls back to a
bundled **ffmpeg** decode path if WebCodecs is unavailable. WebSocket control
channel (8765) and UDP discovery (8767) are **unchanged**.

---

## 0. Confirmed scope (full performance + quality)

**IN — implement:**
- H.264 hardware encode (MediaCodec) → 1080p30 / 720p30 / 720p24 / 540p24 ladder.
- Configurable encoder: user-selectable resolution, FPS, and bitrate/quality
  (plus the automatic ABR ladder).
- Real low-latency, drop-old-not-stale, end-to-end backpressure + metrics.
- **White balance + ISO** manual controls (needs a Camera2-capable path; the
  current `camera` plugin lacks WB/ISO — see §12 below).
- **Wireless microphone** (phone audio → desktop), as its own sub-track with A/V
  sync — opt-in, scoped as a later phase.
- **Desktop-side green-screen / chroma key** on the received feed (done on the PC,
  not the phone — cheaper and higher quality).
- **Per-source still capture** on the desktop client.

**OUT — explicitly excluded (per product owner):**
- ❌ USB connection (Wi-Fi/LAN only).
- ❌ Virtual webcam driver (the desktop is the consumer; no other app needs it).
- ❌ 4K streaming (bandwidth/heat with no church-projector benefit; cap at 1080p).
- ❌ On-device face beautify and background blur/bokeh (wrong fit; green-screen is
  handled desktop-side instead).

---

## 1. Technical audit of the current pipeline

### 1.1 Capture + encode (the dominant bottleneck)
- `camera_service.dart` captures **YUV420** at `ResolutionPreset.medium` and hands
  every frame to `jpeg_encoder.dart`, a Dart isolate running the pure-Dart
  `image` package (`encodeJpg`).
- To survive, it is forced down to **854 px wide, quality 60, 24 fps** caps
  (`_maxOutWidth=854`, `_jpegQuality=60`, `_targetFps=24`). This is an
  **architectural ceiling**, not a tuning choice: software YUV→RGB→JPEG in Dart
  cannot do 1080p30 without multi-hundred-ms latency and thermal throttling.
- Single-frame-in-flight backpressure (`_frameInFlight`) is good and worth
  keeping conceptually — but it means whenever an encode is slow, frames are
  *dropped at the source*, capping effective FPS well below target.
- **CPU/battery/thermal:** per-pixel Dart math on the CPU is the worst case for
  power draw and heat. Hardware H.264 moves this to the dedicated encoder block —
  ~5–10× less CPU and far less heat for the same picture.

### 1.2 Wire format + transport
- Video channel: raw TCP, `[4-byte BE length][JPEG]`, prefixed once by a 32-byte
  ASCII deviceId header. Each JPEG is a full independent image (no inter-frame
  compression) → **5–10× the bitrate of H.264** for equal quality. This is why
  WiFi congestion shows up so fast.
- `connection_service.dart` `sendFrame()` already does a single contiguous write
  and tracks `_pendingBytes` for backpressure — solid foundation we reuse.
- **TCP latency spikes:** with MJPEG, one large frame (low-compressibility scene)
  can momentarily saturate the link; `tcpNoDelay` is set (good), but there is no
  pacing, so a burst can stall the next control message's RTT measurement.

### 1.3 Frame freshness / queue
- Native (Dart) side: no queue — drop-on-busy. Good.
- **Desktop side: this is where stale frames live.** `mobile-bridge.ts` fans the
  JPEG bytes straight into a `multipart/x-mixed-replace` MJPEG response, and the
  renderer draws it via `<img>`/canvas. The browser's MJPEG `<img>` decoder
  buffers internally and can lag behind real time under load; there is no
  "latest-frame-wins" guarantee on the consumer.

### 1.4 Backpressure
- Phone→OS backpressure exists (`_pendingBytes`, `canAcceptFrame`). But there is
  **no end-to-end backpressure**: the desktop never tells the phone "I am behind,
  slow down." Adaptive quality is driven purely by the phone's local socket
  backlog, which only sees the *send* side of the link, not the *receive*/decode
  side.

### 1.5 Jitter / latency control
- Latency is measured only on the **control** WS via ping/pong RTT. The **video**
  path has no timestamping, so the displayed-frame age (the number that actually
  matters for "is this live?") is unknown. No jitter buffer, no frame-age metric.

### 1.6 Metrics
- Phone reports `framesSent` / `framesDropped` / control RTT. Missing: encode
  time, send bitrate, **video** end-to-end latency, decode FPS on desktop,
  desktop dropped/late frames.

### Audit verdict
The single highest-impact change is **replace pure-Dart JPEG with hardware
H.264 (MediaCodec)**. Everything else (ABR, metrics, latest-frame decode) is
multiplicative on top of that. Keeping TCP (not UDP/RTP) is the right call for a
church LAN: simpler, reliable, no packet-loss recovery to build, and on a quiet
local network TCP adds negligible latency when frames are paced and small.

---

## 2. Recommended architecture

```
PHONE (Flutter + Kotlin)                         DESKTOP (Electron + React)
┌──────────────────────────────┐                 ┌───────────────────────────────┐
│ Camera2/CameraX  ─ Surface ─▶ │                 │ TCP receiver (mobile-bridge)  │
│ MediaCodec H.264 HW encoder   │                 │  splits NAL/AU frames         │
│  (Surface input, no copy)     │                 │  newest-AU-wins fan-out       │
│        │ AnnexB AUs           │   TCP 8766      │        │                      │
│        ▼                      │  ───────────▶   │        ▼                      │
│ Native sender (drop-old,      │  length+ts+key  │ WebCodecs VideoDecoder        │
│  paced, backpressure)         │   framed AUs    │  (fallback: ffmpeg pipe)      │
│        ▲                      │   ◀───────────  │        │ VideoFrame           │
│ ABR controller ◀ WS feedback  │   WS 8765       │        ▼                      │
│        │                      │  rx_stats msgs  │ canvas draw (latest only)     │
│ ConnectionService (WS ctrl)   │  ◀───────────▶  │ metrics overlay               │
└──────────────────────────────┘                 └───────────────────────────────┘
```

**Key properties**
- **Hardware encode** via `MediaCodec` with a **Surface** input wired directly to
  the camera — zero CPU pixel copies. Target 1080p30 @ 4–6 Mbps VBR.
- **New framed wire format** on the same TCP port, versioned, carrying frame
  type (key/delta), capture timestamp (for latency), and codec config (SPS/PPS).
- **Desktop decodes with WebCodecs** → real `VideoFrame`s drawn to canvas;
  **latest-frame-wins** so a slow paint never shows stale video.
- **End-to-end ABR:** desktop sends periodic `rx_stats` (decode FPS, queue depth,
  frame age) over the WS; phone's ABR fuses that with local socket backlog to
  pick bitrate/resolution/FPS.
- **Backward compatible rollout:** a `videoCodec` field in the `hello`/`welcome`
  handshake negotiates `h264` vs legacy `mjpeg`, so we can ship incrementally and
  keep a known-good fallback.

---

## 3. Step-by-step implementation plan (phased)

**Phase 0 — Non-breaking quick wins (ship first, still MJPEG).**
Lock in correctness + visibility before changing the codec.
- Desktop: guarantee latest-frame-wins on the consumer (coalesce MJPEG paints).
- Phone: richer metrics plumbing (encode ms, send bitrate) — fields only.
- Add a `videoCodec` capability to the handshake (defaults to `mjpeg`; no behavior
  change yet).
- **Verify:** existing MJPEG still works exactly as today.

**Phase 1 — Protocol v2 framing (dual-codec).**
- Define the framed AU wire format (below). Implement encode/parse on both ends
  behind the negotiated `videoCodec`. MJPEG path untouched.

**Phase 2 — Android MediaCodec encoder (Kotlin platform channel).**
- Add a Kotlin `H264Encoder` driven by a `MethodChannel`/`EventChannel`. Camera
  feeds its Surface; encoder emits Annex-B AUs to the Dart sender.

**Phase 3 — Flutter integration.**
- `camera_service.dart` switches, when `h264` is negotiated, from the Dart JPEG
  isolate to the native encoder. `connection_service.dart` sends v2 frames.

**Phase 4 — Desktop WebCodecs decoder + receiver.**
- `mobile-bridge.ts` parses v2 frames, newest-AU-wins. A new renderer component
  decodes via `VideoDecoder` and draws the newest `VideoFrame`. ffmpeg fallback.

**Phase 5 — ABR + metrics + reconnect polish.**
- `rx_stats` feedback loop, full metrics overlay (latency/FPS/bitrate/dropped/
  quality), non-blocking reconnect that keeps preview alive.

Each phase builds + runs against the real desktop before the next begins.

---

## 4. Wire format — Protocol v2 (framed access units)

One TCP stream, after the existing 32-byte deviceId header. Each frame:

```
 offset  size  field
   0      1    magic      = 0xCB  (Church Bridge v2 marker; distinguishes from MJPEG)
   1      1    type       = 0:config(SPS/PPS) 1:keyframe(IDR) 2:delta
   2      2    reserved/flags (BE)         (bit0 = mirror, bits for rotation 0/90/180/270)
   4      8    captureTsUs (BE)            phone monotonic capture time, microseconds
  12      4    payloadLen (BE)
  16      N    payload    = Annex-B AU bytes (or SPS+PPS for type 0)
```

- `captureTsUs` lets the desktop compute **video latency** = nowUs − captureTsUs
  (after a one-time clock-offset handshake; see §10).
- `type 0` (config) is sent on connect and on every encoder reconfig (resolution
  change) so a freshly-attached desktop decoder can initialize.
- Rotation/mirror travel in flags so the desktop bakes them into the draw exactly
  like the current canvas does (consistent with the main-preview fix already in
  place).

Legacy MJPEG frames begin with a 4-byte length whose top byte is a JPEG SOI-ish
value never equal to `0xCB`, so the receiver can sniff v2 vs legacy if needed —
but negotiation via the handshake is the primary switch.

---

## 5. Adaptive bitrate / resolution / FPS strategy

Three-tier ladder; the controller moves **one step at a time**, fast down / slow up:

| Tier | Resolution | FPS | H.264 bitrate |
|------|-----------|-----|---------------|
| T0   | 1920×1080 | 30  | 6 Mbps        |
| T1   | 1280×720  | 30  | 3 Mbps        |
| T2   | 1280×720  | 24  | 2 Mbps        |
| T3   | 960×540   | 24  | 1.2 Mbps      |

Inputs to the controller (each ~500 ms):
- **local**: socket `_pendingBytes` backlog (already tracked).
- **remote** (`rx_stats` over WS): desktop decode FPS, decoder queue depth, mean
  frame age, dropped-late count.

Rules:
- Backlog high **or** desktop frame-age rising **or** decode FPS << target → step
  **down** immediately.
- All-clear for 3 consecutive windows → step **up** one tier.
- Bitrate changes are cheap (`MediaCodec` dynamic `setParameters` /
  `PARAMETER_KEY_VIDEO_BITRATE`); resolution changes require an encoder reconfig +
  fresh `config` frame (do this sparingly, only across T-boundaries that change
  resolution).
- Always request a **keyframe** right after any reconfig and after a reconnect.

---

## 6. Frame queue & backpressure strategy

- **Phone:** keep single-frame-in-flight at the *sender* (one AU buffered max). On
  overflow, drop the **oldest** delta; never drop a keyframe/config. Coalesce so
  the newest AU always wins.
- **TCP:** pace sends to the negotiated FPS; rely on socket-writable +
  `_pendingBytes` ceiling for hard backpressure.
- **Desktop receiver:** maintain a 1-deep "pending AU" slot per device. If a new
  AU arrives before the decoder consumed the last delta, **replace** it (newest
  wins) — except never drop `config`/keyframe (those gate decodability).
- **Desktop decoder→paint:** draw only the most recent `VideoFrame`; if rAF is
  behind, skip intermediate frames (close older `VideoFrame`s to free GPU memory).

This is the "drop old, not stale" guarantee end to end.

---

## 7. Reconnect & heartbeat strategy

- Keep the existing WS ping/pong (1 s, 3-miss → reconnect) and exponential
  backoff (500 ms→5 s). It's good.
- **Decouple preview from transport:** the camera preview + encoder keep running
  during a reconnect so the UI never freezes; only the *sender* pauses. On video
  socket re-open, send `config` + force a keyframe before resuming deltas.
- Desktop: on video socket drop, hold the last frame briefly then show the
  existing frozen-frame fallback (already implemented) — no change to that UX.
- Make video-socket reconnect independent of control-socket reconnect (already
  partially true) and ensure neither blocks the Flutter UI isolate.

---

## 8. Latency measurement strategy

- **Control RTT** (have it): WS ping/pong.
- **Video latency** (new): one-time clock-offset exchange — phone sends
  `clock_sync{t0}` , desktop replies `{t0, t1}`; phone computes offset like NTP.
  Thereafter desktop latency = `nowUs − (captureTsUs + offset)`. Show as the
  headline "X ms" with green/yellow/red thresholds (≤150 / ≤250 / >250).
- **Decode FPS / frame age**: measured on desktop from `VideoFrame.timestamp`
  cadence; reported back in `rx_stats` and shown in the metrics overlay.

---

## 9. Metrics surfaced (both ends)

Phone overlay + desktop overlay show: **latency (video + control), FPS (capture/
encode/decode), bitrate (kbps), dropped frames (src + late-at-sink), connection
quality** (fused score → excellent/good/fair/poor). All already have partial
plumbing; we complete the missing fields.

---

## 10. Risks & mitigations

- **Device MediaCodec quirks** (color formats, Surface vs ByteBuffer): use
  Surface input (most compatible), query supported profiles, fall back to T1 if
  1080p encode init fails on a given device.
- **WebCodecs availability** in the Electron version: Electron 28 = Chromium 120,
  which has `VideoDecoder`. Keep an ffmpeg-pipe fallback decoder for safety.
- **Rollout safety:** everything gated behind `videoCodec` negotiation; MJPEG
  stays as the guaranteed fallback until H.264 is proven on the operator's
  devices.

---

## 11. Where the sample code lives

Phase 2/4 will introduce these files (sketched in this plan's companion sections
when each phase starts):
- `android/app/src/main/kotlin/.../H264Encoder.kt` — MediaCodec, Surface input.
- `android/app/src/main/kotlin/.../CameraH264Channel.kt` — platform channel glue.
- `lib/services/h264_sender.dart` — v2 framing + drop-old sender.
- `lib/services/video_metrics.dart` — latency/FPS/bitrate aggregation.
- `electron/h264-receiver.ts` (or extend `mobile-bridge.ts`) — v2 parser,
  newest-AU-wins.
- `src/components/MobileH264View.tsx` — WebCodecs `VideoDecoder` → canvas.
- `src/hooks/useAbrController.ts` (phone side mirrors in Dart) — ladder logic.

---

## Implementation status (live)

**Built + compiles (desktop `tsc`/`vite` clean, `dart analyze` clean):**
- ✅ Phase 0 — `videoCodec` handshake negotiation; desktop latest-frame-wins
  fan-out; metric fields (send bitrate, encode ms, measured FPS).
- ✅ Phase 1 — v2 framed wire format. Desktop `electron/video-protocol.ts` +
  Dart `lib/services/video_protocol.dart` (byte-identical). Unified
  `VideoStreamParser` on the desktop demuxes legacy MJPEG + v2; parser proven
  against a mixed stream split on pathological 7-byte boundaries.
- ✅ Phase 4 — desktop H.264 path: receiver forwards AUs over IPC
  (`mobile-h264-au`), `getH264Config` for mid-stream attach, and
  `src/components/MobileH264View.tsx` (WebCodecs `VideoDecoder`, latest-frame
  draw matching MJPEG framing). Wired into MainPreview **and** PresentationApp,
  branched on `videoCodec === 'h264'`.
- ✅ Phase 2 — Android `H264Encoder.kt` (MediaCodec, ByteBuffer YUV input,
  Annex-B AU output, dynamic bitrate, keyframe request) + `MainActivity.kt`
  Method/EventChannel glue.
- ✅ Phase 3 — Flutter: `h264_encoder_channel.dart`, `camera_service.setH264Mode`
  (routes YUV to native encoder, bypassing the Dart JPEG isolate),
  `connection_service.sendV2Frame`, and `camera_screen` wiring. Phone advertises
  `['h264','mjpeg']`.

**ACTIVATION GATE (one line):** the desktop still sets
`SUPPORTED_VIDEO_CODECS = ['mjpeg']`, so every session negotiates MJPEG and the
H.264 path stays dormant. Flip to `['h264','mjpeg']` in
`electron/mobile-bridge.ts` to turn it on. Until then, **nothing changes** for
existing users — the entire H.264 path is wired but inert.

**On-device validation required (cannot be verified from source):**
- MediaCodec init at the chosen resolution on the operator's actual phone(s).
- The NV12 pack in `H264Encoder.packYuv` vs the device's real plane strides
  (some devices deliver semi-planar UV; if colors are swapped/garbled this is the
  first place to look).
- WebCodecs decode of the device's exact SPS/PPS (the avc1 codec string is
  derived from the SPS; if `configure` rejects it, log the bytes).
- End-to-end latency target (<150–250 ms) and the per-frame `MethodChannel`
  overhead (if it dominates, move encode intake to a host-side `ImageReader`
  Surface in a later pass).

- ✅ Phase 5 — complete:
  - **5a Reconnect:** `connection_service.onVideoReady` fires on every video
    socket (re)connect → `camera_screen` calls `requestH264Keyframe()` so a
    freshly-attached desktop decoder initializes without a stall.
  - **5b ABR:** `lib/services/abr_controller.dart` ladder (1080p30→720p30→720p24→
    540p24), fast-down/slow-up. Desktop `MobileH264View` measures decode FPS +
    decoder queue depth and reports `rx_stats` (renderer→`mb-send-rx-stats`→
    `bridge.sendRxStats`→WS). Phone fuses with local socket backlog and restarts/
    retunes the native encoder (`setH264Mode`/`updateH264Bitrate`).
  - **5c Metrics HUD:** `lib/widgets/metrics_overlay.dart` — latency, FPS,
    bitrate, encode ms, dropped frames, codec/quality, link grade. Tap the
    connection badge to toggle.

**Verified:** APK assembles (release, exit 0); `dart analyze lib/` clean (only a
pre-existing `settings_screen` deprecation); desktop `tsc` + `vite build` clean.

**Still TODO (on-device, then optional polish):**
- Flip the ACTIVATION GATE and test on a real phone (see below).
- frameAgeMs in `rx_stats` is currently 0 ("unknown") — wiring the NTP-style
  clock-sync (plan §8) makes the ABR age-aware and powers a true end-to-end
  video-latency number in the HUD.
- "Later" features: white balance + ISO (Camera2 path), wireless mic,
  desktop green-screen, per-source still capture.

### How to activate + test (on-device)
1. In `electron/mobile-bridge.ts` set
   `SUPPORTED_VIDEO_CODECS = ['h264', 'mjpeg']` and rebuild the desktop.
2. Install the release APK on the phone, connect to the desktop. The handshake
   negotiates `h264`; the phone starts the MediaCodec encoder; the desktop
   decodes via WebCodecs. If anything fails, it auto-falls-back to MJPEG.
3. Watch for: correct colors (NV12 pack vs device strides), decode init (SPS
   parse), latency < 250 ms, and the ABR ladder reacting when you stress WiFi.

## Recommendation on sequencing

Start with **Phase 0** (non-breaking): it ships value immediately (guaranteed
latest-frame on desktop + metric fields + handshake negotiation) with zero risk
to the working MJPEG path, and it lays the handshake groundwork that all later
phases switch on. Then proceed Phase 1→5, building and verifying against the real
desktop at each gate.
```
