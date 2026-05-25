import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/camera_filters.dart';

/// Wraps the camera preview with the current visual filters (Section 8).
/// The filter is purely visual — it never touches the streamed frames.
class FilteredPreview extends StatelessWidget {
  final Widget child;
  final CameraFilters filters;
  const FilteredPreview({super.key, required this.child, required this.filters});

  @override
  Widget build(BuildContext context) {
    Widget content = child;

    // Color matrix (brightness/contrast/saturation/hue/sepia/grayscale).
    if (!filters.isIdentity) {
      content = ColorFiltered(colorFilter: filters.colorFilter(), child: content);
    }

    // Blur overlay.
    if (filters.blur > 0) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: filters.blur, sigmaY: filters.blur),
            child: const SizedBox.expand(),
          ),
        ],
      );
    }

    // Opacity.
    if (filters.opacity < 100) {
      content = Opacity(opacity: (filters.opacity / 100).clamp(0.0, 1.0), child: content);
    }

    return content;
  }
}
