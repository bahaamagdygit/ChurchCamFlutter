import 'package:permission_handler/permission_handler.dart';

/// Ask for camera permission. Returns true if granted.
Future<bool> requestCameraPermission() async {
  final status = await Permission.camera.request();
  return status.isGranted;
}

/// Whether the user permanently denied camera access (need Settings).
Future<bool> isCameraPermanentlyDenied() async {
  return await Permission.camera.isPermanentlyDenied;
}

Future<void> openCameraSettings() async {
  await openAppSettings();
}
