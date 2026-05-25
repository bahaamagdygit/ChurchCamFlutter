# Church Cam (Flutter)

LAN-only mobile camera for the Church Live Stream desktop app. The phone streams
its camera to the desktop over local WiFi — **no internet required**. Control
flows both ways: the desktop operator can drive the phone camera (zoom, focus,
exposure, torch, flip, resolution, filters) and the phone can drive the desktop
(switch camera, slides, stream, recording, cut-to-black, reading overlay).

- Control channel: WebSocket on **port 8765**
- Video channel: raw TCP on **port 8766** (length-prefixed JPEG frames)
- Discovery: UDP beacons on **port 8767** (auto-find the desktop on the LAN)

---

## 1. Install Flutter (one time)

1. Download the Flutter SDK (stable) for Windows:
   https://docs.flutter.dev/get-started/install/windows
2. Unzip to a path with **no spaces**, e.g. `C:\flutter` (or `D:\flutter`).
3. Add `…\flutter\bin` to your **PATH** (System Environment Variables).
4. Open a new terminal and verify:
   ```powershell
   flutter --version
   flutter doctor
   ```
5. Accept Android licenses (needs Android SDK / Android Studio installed):
   ```powershell
   flutter doctor --android-licenses
   ```
6. If your Flutter SDK is **not** at `D:\flutter`, edit
   `android/local.properties` → `flutter.sdk=…`.

## 2. Find the desktop IP on Windows

On the desktop PC, open a terminal and run:
```powershell
ipconfig
```
Look under your active WiFi adapter for **IPv4 Address**, e.g. `192.168.1.42`.
That is the IP you scan/type on the phone. (The desktop app's Mobile Cameras
panel also shows a QR code that encodes this automatically.)

## 3. Enable "Unknown sources" on Android

To install an APK that isn't from the Play Store:
- Android 8+: when you tap the APK, Android prompts "Allow from this source" for
  the app you're installing from (Files / Chrome) → enable it.
- Or: Settings → Apps → Special access → **Install unknown apps** → pick your
  file manager → allow.

## 4. Generate the release keystore (already done once)

A keystore is already generated at `android/app/churchcam.keystore` and wired via
`android/key.properties`. To create your own instead:
```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -v `
  -keystore android\app\churchcam.keystore -storetype JKS -keyalg RSA -keysize 2048 `
  -validity 10000 -alias churchcam -storepass <PASS> -keypass <PASS> `
  -dname "CN=Church Cam, O=Church Live Stream, C=EG"
```
Then set the matching values in `android/key.properties`:
```
storePassword=<PASS>
keyPassword=<PASS>
keyAlias=churchcam
storeFile=churchcam.keystore
```
> `key.properties` and `*.keystore` are git-ignored — never commit them.

## 5. Build the APK

```powershell
cd D:\MyProjects\LiveStream\ChurchCamFlutter
flutter pub get
flutter build apk --release
```
Output (single universal APK):
```
build\app\outputs\flutter-apk\app-release.apk
```

## 6. Transfer & install the APK

**USB (adb):**
```powershell
C:\Users\<you>\AppData\Local\Android\Sdk\platform-tools\adb.exe install -r `
  build\app\outputs\flutter-apk\app-release.apk
```
**Without USB:** copy the APK to the phone (Drive / WhatsApp / USB MTP), tap it in
the Files app, allow unknown sources, install.

> If you see **"App not installed as package conflicts with an existing package"**,
> uninstall the old Church Cam first (Settings → Apps → Church Cam → Uninstall),
> then install the new APK. This happens when the signing key changed.

## 7. Using it

1. Start the desktop **Live** app and open its Mobile Cameras (📱) panel.
2. On the phone: tap the desktop under **"Found on this network"**, or tap
   **Scan QR**, or **Add Manually** and type the desktop IP.
3. Grant camera permission. The phone streams to the desktop.
4. **Camera** tab = preview + zoom/filters/torch/flip + pinch-zoom + tap-to-focus.
   **Control** tab = drive the desktop (slides, stream, recording, cut-to-black).
   **Settings** tab = device name, resolution, ports, disconnect.

---

## Troubleshooting

**Camera permission denied**
The app shows a dedicated screen with an "Open Settings" button. Grant Camera
permission there, then return to the app.

**Can't connect / "Could not reach"**
- Both devices must be on the **same WiFi** (and the network must allow
  device-to-device traffic — some guest/public WiFi blocks it).
- Confirm the desktop app is running and the IP is correct (`ipconfig`).
- Windows Firewall: allow inbound TCP **8765** and **8766** for the desktop app.
- Try the auto-discovered entry under "Found on this network" — it's always
  the current IP even if the desktop's IP changed.

**Video lag / stutter**
- The app auto-adapts quality to your WiFi (drops JPEG quality/FPS under load and
  raises them again when the link is clear).
- Move closer to the router or use 5GHz WiFi.
- Other heavy network use on the same WiFi competes for bandwidth.

**Image is rotated / sideways**
- Orientation is sensor-based and sent to the desktop on every rotation, and
  re-sent on reconnect. If it's ever stuck, rotate the phone once to resync, or
  disconnect/reconnect.

**White balance "unsupported" warning on the desktop**
- The Flutter `camera` plugin has no white-balance API, so the phone reports it
  as unsupported. All other controls (zoom, focus, exposure, torch, flip,
  resolution, filters) are supported.

---

## Architecture (quick map)

```
lib/
  main.dart                      app entry + routes (Connect → HomeShell)
  models/camera_filters.dart     8-param filters + color matrix + presets
  services/
    connection_service.dart      WebSocket control + TCP video + heartbeat + reconnect
    camera_service.dart          camera capture, controls, adaptive quality
    jpeg_encoder.dart            background isolate: YUV/BGRA → JPEG
    orientation_service.dart     accelerometer → 0/90/180/270
    discovery_service.dart       UDP beacon listener
    storage.dart                 shared_preferences: connections, settings, filters
  screens/
    connect_screen.dart          QR scan + discovery + saved + manual
    qr_scan_screen.dart          mobile_scanner full-screen
    home_shell.dart              bottom nav: Camera / Control / Settings
    camera_screen.dart           preview, filters, focus ring, pinch-zoom
    control_screen.dart          remote-control the desktop
    settings_screen.dart         device name, resolution, ports, disconnect
  widgets/
    connection_badge.dart        latency dot (green/yellow/red)
    filtered_preview.dart        ColorFiltered + blur overlay
    reading_overlay.dart         bottom reading-text bar
```

## Protocol summary

WebSocket (8765), JSON:
```
phone → { type:'hello', name, platform:'Android', capabilities, orientationAngle, zoom, filters }
desk  → { type:'welcome', deviceId, videoPort, streamStatus, recordingStatus, desktopCameras }
both  → { type:'ping'|'pong', t }                     # heartbeat / latency
desk  → { type:'command', action, value }             # zoom/focus/exposure/torch/flip/resolution/filters
phone → { type:'control_ack', control, value }        # applied confirmation
phone → { type:'control_error', control, reason }     # unsupported
phone → { type:'control', action, value }             # select_camera/set_zoom/next_slide/start_stream/cut_to_black/…
phone → { type:'orientation_change', angle }
desk  → { type:'reading_update', text, langs }
```
TCP (8766): 32-byte ASCII deviceId header, then repeating `[4-byte BE length][JPEG bytes]`.

> Note: action names use the desktop's vocabulary (`next_slide`, `start_stream`,
> `cut_to_black`, etc.) so controls work against the existing desktop app.
