import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../link/link_controller.dart';

/// Shows "Incoming call" on the PC, with Answer and Decline, on top of any
/// screen. Answering only picks up on the phone: the voice stays on the phone.
class CallHost extends StatefulWidget {
  const CallHost({
    super.key,
    required this.navigatorKey,
    required this.link,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final LinkController link;
  final Widget child;

  @override
  State<CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<CallHost> {
  bool _showing = false;
  BuildContext? _dialogContext;

  @override
  void initState() {
    super.initState();
    widget.link.phone.addListener(_check);
  }

  @override
  void dispose() {
    widget.link.phone.removeListener(_check);
    super.dispose();
  }

  void _close() {
    final dialog = _dialogContext;
    _dialogContext = null;
    if (dialog != null && dialog.mounted) Navigator.of(dialog).pop();
  }

  Future<void> _bringToFront() async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.show();
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.focus();
    } catch (_) {
      // The notification still tells the person about the call.
    }
  }

  void _check() {
    final phone = widget.link.phone;
    if (phone.incomingCall == null) {
      if (_showing) _close();
      return;
    }
    if (_showing) return;
    _showing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = widget.navigatorKey.currentContext;
      if (context == null || !context.mounted || phone.incomingCall == null) {
        _showing = false;
        return;
      }
      unawaited(_bringToFront());
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        animationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 120),
          reverseDuration: Duration(milliseconds: 60),
        ),
        builder: (dialogContext) {
          _dialogContext = dialogContext;
          return ListenableBuilder(
            listenable: phone,
            builder: (context, _) {
              final call = phone.incomingCall;
              return AlertDialog(
                icon: const Icon(Icons.call_rounded),
                title: const Text('Incoming call'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      call?.title ?? '',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    if (call != null &&
                        call.name.isNotEmpty &&
                        call.number.isNotEmpty)
                      Text(call.number),
                    const SizedBox(height: 8),
                    Text(
                      'on ${widget.link.activePeer?.name ?? 'your phone'}. '
                      'If you answer, you talk on the phone, not on this PC.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                actionsAlignment: MainAxisAlignment.center,
                actionsOverflowAlignment: OverflowBarAlignment.center,
                actions: [
                  TextButton(
                    onPressed: () {
                      _dialogContext = null;
                      phone.dismissCall();
                      Navigator.of(dialogContext).pop();
                    },
                    child: const Text('Dismiss'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      final why = await phone.callAction(false);
                      if (why != null) {
                        messenger?.showSnackBar(SnackBar(content: Text(why)));
                      }
                    },
                    icon: const Icon(Icons.call_end_rounded),
                    label: const Text('Decline'),
                  ),
                  FilledButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      final why = await phone.callAction(true);
                      if (why != null) {
                        messenger?.showSnackBar(SnackBar(content: Text(why)));
                      }
                    },
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Answer'),
                  ),
                ],
              );
            },
          );
        },
      );
      _dialogContext = null;
      _showing = false;
      if (phone.incomingCall != null) phone.dismissCall();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
