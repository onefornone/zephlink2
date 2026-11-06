import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../app_scope.dart';
import '../features/transfer_hub.dart';
import '../link/link_controller.dart';
import '../platform/android_received_files.dart';
import '../platform/android_file_picker.dart';
import '../theme/zeph_colors.dart';
import '../widgets/format.dart';
import '../widgets/transfer_preview.dart';
import '../widgets/widgets.dart';
import 'devices_screen.dart';

/// Files tab: send files to the other device and see what is coming in.
class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    final content = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListenableBuilder(
          listenable: link,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: gapped([
              _SendCard(link: link),
              _TransfersCard(link: link),
              _FolderCard(link: link),
            ]),
          ),
        ),
      ),
    );
    if (isPhonePlatform) return content;
    return DropTarget(
      onDragDone: (details) => link.sendFiles(details.files),
      child: content,
    );
  }
}

class _SendCard extends StatelessWidget {
  const _SendCard({required this.link});

  final LinkController link;

  Future<void> _choose(BuildContext context) async {
    try {
      final files = Platform.isAndroid
          ? await AndroidFilePicker.pickFiles()
          : await openFiles();
      if (files.isNotEmpty) await link.sendFiles(files);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink file selection',
          context: ErrorDescription('while selecting files to send'),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not select those files.')),
        );
      }
    }
  }

  Future<void> _chooseFolder(BuildContext context) async {
    try {
      final List<TransferSource> sources;
      if (Platform.isAndroid) {
        final picked = await AndroidFilePicker.pickFolder();
        sources = picked
            .map(
              (entry) => TransferSource(
                file: entry.file,
                relativePath: entry.relativePath,
              ),
            )
            .toList();
      } else {
        final folderPath = await getDirectoryPath();
        if (folderPath == null) return;
        final normalizedPath = folderPath.replaceAll(RegExp(r'[\\/]+$'), '');
        final folder = Directory(normalizedPath);
        final rootName = normalizedPath.split(RegExp(r'[\\/]')).last;
        sources = [];
        await for (final entity in folder.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final relative = entity.path
              .substring(normalizedPath.length + 1)
              .replaceAll('\\', '/');
          sources.add(
            TransferSource(
              file: XFile(entity.path),
              relativePath: '$rootName/$relative',
            ),
          );
        }
      }
      if (sources.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That folder contains no files.')),
          );
        }
        return;
      }
      await link.sendSources(sources);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink folder selection',
          context: ErrorDescription('while selecting a folder to send'),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not select that folder.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final peer = link.activePeer;

    if (peer == null) {
      return ZCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect a device to send files', style: tt.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Files are sent straight to your other device over your Wi-Fi, encrypted. '
              'Nothing goes through the internet.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => openDevices(context),
              icon: const Icon(Icons.devices_rounded),
              label: const Text('Open Devices'),
            ),
          ],
        ),
      );
    }

    return ZCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.upload_rounded, color: cs.onPrimaryContainer),
          ),
          const SizedBox(height: 12),
          Text('Send files to ${peer.name}', style: tt.titleMedium),
          const SizedBox(height: 4),
          Text(
            isPhonePlatform
                ? 'Choose files on your phone.'
                : 'Drag files into this window, or choose them.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => _choose(context),
                icon: const Icon(Icons.attach_file_rounded),
                label: const Text('Choose files'),
              ),
              OutlinedButton.icon(
                onPressed: () => _chooseFolder(context),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Choose folder'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TransfersCard extends StatelessWidget {
  const _TransfersCard({required this.link});

  final LinkController link;

  String _status(TransferItem item) {
    switch (item.state) {
      case TransferState.waiting:
        return 'Waiting for the other device…';
      case TransferState.active:
        return '${formatBytes(item.bytes)} of ${formatBytes(item.size)}'
            ' · ${formatSpeed(item.speed)}';
      case TransferState.paused:
        return item.error ?? 'Paused. Reconnect and resume to continue.';
      case TransferState.done:
        return '${formatBytes(item.size)} · ${item.outgoing ? 'sent' : 'received'}';
      case TransferState.failed:
        return item.error ?? 'Failed';
      case TransferState.cancelled:
        return item.error ?? 'Cancelled';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final items = link.transfers;
    final hasFinished = items.any(
      (item) =>
          item.state == TransferState.done ||
          item.state == TransferState.failed ||
          item.state == TransferState.cancelled,
    );

    return ZCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardHeader(
            'Transfers',
            trailing: hasFinished
                ? TextButton(
                    onPressed: link.clearFinishedTransfers,
                    child: const Text('Clear finished'),
                  )
                : null,
          ),
          if (items.isEmpty)
            Text(
              'No transfers yet.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            )
          else
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: TransferPreview(
                        name: item.name,
                        filePath:
                            item.state == TransferState.done ? item.path : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.titleSmall,
                          ),
                          Text(
                            _status(item),
                            style: tt.bodySmall?.copyWith(
                              color: item.state == TransferState.failed
                                  ? cs.error
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                          if (item.running ||
                              item.state == TransferState.paused) ...[
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value: item.state == TransferState.active ||
                                      item.state == TransferState.paused
                                  ? item.progress
                                  : null,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (item.running)
                      IconButton(
                        tooltip: 'Cancel',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => link.cancelTransfer(item),
                      )
                    else if (item.state == TransferState.paused) ...[
                      if (item.outgoing)
                        IconButton(
                          tooltip: 'Resume',
                          icon: const Icon(Icons.play_arrow_rounded),
                          onPressed: link.activePeer == null
                              ? null
                              : () => link.resumeTransfer(item),
                        ),
                      IconButton(
                        tooltip: 'Cancel',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => link.cancelTransfer(item),
                      ),
                    ] else if (item.state == TransferState.done &&
                        item.path != null)
                      IconButton(
                        tooltip: 'Open file',
                        icon:
                            Icon(Icons.open_in_new_rounded, color: cs.success),
                        onPressed: () => _openReceivedFile(context, item),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({required this.link});

  final LinkController link;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ZCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardHeader('Received files'),
          FutureBuilder<String>(
            future: link.hub.folderPath(),
            builder: (context, snapshot) {
              final path = snapshot.data;
              if (path == null) {
                return Text(
                  snapshot.hasError
                      ? 'Could not find a folder to save files in.'
                      : 'Finding the folder…',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    path,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  if (Platform.isWindows)
                    TextButton.icon(
                      onPressed: () => Process.run('explorer.exe', [path]),
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Open folder'),
                    )
                  else
                    TextButton.icon(
                      onPressed: () => _openAndroidFolder(context),
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Open in file manager'),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

Future<void> _openAndroidFolder(BuildContext context) async {
  try {
    await AndroidReceivedFiles.openFolder();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Zephlink received files',
        context: ErrorDescription('while opening Downloads/Zephlink'),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not open the Android file manager.')),
      );
    }
  }
}

Future<void> _openReceivedFile(
  BuildContext context,
  TransferItem item,
) async {
  try {
    final uri = item.externalUri;
    if (uri != null && uri.startsWith('content://')) {
      await AndroidReceivedFiles.openFile(uri);
    } else {
      await OpenFilex.open(item.path!);
    }
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Zephlink received files',
        context: ErrorDescription('while opening ${item.name}'),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the received file.')),
      );
    }
  }
}
