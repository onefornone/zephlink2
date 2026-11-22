import 'package:flutter/material.dart';

import '../link/link_controller.dart';
import 'widgets.dart';

/// Settings card for linking over the internet through your own relay.
class InternetLinkCard extends StatefulWidget {
  const InternetLinkCard({super.key, required this.link});

  final LinkController link;

  @override
  State<InternetLinkCard> createState() => _InternetLinkCardState();
}

class _InternetLinkCardState extends State<InternetLinkCard> {
  late final TextEditingController _address;
  String? _error;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final current = widget.link.relayUrl;
    _address = TextEditingController(
      text: current.startsWith('wss://') ? current.substring(6) : current,
    );
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final error = await widget.link.setRelayUrl(_address.text);
    if (!mounted) return;
    setState(() {
      _error = error;
      _saved = error == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final link = widget.link;
    final ready = link.relayReadyPeers;
    final notReady = link.pairedPeers
        .where((peer) => peer.relayKey == null)
        .toList();
    return ZCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardHeader('Internet link'),
          Text(
            'Link when you are not on the same Wi-Fi, through a small relay '
            'that you run yourself (free). Everything is encrypted by your '
            'devices first, so the relay cannot read it. See RELAY.md for the '
            'setup steps.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          ToggleRow(
            title: 'Link over the internet',
            subtitle: 'Only with devices you have already paired',
            value: link.relayOn,
            onChanged: link.setRelayOn,
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) => setState(() => _saved = false),
            decoration: InputDecoration(
              labelText: 'Relay address',
              hintText: 'zephlink-relay.yourname.workers.dev',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _error,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _save,
                child: const Text('Save address'),
              ),
              if (_saved) ...[
                const SizedBox(width: 10),
                Text('Saved', style: tt.bodySmall),
              ],
            ],
          ),
          if (link.relayOn) ...[
            const SizedBox(height: 10),
            if (link.relayUrl.isEmpty)
              Text(
                'Add the relay address above to start.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            if (link.relayNote != null)
              Text(link.relayNote!, style: tt.bodyMedium),
            if (ready.isNotEmpty)
              Text(
                'Ready for the internet: '
                '${ready.map((peer) => peer.name).join(', ')}',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            if (notReady.isNotEmpty)
              Text(
                'Link once on the same Wi-Fi to get '
                '${notReady.map((peer) => peer.name).join(', ')} ready.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
          ],
        ],
      ),
    );
  }
}
