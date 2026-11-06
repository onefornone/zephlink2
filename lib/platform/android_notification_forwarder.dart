import 'dart:io';

import 'package:flutter/services.dart';

class AndroidNotificationForwarder {
  static const MethodChannel _channel =
      MethodChannel('zephlink/notification_forwarding');

  static bool get supported => Platform.isAndroid;

  static Future<bool> hasAccess() async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('hasAccess') ?? false;
  }

  static Future<void> openSettings() async {
    if (!supported) return;
    await _channel.invokeMethod<void>('openSettings');
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!supported) return;
    await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
  }

  static Future<List<Map<Object?, Object?>>> pending() async {
    if (!supported) return const [];
    final events = await _channel.invokeListMethod<Map<Object?, Object?>>(
          'pending',
        ) ??
        const [];
    return events;
  }

  static Future<void> acknowledge(String eventId) async {
    if (!supported) return;
    await _channel.invokeMethod<void>('acknowledge', {'eventId': eventId});
  }

  static Future<bool> reply(String id, String text) async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>(
          'reply',
          {'id': id, 'text': text},
        ) ??
        false;
  }

  static Future<bool> dismiss(String id) async {
    if (!supported) return false;
    return await _channel.invokeMethod<bool>('dismiss', {'id': id}) ?? false;
  }
}
