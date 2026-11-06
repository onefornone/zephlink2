import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_handler/share_handler.dart';

import 'app.dart';
import 'link/link_controller.dart';
import 'platform/single_instance.dart';
import 'platform/transfer_notifications.dart';
import 'platform/windows_background_host.dart';
import 'theme/theme_controller.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Only one copy of the app on Windows. A second start (for example
  // "Send with Zephlink" in Explorer) hands its files to the first and quits.
  LinkController? runningLink;
  final earlyStarts = <List<String>>[];
  final isFirst = await SingleInstance.acquire(args, (second) {
    final current = runningLink;
    if (current == null) {
      earlyStarts.add(second);
    } else {
      _handleLaunchArgs(current, second);
    }
  });
  if (!isFirst) exit(0);

  final prefs = await SharedPreferences.getInstance();
  await WindowsBackgroundHost.initialize(
    keepRunning: prefs.getBool('zl_keep') ?? true,
    startMinimized: args.contains('--minimized'),
  );
  final notifications = TransferNotifications();
  await notifications.initialize();
  final link = LinkController(
    prefs,
    onFileReceived: (item, from) => notifications.receivedFile(item.name, from),
  );
  if (Platform.isAndroid) {
    final shareHandler = ShareHandler.instance;
    try {
      shareHandler.sharedMediaStream.listen(
        (media) => unawaited(_queueSharedMedia(Future.value(media), link)),
        onError: (Object error, StackTrace stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'Zephlink Android sharing',
              context: ErrorDescription('while receiving shared files'),
            ),
          );
        },
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink Android sharing',
          context: ErrorDescription('while starting Android share handling'),
        ),
      );
    }
  }
  runningLink = link;
  if (Platform.isWindows) {
    _handleLaunchArgs(link, args, openWindow: false);
    for (final second in earlyStarts) {
      _handleLaunchArgs(link, second);
    }
    earlyStarts.clear();
  }
  runApp(
    ZephlinkApp(
      themeController: ThemeController(prefs),
      linkController: link,
    ),
  );
  if (Platform.isAndroid) {
    unawaited(_pickInitialSharedMedia(link));
  }
  // Quick connect: start looking for your devices the moment the app opens.
  unawaited(link.start());
}

Future<void> _pickInitialSharedMedia(LinkController link) async {
  try {
    final media = await ShareHandler.instance.getInitialSharedMedia();
    final files = (media?.attachments ?? const [])
        .whereType<SharedAttachment>()
        .map((attachment) => attachment.path)
        .where((path) => path.isNotEmpty)
        .map(XFile.new)
        .toList();
    await link.queueSharedFiles(files);
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Zephlink Android sharing',
        context: ErrorDescription('while reading files shared to Zephlink'),
      ),
    );
  }
}

Future<void> _queueSharedMedia(
  Future<SharedMedia?> mediaFuture,
  LinkController link,
) async {
  try {
    final media = await mediaFuture;
    final files = (media?.attachments ?? const [])
        .whereType<SharedAttachment>()
        .map((attachment) => attachment.path)
        .where((path) => path.isNotEmpty)
        .map(XFile.new)
        .toList();
    await link.queueSharedFiles(files);
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Zephlink Android sharing',
        context: ErrorDescription('while queuing shared files'),
      ),
    );
  }
}

/// Reads the start-up words of a Windows launch: `--send file...` queues
/// files for the other device, `--minimized` means "stay in the tray".
void _handleLaunchArgs(
  LinkController link,
  List<String> args, {
  bool openWindow = true,
}) {
  final sendAt = args.indexOf('--send');
  if (sendAt >= 0) {
    final files = args
        .skip(sendAt + 1)
        .where((path) => path.isNotEmpty && !path.startsWith('--'))
        .map((path) => XFile(path))
        .toList();
    unawaited(link.queueSharedFiles(files));
  }
  // A second copy asking for attention brings the window forward, unless it
  // only started quietly (for example from the Startup folder).
  if (openWindow && !(args.contains('--minimized') && sendAt < 0)) {
    WindowsBackgroundHost.bringToFront();
  }
}
