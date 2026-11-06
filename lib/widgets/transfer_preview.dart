import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../platform/android_received_files.dart';

class TransferPreview extends StatelessWidget {
  const TransferPreview({
    super.key,
    required this.name,
    required this.filePath,
    this.size = 44,
  });

  final String name;
  final String? filePath;
  final double size;

  static const Set<String> _imageExtensions = {
    'bmp',
    'gif',
    'heic',
    'jpeg',
    'jpg',
    'png',
    'webp',
  };

  IconData get _icon {
    final extension = name.split('.').last.toLowerCase();
    if (_imageExtensions.contains(extension)) return Icons.image_outlined;
    if (extension == 'pdf') return Icons.picture_as_pdf_outlined;
    if (const {'doc', 'docx', 'odt', 'rtf'}.contains(extension)) {
      return Icons.description_outlined;
    }
    if (const {'mp3', 'm4a', 'ogg', 'wav'}.contains(extension)) {
      return Icons.audio_file_outlined;
    }
    if (const {'mp4', 'mkv', 'mov', 'webm'}.contains(extension)) {
      return Icons.video_file_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = filePath;
    final extension = name.split('.').last.toLowerCase();
    if (path != null && _imageExtensions.contains(extension)) {
      if (path.startsWith('content://')) {
        return FutureBuilder<Uint8List?>(
          future: AndroidReceivedFiles.thumbnail(path),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) return _placeholder(cs);
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                bytes,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => _placeholder(cs),
              ),
            );
          },
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * 2).round(),
          cacheHeight: (size * 2).round(),
          errorBuilder: (context, error, stackTrace) => _placeholder(cs),
        ),
      );
    }
    return _placeholder(cs);
  }

  Widget _placeholder(ColorScheme colors) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Icon(_icon, color: colors.onPrimaryContainer, size: size * 0.55),
    );
  }
}
