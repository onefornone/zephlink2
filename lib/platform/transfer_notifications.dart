import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class TransferNotifications {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;

    final settings = InitializationSettings(
      android: Platform.isAndroid
          ? const AndroidInitializationSettings('ic_zephlink_notification')
          : null,
      windows: Platform.isWindows
          ? const WindowsInitializationSettings(
              appName: 'Zephlink',
              appUserModelId: 'OneForNone.Zephlink',
              guid: '40b8153b-81ec-48c6-a013-8fbb633dd3ab',
            )
          : null,
    );
    try {
      await _plugin.initialize(settings: settings);
      _ready = true;
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final enabled = await android?.areNotificationsEnabled();
        if (enabled != true) {
          await android?.requestNotificationsPermission();
        }
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink notifications',
          context: ErrorDescription('while initializing file notifications'),
        ),
      );
    }
  }

  Future<void> receivedFile(String name, String from) async {
    if (!_ready) return;
    const androidDetails = AndroidNotificationDetails(
      'zephlink_received_files',
      'Received files',
      channelDescription: 'Shown when Zephlink receives a file',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    try {
      await _plugin.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff),
        title: 'File received',
        body: '$name from $from',
        notificationDetails: const NotificationDetails(
          android: androidDetails,
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink notifications',
          context: ErrorDescription('while showing a received-file notification'),
        ),
      );
    }
  }
}
