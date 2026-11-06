import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';

class AndroidFilePicker {
  static const MethodChannel _channel = MethodChannel('zephlink/file_picker');

  static Future<List<AndroidPickedFile>> pickFolder() async {
    if (!Platform.isAndroid) return const [];
    final entries = await _channel.invokeListMethod<Map<Object?, Object?>>(
          'pickFolder',
        ) ??
        const [];
    return entries.map((entry) {
      final path = entry['path'];
      final name = entry['name'];
      final relativePath = entry['relativePath'];
      if (path is! String || name is! String || relativePath is! String) {
        throw const FormatException(
            'Android returned an invalid folder entry.');
      }
      return AndroidPickedFile(
        XFile(path, name: name),
        relativePath,
      );
    }).toList();
  }

  static Future<List<XFile>> pickFiles() async {
    if (!Platform.isAndroid) return const [];
    final entries = await _channel.invokeListMethod<Map<Object?, Object?>>(
          'pickFiles',
        ) ??
        const [];
    return entries.map((entry) {
      final path = entry['path'];
      final name = entry['name'];
      if (path is! String || name is! String) {
        throw const FormatException('Android returned an invalid file.');
      }
      return XFile(path, name: name);
    }).toList();
  }

  static Future<void> deleteAfterTransfer(String path) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('deleteTemporaryFile', {'path': path});
  }
}

class AndroidPickedFile {
  const AndroidPickedFile(this.file, this.relativePath);

  final XFile file;
  final String relativePath;
}
