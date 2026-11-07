import 'dart:io';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../platform/android_notification_forwarder.dart';
import '../platform/background.dart';
import '../platform/windows_background_host.dart';
import '../widgets/widgets.dart';
import 'devices_screen.dart';

/// Settings: appearance (light, dark, system), connection and about.
/// Every switch here really changes how the app behaves.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _startWithWindows = false;
  bool _batteryFree = true;
  bool _notificationAccess = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSystemState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadSystemState();
  }

  Future<void> _loadSystemState() async {
    final startup = await WindowsStartup.isEnabled();
    final battery = await BackgroundKeeper.batteryUnrestricted();
    final notificationAccess = await AndroidNotificationForwarder.hasAccess();
    if (!mounted) return;
    setState(() {
      _startWithWindows = startup;
      _batteryFree = battery;
      _notificationAccess = notificationAccess;
    });
  }

  Future<void> _openNotificationAccess() async {
    await AndroidNotificationForwarder.openSettings();
    await _loadSystemState();
  }

  Future<void> _setStartup(bool value) async {
    final ok = await WindowsStartup.setEnabled(value);
    if (!mounted) return;
    setState(() => _startWithWindows = ok ? value : _startWithWindows);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not change the Windows startup setting.'),
        ),
      );
    }
  }

  Future<void> _allowBattery() async {
    await BackgroundKeeper.requestBatteryUnrestricted();
    // The system screen closes later, so check again shortly after.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _loadSystemState();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final link = AppScope.linkOf(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: gapped([
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    return ZCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const CardHeader('Appearance'),
                          SegmentedButton<ThemeMode>(
                            segments: const [
                              ButtonSegment<ThemeMode>(
                                value: ThemeMode.system,
                                icon: Icon(Icons.brightness_auto_outlined),
                                label: Text('System'),
                              ),
                              ButtonSegment<ThemeMode>(
                                value: ThemeMode.light,
                                icon: Icon(Icons.light_mode_outlined),
                                label: Text('Light'),
                              ),
                              ButtonSegment<ThemeMode>(
                                value: ThemeMode.dark,
                                icon: Icon(Icons.dark_mode_outlined),
                                label: Text('Dark'),
                              ),
                            ],
                            selected: {controller.mode},
                            onSelectionChanged: (selection) =>
                                controller.setMode(selection.first),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'System follows your phone or Windows setting.',
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                ActionTile(
                  icon: Icons.devices_rounded,
                  title: 'Devices',
                  subtitle: 'Connect a new device or manage paired ones',
                  onTap: () => openDevices(context),
                ),
                ListenableBuilder(
                  listenable: link,
                  builder: (context, _) {
                    return ZCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const CardHeader('Connection'),
                          ToggleRow(
                            title: 'Quick connect',
                            subtitle:
                                'Reconnect to trusted devices automatically after the first approved pairing',
                            value: link.quickConnect,
                            onChanged: link.setQuickConnect,
                          ),
                          ToggleRow(
                            title: 'Receive files automatically',
                            subtitle:
                                'Accept files sent by your paired devices',
                            value: link.autoReceive,
                            onChanged: link.setAutoReceive,
                          ),
                          ToggleRow(
                            title: 'File received notifications',
                            subtitle:
                                'Show a system notification when a file arrives',
                            value: link.fileNotifications,
                            onChanged: link.setFileNotifications,
                          ),
                          if (AndroidNotificationForwarder.supported) ...[
                            ToggleRow(
                              title: 'Forward phone notifications to Windows',
                              subtitle:
                                  'Share notification text and available quick replies over the encrypted link',
                              value: link.forwardNotifications,
                              onChanged: link.setForwardNotifications,
                            ),
                            if (link.forwardNotifications &&
                                !_notificationAccess)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: FilledButton.tonalIcon(
                                  onPressed: _openNotificationAccess,
                                  icon: const Icon(
                                      Icons.notifications_active_outlined),
                                  label: const Text(
                                    'Grant notification access',
                                  ),
                                ),
                              ),
                          ],
                          ToggleRow(
                            title: 'Share clipboard automatically',
                            subtitle:
                                'Text you copy appears on the other device',
                            value: link.autoClipboard,
                            onChanged: link.setAutoClipboard,
                          ),
                          if (Platform.isAndroid)
                            ToggleRow(
                              title: 'Let my PC ring this phone',
                              subtitle:
                                  'Find my phone: rings loudly, even on silent, when a linked device asks',
                              value: link.tools.allowRing,
                              onChanged: link.tools.setAllowRing,
                            ),
                          ToggleRow(
                            title: 'Let linked devices browse my files',
                            subtitle:
                                'Skip the question each time. They can only look and ask for a file, never change or delete',
                            value: link.tools.alwaysAllowFiles,
                            onChanged: link.tools.setAlwaysAllowFiles,
                          ),
                          if (BackgroundKeeper.supported ||
                              WindowsBackgroundHost.supported) ...[
                            ToggleRow(
                              title: 'Keep running after closing',
                              subtitle: BackgroundKeeper.supported
                                  ? 'Keeps the link alive with a foreground notification'
                                  : 'Closing the window hides Zephlink in the system tray',
                              value: link.keepRunning,
                              onChanged: link.setKeepRunning,
                            ),
                            if (BackgroundKeeper.supported && !_batteryFree)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: FilledButton.tonalIcon(
                                  onPressed: _allowBattery,
                                  icon: const Icon(
                                    Icons.battery_charging_full_rounded,
                                  ),
                                  label: const Text(
                                    'Allow unrestricted battery use',
                                  ),
                                ),
                              ),
                          ],
                          if (WindowsStartup.supported) ...[
                            ToggleRow(
                              title: 'Start with Windows',
                              subtitle: 'Opens Zephlink when you sign in',
                              value: _startWithWindows,
                              onChanged: _setStartup,
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Right-click the tray icon for Open and Quit. '
                                'Turn off “Keep running after closing” to exit when you close the window.',
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
                ZCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const CardHeader('About'),
                      Row(
                        children: [
                          const ZLogo(size: 40),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Zephlink 0.2.0', style: tt.titleSmall),
                                Text(
                                  'Everything stays between your own devices. No account, no cloud.',
                                  style: tt.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
