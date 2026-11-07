import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Shows an H.264 video stream from the other device.
///
/// This is the "simple" version that is used when the smooth-video player is
/// not part of the build. It never starts, so Zephlink uses small JPEG
/// pictures instead. The Windows build swaps in a real player (see
/// platform/windows/h264_viewer.dart and the Windows part of the workflow).
class H264Viewer {
  H264Viewer({this.onNeedKeyFrame});

  /// Whether this build can play H.264 at all.
  static bool get available => false;

  /// Called when the player needs a fresh full picture from the sender.
  final void Function()? onNeedKeyFrame;

  /// Size of the video once it is known.
  final ValueNotifier<Size?> size = ValueNotifier<Size?>(null);

  /// True once the first picture is on screen.
  bool get hasPicture => false;

  Future<bool> start() async => false;

  /// Adds the next piece of video. [key] is true for a full picture.
  void add(Uint8List data, bool key) {}

  Widget buildView() => const SizedBox.shrink();

  Future<void> dispose() async {
    size.dispose();
  }
}
