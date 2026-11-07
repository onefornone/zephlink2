import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../app_scope.dart';
import '../features/transfer_hub.dart';
import '../link/link_controller.dart';
import '../link/models.dart';
import '../theme/zeph_colors.dart';
import '../widgets/format.dart';
import '../widgets/pair_qr.dart';
import '../widgets/resend.dart';
import '../widgets/transfer_preview.dart';
import '../widgets/widgets.dart';
import 'devices_screen.dart';
import 'files_screen.dart';
import 'remote_screen.dart';
import 'screen_screen.dart';

/// Home / Connect tab: the state of your link, quick actions and recent files.
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  void _open(BuildContext context, String title, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PageScaffold(title: title, child: page),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    final phone = isPhonePlatform;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final peer = link.activePeer;
        return ResponsiveColumns(
          main: [
            HeroCard(phone: phone),
            if (link.pendingSharedCount > 0)
              ZCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${link.pendingSharedCount} shared file'
                      '${link.pendingSharedCount == 1 ? '' : 's'} ready',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Connect a trusted device to send them automatically.',
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () => openDevices(context),
                      icon: const Icon(Icons.devices_rounded),
                      label: const Text('Connect a device'),
                    ),
                  ],
                ),
              ),
            AdaptiveGrid(
              minTileWidth: 170,
              children: [
                ActionTile(
                  icon: Icons.upload_rounded,
                  title: 'Send files',
                  subtitle: peer != null
                      ? 'To ${peer.name}'
                      : 'Connect a device first',
                  onTap: () => _open(context, 'Files', const FilesScreen()),
                ),
                ActionTile(
                  icon: Icons.content_paste_rounded,
                  title: 'Send clipboard',
                  subtitle: peer != null
                      ? 'Text to ${peer.name}'
                      : 'Connect a device first',
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final error = await link.sendClipboard();
                    messenger
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(content: Text(error ?? 'Clipboard sent')),
                      );
                  },
                ),
                ActionTile(
                  icon: Icons.screen_share_outlined,
                  title: 'Mirror',
                  subtitle: peer != null
                      ? 'See or share a screen'
                      : 'Connect a device first',
                  onTap: () => _open(context, 'Screen', const ScreenScreen()),
                ),
                ActionTile(
                  icon: Icons.mouse_outlined,
                  title: 'Remote',
                  subtitle: peer != null
                      ? 'Control ${peer.name}'
                      : 'Connect a device first',
                  onTap: () => _open(context, 'Remote', const RemoteScreen()),
                ),
              ],
            ),
          ],
          side: const [RecentTransfersCard()],
        );
      },
    );
  }
}

/// Big card showing the real state of the link to your other device.
class HeroCard extends StatelessWidget {
  const HeroCard({super.key, required this.phone});

  /// True when this app runs on the phone (so the other device is the PC).
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => _build(context, link),
    );
  }

  Widget _build(BuildContext context, LinkController link) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final status = link.status;
    final peer = link.activePeer;
    final other = phone ? 'PC' : 'phone';

    late final String chip;
    late final String title;
    late final String detail;
    Color dot = kOnlineDot;
    switch (status) {
      case LinkStatus.connected:
        chip = 'Connected';
        title = peer?.name ?? 'Your $other';
        detail = '${peer?.platform == 'android' ? 'Android' : 'Windows'} · '
            'same Wi-Fi · end-to-end encrypted';
      case LinkStatus.connecting:
        chip = 'Connecting';
        dot = cs.amber;
        title = 'Linking up…';
        detail = 'Setting up a private, encrypted link.';
      case LinkStatus.searching:
        chip = 'Searching';
        dot = cs.amber;
        final paired = link.pairedPeers;
        title = paired.isEmpty ? 'Your $other' : paired.first.name;
        detail = 'Looking for it on this Wi-Fi. Open Zephlink on it.';
      case LinkStatus.unpaired:
        chip = 'Not linked yet';
        dot = cs.amber;
        title = 'Pair your $other';
        detail = 'Open Zephlink on both devices, then connect them once. '
            'After that they link by themselves.';
    }

    final quick = link.quickLinkTime;
    final showQuick = status == LinkStatus.connected &&
        quick != null &&
        quick < const Duration(seconds: 60);
    final address = link.primaryAddress;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: cs.heroGradient,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Pill(
                chip,
                background: cs.heroChip,
                foreground: Colors.white,
                dotColor: dot,
              ),
              if (showQuick)
                Text(
                  'Quick-linked in ${(quick.inMilliseconds / 1000).toStringAsFixed(1)} s',
                  style: tt.bodySmall?.copyWith(color: Colors.white),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(title, style: tt.headlineMedium?.copyWith(color: Colors.white)),
          const SizedBox(height: 6),
          Text(detail, style: tt.bodyMedium?.copyWith(color: Colors.white)),
          if (address != null) ...[
            const SizedBox(height: 10),
            Text(
              'This device: $address',
              style: tt.titleSmall?.copyWith(color: Colors.white),
            ),
          ],
          const SizedBox(height: 14),
          if (status == LinkStatus.connected)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (link.latencyText.isNotEmpty)
                  Pill(
                    'Wi-Fi · ${link.latencyText}',
                    background: cs.heroChip,
                    foreground: Colors.white,
                  ),
                Pill(
                  'End-to-end encrypted',
                  background: cs.heroChip,
                  foreground: Colors.white,
                ),
              ],
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => openDevices(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF00455A),
                  ),
                  child: Text(
                    status == LinkStatus.unpaired
                        ? 'Connect a device'
                        : 'Manage devices',
                  ),
                ),
                if (phone)
                  OutlinedButton.icon(
                    onPressed: () => scanPairingQr(context, link),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white70),
                    ),
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Scan QR code'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () => showPairQrDialog(
                      context,
                      link,
                      onEnterCode: () => openDevices(context),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white70),
                    ),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: const Text('Show QR code'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Recent file transfers with a quick way to open them or view all transfers.
class RecentTransfersCard extends StatelessWidget {
  const RecentTransfersCard({super.key});

  String _status(TransferItem item) {
    if (item.running) {
      if (item.state == TransferState.waiting) {
        return 'Waiting for the other device…';
      }
      return '${formatBytes(item.bytes)} of ${formatBytes(item.size)}';
    }
    if (item.state == TransferState.done) {
      return '${formatBytes(item.size)} · ${item.outgoing ? 'sent' : 'received'}';
    }
    return item.error ?? 'Transfer failed';
  }

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final items = link.transfers.take(8).toList();
        return ZCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardHeader(
                'Recent files',
                trailing: IconButton(
                  tooltip: 'View all transfers',
                  icon: const Icon(Icons.visibility_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PageScaffold(
                        title: 'Files',
                        child: FilesScreen(),
                      ),
                    ),
                  ),
                ),
              ),
              if (items.isEmpty)
                Text(
                  'Files you send or receive will appear here.',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                )
              else
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        TransferPreview(
                          name: item.name,
                          filePath: item.state == TransferState.done
                              ? item.path
                              : null,
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
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(
                                  color: item.state == TransferState.failed
                                      ? cs.error
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (item.running)
                          IconButton(
                            tooltip: 'Cancel transfer',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => link.cancelTransfer(item),
                          )
                        else if (item.outgoing &&
                            (item.state == TransferState.failed ||
                                item.state == TransferState.cancelled))
                          IconButton(
                            tooltip: 'Send again',
                            icon: const Icon(Icons.replay_rounded),
                            onPressed: link.activePeer == null
                                ? null
                                : () => resendWithMessage(context, link, item),
                          )
                        else if (item.state == TransferState.done &&
                            item.path != null)
                          IconButton(
                            tooltip: 'Open file',
                            icon: Icon(
                              Icons.open_in_new_rounded,
                              color: cs.success,
                            ),
                            onPressed: () => OpenFilex.open(item.path!),
                          ),
                      ],
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}
