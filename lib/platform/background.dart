import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the app alive on Android with a small notification (a foreground
/// service), so the link survives the screen turning off.
class BackgroundKeeper {
  static const MethodChannel _channel = MethodChannel('zephlink/keepalive');

  static bool get supported => Platform.isAndroid;

  static Future<void> start() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('start');
    } catch (_) {
      // Not available (for example in tests).
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      // Not available.
    }
  }

  /// True when Android will not stop the app to save battery.
  static Future<bool> batteryUnrestricted() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('batteryExempt') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks Android to let the app run in the background without limits.
  static Future<void> requestBatteryUnrestricted() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('requestBatteryExempt');
    } catch (_) {
      // Not available.
    }
  }
}

/// "Start with Windows" by putting a shortcut in the Startup folder.
class WindowsStartup {
  static bool get supported => Platform.isWindows;

  static String? get _shortcutPath {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    return '$appData\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\Zephlink.lnk';
  }

  static Future<bool> isEnabled() async {
    final path = _shortcutPath;
    if (!supported || path == null) return false;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Returns true if the change worked.
  static Future<bool> setEnabled(bool enabled) async {
    final path = _shortcutPath;
    if (!supported || path == null) return false;
    try {
      if (!enabled) {
        final file = File(path);
        if (await file.exists()) await file.delete();
        return true;
      }
      final exe = Platform.resolvedExecutable;
      final folder = File(exe).parent.path;
      String quote(String v) => "'${v.replaceAll("'", "''")}'";
      final script = '\$s = (New-Object -ComObject WScript.Shell)'
          '.CreateShortcut(${quote(path)}); '
          '\$s.TargetPath = ${quote(exe)}; '
          '\$s.Arguments = \'--minimized\'; '
          '\$s.WorkingDirectory = ${quote(folder)}; '
          '\$s.Save()';
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
