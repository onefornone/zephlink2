import 'package:flutter/material.dart';

import '../widgets/widgets.dart';
import 'devices_screen.dart';
import 'inbox_screen.dart';
import 'settings_screen.dart';
import 'tools_screen.dart';

/// Opens the Settings page on top of the current screen.
void openSettings(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
  );
}

/// More tab (phone): Devices, Clipboard, Inbox and Settings.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  void _open(BuildContext context, String title, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PageScaffold(title: title, child: page),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: gapped([
        ActionTile(
          icon: Icons.devices_rounded,
          title: 'Devices',
          subtitle: 'Pair a new device or manage paired ones',
          onTap: () => openDevices(context),
        ),
        ActionTile(
          icon: Icons.content_paste_rounded,
          title: 'Clipboard',
          subtitle: 'Share text with your other device',
          onTap: () => _open(context, 'Clipboard', const ToolsScreen()),
        ),
        ActionTile(
          icon: Icons.inbox_outlined,
          title: 'Inbox',
          subtitle: 'Phone notifications (coming later)',
          onTap: () => _open(context, 'Inbox', const InboxScreen()),
        ),
        ActionTile(
          icon: Icons.settings_outlined,
          title: 'Settings',
          subtitle: 'Dark mode, background running, files',
          onTap: () => openSettings(context),
        ),
      ], gap: 12),
    );
  }
}
