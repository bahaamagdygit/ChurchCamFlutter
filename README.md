# Church Cam Flutter

A professional Flutter-based mobile app for church live streaming with camera feed control.

## Features

✅ **WebSocket Control Channel** - Bidirectional communication with desktop app
✅ **TCP Video Streaming** - Efficient video frame transmission
✅ **Auto-Reconnection** - Automatic retry with exponential backoff
✅ **Real-time Latency** - Live latency monitoring
✅ **Frame Statistics** - Track sent and dropped frames
✅ **Cross-Platform** - iOS and Android support
✅ **LAN & WAN Support** - Works on local network and internet
✅ **Permission Handling** - Proper camera and network permission management

## Setup Instructions

### Prerequisites

1. **Flutter SDK** - Download from [flutter.dev](https://flutter.dev/docs/get-started/install)
2. **Android SDK** - API level 21+ (minSdkVersion: 21)
3. **Desktop App** - Running on the same network

### Installation

1. **Navigate to project directory**
   ```bash
   cd D:\MyProjects\LiveStream\ChurchCamFlutter
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Run the app**
   ```bash
   flutter run
   ```

   Or build APK:
   ```bash
   flutter build apk --release
   ```

### Configuration

**Local Properties** - Create `local.properties`:
```properties
sdk.dir=C:\\Users\\PC\\AppData\\Local\\Android\\Sdk
flutter.sdk=C:\\path\\to\\flutter
```

## Architecture

### Services

**ConnectionService** (`lib/services/connection_service.dart`)
- Manages WebSocket control channel (port 8765)
- Manages TCP video socket (port 8766)
- Handles auto-reconnection with exponential backoff
- Provides latency monitoring

### Screens

**ConnectScreen** - Connection setup and status
- IP/port configuration
- Connection status display
- Error handling with helpful messages

**CameraScreen** - Live camera feed
- Real-time camera preview
- Connection status indicator
- Frame statistics display

## Protocol

### WebSocket (Port 8765)

```json
// Hello handshake
{ "type": "hello", "name": "Mobile Camera (Flutter)", "orientationAngle": 0, "capabilities": {} }

// Welcome response
{ "type": "welcome", "deviceId": "dev_..." }

// Heartbeat
{ "type": "ping", "t": 1234567890 }
{ "type": "pong", "t": 1234567890 }
```

### TCP Video (Port 8766)

1. Send **32-byte ASCII deviceId header**
2. Send frames with **4-byte big-endian length prefix**
3. Frame format: `[4-byte length][JPEG data][4-byte length][JPEG data]...`

## Troubleshooting

### "Can't reach the desktop"
- ✓ Both devices on same WiFi
- ✓ Desktop app is running  
- ✓ IP address is correct
- ✓ Firewall allows ports 8765 & 8766

### Camera permission denied
- Grant camera permission in app settings
- Check `AndroidManifest.xml` has `CAMERA` permission

### Video streaming not working
- Check network connectivity
- Verify desktop app is listening on port 8766
- Check logs for error details

## Building for Production

```bash
# Build signed APK
flutter build apk --release

# Build App Bundle (for Play Store)
flutter build appbundle --release
```

APK location: `build/app/outputs/apk/release/app-release.apk`

## Dependencies

- **camera** - Camera access and preview
- **web_socket_channel** - WebSocket communication
- **provider** - State management
- **permission_handler** - Runtime permissions
- **logger** - Logging utility
- **shared_preferences** - Local storage

## Performance

- **Latency**: Real-time monitoring via heartbeat pings
- **Frame Rate**: Configurable based on network conditions
- **Auto-Reconnection**: Exponential backoff (1s, 2s, 4s, 8s, 16s max)
- **Resource Usage**: Minimal CPU/memory footprint

## Known Limitations

- Max 5 reconnection attempts (configurable)
- Frame queue capacity: 2 frames (prevents latency buildup)
- Video frames are dropped under poor WiFi (graceful degradation)

## Future Enhancements

- [ ] Frame compression optimization
- [ ] Adaptive bitrate streaming
- [ ] Multi-camera support
- [ ] Recording capability
- [ ] Remote PTZ control
- [ ] iOS optimization

## Support

For issues or questions, check:
1. Connection logs in console
2. Desktop app configuration
3. Network settings
4. Firewall rules

## License

Proprietary - Church Live Stream Studio
