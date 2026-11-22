import 'dart:io';

import 'package:flutter/services.dart';

/// Phone-only: text messages and calls, for the linked PC.
class AndroidPhone {
  static const MethodChannel _channel = MethodChannel('zephlink/phone');
  static bool _bound = false;

  /// Called when a text arrives or a call rings, starts or ends.
  static void Function(Map<String, dynamic> event)? onEvent;

  static bool get supported => Platform.isAndroid;

  static void bind() {
    if (_bound || !supported) return;
    _bound = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is Map) {
        onEvent?.call(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
  }

  /// Which groups ("sms", "calls", "contacts") Android has allowed.
  static Future<Map<String, bool>> perms() async {
    if (!supported) return const {};
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('perms');
      return <String, bool>{
        for (final entry in (raw ?? const <Object?, Object?>{}).entries)
          entry.key.toString(): entry.value == true,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Shows Android's permission question for [group]. True when allowed.
  static Future<bool> request(String group) async {
    if (!supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('request', <String, dynamic>{'group': group})
              .timeout(const Duration(seconds: 90)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> conversations(int limit) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'conversations',
      <String, dynamic>{'limit': limit},
    );
    return [
      for (final item in raw ?? const <Map<Object?, Object?>>[])
        Map<String, dynamic>.from(item),
    ];
  }

  static Future<List<Map<String, dynamic>>> thread(int thread, int limit) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'thread',
      <String, dynamic>{'thread': thread, 'limit': limit},
    );
    return [
      for (final item in raw ?? const <Map<Object?, Object?>>[])
        Map<String, dynamic>.from(item),
    ];
  }

  /// Sends a text. Null when sent, else a short reason.
  static Future<String?> send(String to, String text) async {
    try {
      return await _channel.invokeMethod<String>(
        'send',
        <String, dynamic>{'to': to, 'text': text},
      );
    } on PlatformException catch (error) {
      return error.message ?? 'Could not send.';
    }
  }

  static Future<String?> answer() async {
    try {
      return await _channel.invokeMethod<String>('answer');
    } on PlatformException catch (error) {
      return error.message ?? 'Could not answer.';
    }
  }

  static Future<String?> reject() async {
    try {
      return await _channel.invokeMethod<String>('reject');
    } on PlatformException catch (error) {
      return error.message ?? 'Could not decline.';
    }
  }
}
