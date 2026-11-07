import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../link/link_controller.dart';

/// A big "Scan with your phone" window with the pairing QR code. The code
/// renews itself when it runs out, until the window is closed.
Future<void> showPairQrDialog(
  BuildContext context,
  LinkController link, {
  VoidCallback? onEnterCode,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PairQrDialog(link: link, onEnterCode: onEnterCode),
  );
}

class _PairQrDialog extends StatefulWidget {
  const _PairQrDialog({required this.link, this.onEnterCode});

  final LinkController link;
  final VoidCallback? onEnterCode;

  @override
  State<_PairQrDialog> createState() => _PairQrDialogState();
}

class _PairQrDialogState extends State<_PairQrDialog> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final window = widget.link.pairing;
      if (mounted && (window == null || !window.open)) {
        widget.link.startPairing();
      }
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final link = widget.link;
      if (link.connected) {
        // Paired: close this window, but only when it is the one on top (an
        // approval question may still be open above it).
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          Navigator.of(context).pop();
        }
        return;
      }
      final current = link.pairing;
      if (current == null || (!current.open && !current.used)) {
        // Ran out of time or too many wrong tries: make a fresh code.
        link.startPairing();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _close() {
    widget.link.cancelPairing();
    Navigator.of(context).pop();
  }

  Widget _step(BuildContext context, int number, String text) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 10,
          backgroundColor: cs.secondaryContainer,
          child: Text(
            '$number',
            style: tt.labelSmall?.copyWith(color: cs.onSecondaryContainer),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: tt.bodySmall)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final link = widget.link;
    final payload = link.pairingQrPayload;
    final window = link.pairing;
    final left = window?.remaining ?? Duration.zero;
    final address = link.primaryAddress;
    return AlertDialog(
      title: const Text('Scan with your phone', textAlign: TextAlign.center),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (payload == null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    address == null
                        ? 'No Wi-Fi address found. Connect this PC to the same '
                            'Wi-Fi as your phone.'
                        : 'Getting the code ready…',
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: payload,
                    version: QrVersions.auto,
                    size: 230,
                    backgroundColor: Colors.white,
                  ),
                ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 6,
                children: [
                  _step(context, 1, 'Install Zephlink'),
                  _step(context, 2, 'Tap "Scan Zephlink QR code"'),
                  _step(context, 3, 'Scan this code'),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Code refreshes in ${left.inMinutes}:'
                '${(left.inSeconds % 60).toString().padLeft(2, '0')}'
                ' · Works on this network',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              if (window != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Or type ${window.pin.substring(0, 3)} ${window.pin.substring(3)}'
                  '${address == null ? '' : ' with address $address'}',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 4),
              Text(
                'Both devices will ask you to approve the first pairing.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actionsOverflowAlignment: OverflowBarAlignment.center,
      actions: [
        if (widget.onEnterCode != null)
          FilledButton.tonalIcon(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onEnterCode!();
            },
            icon: const Icon(Icons.wifi_find_rounded),
            label: const Text('Pair nearby instead'),
          ),
        TextButton(onPressed: _close, child: const Text('Cancel')),
      ],
    );
  }
}
