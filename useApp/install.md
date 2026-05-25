# Church Cam (Flutter) — Build & Install

## What was fixed / added
- **Crash on open:** the app declared `.MainActivity` in the manifest but the
  Kotlin class didn't exist → `ClassNotFoundException` on launch. Added
  `android/app/src/main/kotlin/com/churchcam/flutter/MainActivity.kt`.
- **Real camera streaming** (parity with ChurchCamApp): live preview, JPEG
  frame capture, zoom, flip front/back, torch, pinch-to-zoom, reading overlay.
- Uses the desktop **mobile-bridge** protocol:
  - Control WebSocket on port **8765** (`hello` → `welcome`, ping/pong, commands).
  - Video TCP on port **8766** (32-byte deviceId header, then 4-byte length-prefixed JPEG frames).

## Prerequisite (one-time)
Flutter SDK is **not installed** on this machine. Install it first:
1. Download Flutter (stable) from https://docs.flutter.dev/get-started/install/windows
2. Unzip to e.g. `C:\flutter`
3. Add `C:\flutter\bin` to your PATH, then open a new terminal and run:
   ```powershell
   flutter --version
   flutter doctor
   ```
4. If you unzipped somewhere other than `C:\flutter`, update:
   - `android/local.properties` → `flutter.sdk=...`
   - `build-apk.bat` → `set FLUTTER_PATH=...`

## Build the APK
```powershell
cd D:\MyProjects\LiveStream\ChurchCamFlutter
flutter pub get
flutter build apk --release
```
APK output: `build\app\outputs\apk\release\app-release.apk`

Or just run `build-apk.bat`.

## Install on a phone
USB (USB debugging on):
```powershell
adb install -r build\app\outputs\apk\release\app-release.apk
```
Or copy the APK to the phone and tap to install (allow "unknown sources").

## Use it
1. Start the desktop app (Live) — it listens on 8765/8766 and broadcasts on the LAN.
2. On the phone, enter the desktop's **Host IP** (shown in the desktop's mobile-camera
   QR/pairing panel), keep ports 8765 / 8766, tap **Connect**.
3. Tap **Go to Camera**, grant camera permission. The feed streams to the desktop;
   zoom/flip/torch can be driven from the phone or remotely from the desktop.

## Notes
- Both devices must be on the **same WiFi**. No internet required.
- If the firewall blocks it, allow inbound TCP 8765 & 8766 on the desktop.
