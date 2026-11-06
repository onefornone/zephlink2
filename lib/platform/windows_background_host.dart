import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

class WindowsBackgroundHost extends StatefulWidget {
  const WindowsBackgroundHost({super.key, required this.child});

  static bool _initialized = false;
  static bool _keepRunning = true;
  static bool _startMinimized = false;
  static bool _userOpened = false;

  static bool get supported => Platform.isWindows;

  /// [startMinimized] starts hidden in the tray (used when Windows starts the
  /// app at sign-in). It only works while the tray icon is available.
  static Future<void> initialize({
    required bool keepRunning,
    bool startMinimized = false,
  }) async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    _keepRunning = keepRunning;
    _startMinimized = startMinimized && keepRunning;
    await windowManager.setPreventClose(keepRunning);
    _initialized = true;
  }

  /// Brings the window forward (from the tray if it is hidden). Used when a
  /// question needs an answer or a second copy of the app was started.
  static void bringToFront() {
    if (!Platform.isWindows || !_initialized) return;
    _userOpened = true;
    unawaited(() async {
      try {
        await windowManager.show();
        if (await windowManager.isMinimized()) await windowManager.restore();
        await windowManager.focus();
      } catch (_) {
        // The window may already be closing.
      }
    }());
  }

  static Future<void> setKeepRunning(bool value) async {
    _keepRunning = value;
    if (!Platform.isWindows || !_initialized) return;
    await windowManager.setPreventClose(value);
  }

  final Widget child;

  @override
  State<WindowsBackgroundHost> createState() => _WindowsBackgroundHostState();

  static bool get isInitialized => _initialized;
}

class _WindowsBackgroundHostState extends State<WindowsBackgroundHost>
    with WindowListener, tray.TrayListener {
  bool _trayReady = false;
  bool _allowExit = false;

  @override
  void initState() {
    super.initState();
    if (!WindowsBackgroundHost.isInitialized) return;
    windowManager.addListener(this);
    tray.trayManager.addListener(this);
    unawaited(_setupTray());
  }

  Future<void> _setupTray() async {
    try {
      await tray.trayManager.setIcon('assets/zephlink.ico');
      await tray.trayManager.setToolTip('Zephlink');
      await tray.trayManager.setContextMenu(
        tray.Menu(
          items: [
            tray.MenuItem(key: 'show', label: 'Open Zephlink'),
            tray.MenuItem.separator(),
            tray.MenuItem(key: 'quit', label: 'Quit Zephlink'),
          ],
        ),
      );
      _trayReady = true;
      if (WindowsBackgroundHost._startMinimized) {
        // The window appears with the first picture; hide it again unless
        // the person (or a request) has already opened it.
        for (final wait in const [400, 900]) {
          await Future<void>.delayed(Duration(milliseconds: wait));
          if (WindowsBackgroundHost._userOpened) break;
          await windowManager.hide();
        }
      }
    } catch (error, stackTrace) {
      await windowManager.setPreventClose(false);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink Windows tray',
          context: ErrorDescription('while setting up the system tray'),
        ),
      );
    }
  }

  Future<void> _showWindow() async {
    WindowsBackgroundHost._userOpened = true;
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() async {
    if (_allowExit) return;
    if (!WindowsBackgroundHost._keepRunning) {
      _allowExit = true;
      await tray.trayManager.destroy();
      return;
    }
    if (!_trayReady) {
      await windowManager.setPreventClose(false);
      return;
    }
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayIconRightMouseDown() {
    unawaited(tray.trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) {
    if (menuItem.key == 'show') {
      unawaited(_showWindow());
    } else if (menuItem.key == 'quit') {
      unawaited(_quit());
    }
  }

  Future<void> _quit() async {
    _allowExit = true;
    await tray.trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void dispose() {
    if (WindowsBackgroundHost.isInitialized) {
      windowManager.removeListener(this);
      tray.trayManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
