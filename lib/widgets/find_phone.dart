import 'package:flutter/material.dart';

import '../features/device_tools.dart';
import '../link/link_controller.dart';
import 'widgets.dart';

/// "Find my phone" on the PC: make the phone ring and see its battery.
class FindPhoneCard extends StatefulWidget {
  const FindPhoneCard({super.key, required this.tools, required this.peerName});

  final DeviceToolsService tools;
  final String peerName;

  @override
  State<FindPhoneCard> createState() => _FindPhoneCardState();
}

class _FindPhoneCardState extends State<FindPhoneCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.tools.refreshInfo();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.tools,
      builder: (context, _) {
        final tools = widget.tools;
        final battery = tools.peerBattery;
        final notice = tools.findNotice;
        return ZCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CardHeader(
                'Find my phone',
                trailing: IconButton(
                  tooltip: 'Check battery',
                  onPressed: tools.findBusy ? null : tools.refreshInfo,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
              Row(
                children: [
                  Icon(
                    tools.peerCharging
                        ? Icons.battery_charging_full_rounded
                        : Icons.battery_std_rounded,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    battery == null
                        ? (tools.findBusy ? 'Checking battery…' : 'Battery unknown')
                        : '$battery%${tools.peerCharging ? ' and charging' : ''}',
                    style: tt.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Makes ${widget.peerName} ring loudly, even on silent. It stops '
                'by itself after a minute and a half, or when you tap Stop here '
                'or on the phone.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (tools.peerRinging)
                FilledButton.tonalIcon(
                  onPressed: tools.stopPeerRing,
                  icon: const Icon(Icons.volume_off_rounded),
                  label: const Text('Stop ringing'),
                )
              else
                FilledButton.icon(
                  onPressed: tools.ringPeer,
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: const Text('Ring my phone'),
                ),
              if (notice != null) ...[
                const SizedBox(height: 8),
                Text(
                  notice,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Shows "Your phone is ringing" with a Stop button on top of any screen.
class FindHost extends StatefulWidget {
  const FindHost({
    super.key,
    required this.navigatorKey,
    required this.link,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final LinkController link;
  final Widget child;

  @override
  State<FindHost> createState() => _FindHostState();
}

class _FindHostState extends State<FindHost> {
  bool _showing = false;
  BuildContext? _dialogContext;

  @override
  void initState() {
    super.initState();
    widget.link.tools.addListener(_check);
  }

  @override
  void dispose() {
    widget.link.tools.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final tools = widget.link.tools;
    if (!tools.ringingHere) {
      final dialog = _dialogContext;
      if (_showing && dialog != null && dialog.mounted) {
        _dialogContext = null;
        Navigator.of(dialog).pop();
      }
      return;
    }
    if (_showing) return;
    _showing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = widget.navigatorKey.currentContext;
      if (context == null || !context.mounted || !tools.ringingHere) {
        _showing = false;
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        animationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 120),
          reverseDuration: Duration(milliseconds: 60),
        ),
        builder: (dialogContext) {
          _dialogContext = dialogContext;
          return AlertDialog(
            icon: const Icon(Icons.notifications_active_rounded),
            title: const Text('Your phone is ringing'),
            content: Text(
              '${widget.link.activePeer?.name ?? 'Your PC'} is helping you find '
              'this phone.',
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  _dialogContext = null;
                  tools.stopRingingHere();
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Stop ringing'),
              ),
            ],
          );
        },
      );
      _dialogContext = null;
      _showing = false;
      if (tools.ringingHere) {
        // The dialog was closed some other way. Stop the sound as well.
        await tools.stopRingingHere();
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
