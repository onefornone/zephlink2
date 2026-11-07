import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Android only: shares the phone screen (a JPEG picture several times a
/// second) and, if the person turned it on, lets the PC tap and swipe.
class AndroidScreen {
  static const MethodChannel _screen = MethodChannel('zephlink/screen');
  static const EventChannel _frames = EventChannel('zephlink/screen/frames');
  static const MethodChannel _control = MethodChannel('zephlink/control');
  static StreamSubscription<dynamic>? _frameSub;

  static bool get supported => Platform.isAndroid;

  /// Asks Android for permission and starts sending pictures to [onFrame].
  /// Returns null when it works, or a short reason when it does not.
  static Future<String?> start({
    required int maxSide,
    required int quality,
    required int fps,
    required void Function(Uint8List jpeg) onFrame,
    void Function()? onStopped,
    void Function()? onVideoFailed,
  }) async {
    if (!supported) return 'This is not an Android phone.';
    try {
      await _frameSub?.cancel();
      _frameSub = _frames.receiveBroadcastStream().listen((Object? event) {
        if (event is Uint8List) {
          onFrame(event);
        } else if (event == 'stopped') {
          onStopped?.call();
        } else if (event == 'h264-failed') {
          onVideoFailed?.call();
        }
      });
      final ok = await _screen.invokeMethod<bool>('start', <String, dynamic>{
        'maxSide': maxSide,
        'quality': quality,
        'fps': fps,
      });
      if (ok != true) {
        await stop();
        return 'Screen sharing was not allowed on this phone.';
      }
      return null;
    } on PlatformException catch (error) {
      await stop();
      return error.message ?? 'Could not start screen sharing.';
    } catch (_) {
      await stop();
      return 'Could not start screen sharing.';
    }
  }

  /// Switches the phone between small pictures ("jpeg") and H.264 video
  /// ("h264"). Returns false when the phone could not do it.
  static Future<bool> setCodec(String mode) async {
    if (!supported) return false;
    try {
      return await _screen.invokeMethod<bool>(
            'codec',
            <String, dynamic>{'mode': mode},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Asks the video encoder for a full picture, so a viewer can (re)start.
  static Future<void> requestKeyFrame() async {
    if (!supported) return;
    try {
      await _screen.invokeMethod<bool>('keyframe');
    } catch (_) {
      // Not sharing.
    }
  }

  /// Whether Zephlink may open screens while it is in the background.
  static Future<bool> overlayAllowed() async {
    if (!supported) return true;
    try {
      return await _control.invokeMethod<bool>('overlayAllowed') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openOverlaySettings() async {
    if (!supported) return;
    try {
      await _control.invokeMethod<bool>('openOverlaySettings');
    } catch (_) {
      // Settings did not open.
    }
  }

  /// Runs a one-tap action such as "lock" or "files". Returns null when it
  /// worked, or a short reason when it did not.
  static Future<String?> quick(String action, {String? argument}) async {
    if (!supported) return 'This is not an Android phone.';
    try {
      return await _control.invokeMethod<String>(
        'quick',
        <String, dynamic>{'a': action, 's': argument},
      );
    } catch (_) {
      return 'Could not do that.';
    }
  }

  /// The apps on this phone that have a launcher icon.
  static Future<List<Map<String, String>>> listApps() async {
    if (!supported) return const [];
    try {
      final raw = await _control.invokeMethod<List<dynamic>>('apps');
      final out = <Map<String, String>>[];
      for (final item in raw ?? const <dynamic>[]) {
        if (item is Map) {
          final label = item['label'];
          final pkg = item['pkg'];
          if (label is String && pkg is String) {
            out.add(<String, String>{'label': label, 'pkg': pkg});
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> stop() async {
    try {
      await _frameSub?.cancel();
      _frameSub = null;
      await _screen.invokeMethod<bool>('stop');
    } catch (_) {
      // Already stopped.
    }
  }

  /// True when the "Zephlink remote control" accessibility service is on.
  static Future<bool> controlEnabled() async {
    if (!supported) return false;
    try {
      return await _control.invokeMethod<bool>('enabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's Accessibility settings so the person can turn it on.
  static Future<void> openControlSettings() async {
    if (!supported) return;
    try {
      await _control.invokeMethod<bool>('openSettings');
    } catch (_) {
      // Not available.
    }
  }

  /// Carries out one tap, swipe, key or text message from the PC.
  static Future<void> apply(Map<String, dynamic> message) async {
    if (!supported) return;
    try {
      await _control.invokeMethod<bool>('apply', message);
    } catch (_) {
      // The service may have been turned off. Ignore.
    }
  }
}
