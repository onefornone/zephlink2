import 'dart:io';

import 'package:flutter/services.dart';

/// Phone-only helpers used by "Find my phone" and "Browse files".
class AndroidTools {
  static const MethodChannel _channel = MethodChannel('zephlink/tools');

  static bool get supported => Platform.isAndroid;

  /// Rings loudly, even when the phone is on silent.
  static Future<bool> ring(int seconds) async {
    if (!supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('ring', <String, dynamic>{'seconds': seconds}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopRing() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('stopRing');
    } catch (_) {
      // Nothing to stop.
    }
  }

  /// Battery percent (or -1) and whether the phone is charging.
  static Future<Map<String, dynamic>> battery() async {
    if (!supported) return <String, dynamic>{'pct': -1, 'charging': false};
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('battery');
      final pct = raw?['pct'];
      final charging = raw?['charging'];
      return <String, dynamic>{
        'pct': pct is int ? pct : -1,
        'charging': charging == true,
      };
    } catch (_) {
      return <String, dynamic>{'pct': -1, 'charging': false};
    }
  }

  /// True when Zephlink may read the phone's files ("All files access").
  static Future<bool> filesAllowed() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('filesAllowed') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openFilesAccess() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('openFilesAccess');
    } catch (_) {
      // Not available.
    }
  }

  /// Internal storage and any SD card or USB drive.
  static Future<List<Map<String, String>>> roots() async {
    if (!supported) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('roots');
      final out = <Map<String, String>>[];
      for (final item in raw ?? const <dynamic>[]) {
        if (item is Map && item['name'] is String && item['path'] is String) {
          out.add(<String, String>{
            'name': item['name'] as String,
            'path': item['path'] as String,
          });
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
