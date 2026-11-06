import 'dart:io';

import 'package:flutter/services.dart';

class AndroidReceivedFile {
  const AndroidReceivedFile({
    required this.name,
    required this.uri,
    required this.size,
  });

  final String name;
  final String uri;
  final int size;
}

class AndroidReceivedFiles {
  static const MethodChannel _channel =
      MethodChannel('zephlink/received_files');

  static Future<AndroidReceivedFile?> publish(File file, String name) async {
    if (!Platform.isAndroid) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'publish',
      {'path': file.path, 'name': name},
    );
    if (result == null ||
        result['name'] is! String ||
        result['uri'] is! String ||
        result['size'] is! int) {
      throw const FormatException(
          'Android did not return the saved file details.');
    }
    return AndroidReceivedFile(
      name: result['name'] as String,
      uri: result['uri'] as String,
      size: result['size'] as int,
    );
  }

  static Future<List<AndroidReceivedFile>> list() async {
    if (!Platform.isAndroid) return const [];
    final entries = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'list',
    );
    if (entries == null) return const [];
    return entries.map((entry) {
      final name = entry['name'];
      final uri = entry['uri'];
      final size = entry['size'];
      if (name is! String || uri is! String || size is! int) {
        throw const FormatException(
            'Android returned invalid received-file details.');
      }
      return AndroidReceivedFile(name: name, uri: uri, size: size);
    }).toList();
  }

  static Future<Uint8List?> thumbnail(String uri) async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<Uint8List>('thumbnail', {'uri': uri});
  }

  static Future<void> openFolder() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openFolder');
  }

  static Future<void> openFile(String uri) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openFile', {'uri': uri});
  }
}
