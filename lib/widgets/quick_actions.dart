import 'dart:async';

import 'package:flutter/material.dart';

import '../features/screen_remote.dart';
import 'widgets.dart';

class _Quick {
  const _Quick(this.label, this.icon, this.action, {this.danger = false});

  final String label;
  final IconData icon;
  final String action;
  final bool danger;
}

const List<_Quick> _windowsActions = [
  _Quick('Lock', Icons.lock_outline_rounded, 'lock'),
  _Quick('Sleep', Icons.bedtime_outlined, 'sleep'),
  _Quick('Screen off', Icons.desktop_access_disabled_rounded, 'screenoff'),
  _Quick('Shut down', Icons.power_settings_new_rounded, 'shutdown', danger: true),
  _Quick('Restart', Icons.restart_alt_rounded, 'restart', danger: true),
  _Quick('Sign out', Icons.logout_rounded, 'signout', danger: true),
  _Quick('Cancel shutdown', Icons.cancel_outlined, 'cancelpower'),
  _Quick('File Explorer', Icons.folder_open_rounded, 'explorer'),
  _Quick('Downloads', Icons.download_rounded, 'downloads'),
  _Quick('Calculator', Icons.calculate_rounded, 'calc'),
  _Quick('Notepad', Icons.edit_note_rounded, 'notepad'),
  _Quick('Task Manager', Icons.speed_rounded, 'taskmgr'),
  _Quick('Settings', Icons.settings_rounded, 'settings'),
];

const List<_Quick> _androidActions = [
  _Quick('Lock screen', Icons.lock_outline_rounded, 'lock'),
  _Quick('Power menu', Icons.power_settings_new_rounded, 'power'),
  _Quick('Screenshot', Icons.screenshot_rounded, 'screenshot'),
  _Quick('Quick settings', Icons.tune_rounded, 'quicksettings'),
  _Quick('Notifications', Icons.notifications_none_rounded, 'notifications'),
  _Quick('Home', Icons.home_rounded, 'home'),
  _Quick('Back', Icons.arrow_back_rounded, 'back'),
  _Quick('Recent apps', Icons.crop_square_rounded, 'recents'),
  _Quick('Files', Icons.folder_open_rounded, 'files'),
  _Quick('Settings', Icons.settings_rounded, 'settings'),
  _Quick('Camera', Icons.photo_camera_outlined, 'camera'),
  _Quick('Flashlight', Icons.flashlight_on_rounded, 'torch'),
  _Quick('Volume up', Icons.volume_up_rounded, 'volup'),
  _Quick('Volume down', Icons.volume_down_rounded, 'voldown'),
  _Quick('Mute', Icons.volume_off_rounded, 'mute'),
];

/// One-tap actions on the other device: lock, power, open a file manager, an
/// app or a website. The list depends on what the other device is.
class QuickActionsCard extends StatelessWidget {
  const QuickActionsCard({
    super.key,
    required this.remote,
    required this.peerPlatform,
    required this.peerName,
  });

  final ScreenRemoteService remote;
  final String peerPlatform;
  final String peerName;

  bool get _windows => peerPlatform == 'windows';

  Future<void> _website(BuildContext context) async {
    final controller = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Open a website on $peerName'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (address == null || address.isEmpty) return;
    final withScheme =
        address.contains('://') ? address : 'https://$address';
    await remote.sendQuick('url', argument: withScheme);
  }

  Future<void> _pickApp(BuildContext context) async {
    unawaited(remote.requestApps());
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _AppPicker(remote: remote, peerName: peerName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final actions = _windows ? _windowsActions : _androidActions;
    return ZCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardHeader('Quick actions'),
          Text(
            'These run on $peerName. Shut down, restart and sign out ask its '
            'owner again each time.',
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in actions)
                FilledButton.tonalIcon(
                  style: item.danger
                      ? FilledButton.styleFrom(
                          foregroundColor: cs.error,
                        )
                      : null,
                  onPressed: () => remote.sendQuick(item.action),
                  icon: Icon(item.icon, size: 18),
                  label: Text(item.label),
                ),
              if (!_windows)
                FilledButton.tonalIcon(
                  onPressed: () => _pickApp(context),
                  icon: const Icon(Icons.apps_rounded, size: 18),
                  label: const Text('Open an app...'),
                ),
              FilledButton.tonalIcon(
                onPressed: () => _website(context),
                icon: const Icon(Icons.language_rounded, size: 18),
                label: const Text('Open a website...'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.remote, required this.peerName});

  final ScreenRemoteService remote;
  final String peerName;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.7;
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Search apps on ${widget.peerName}',
              ),
              onChanged: (value) =>
                  setState(() => _search = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.remote,
                builder: (context, _) {
                  final all = widget.remote.peerApps;
                  if (all.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final apps = [
                    for (final app in all)
                      if (_search.isEmpty ||
                          (app['label'] ?? '').toLowerCase().contains(_search))
                        app,
                  ];
                  return ListView.builder(
                    itemCount: apps.length,
                    itemBuilder: (context, index) {
                      final app = apps[index];
                      return ListTile(
                        leading: const Icon(Icons.apps_rounded),
                        title: Text(app['label'] ?? ''),
                        onTap: () {
                          widget.remote
                              .sendQuick('app', argument: app['pkg']);
                          Navigator.of(context).pop();
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
