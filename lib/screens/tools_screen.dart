import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../link/link_controller.dart';
import '../widgets/format.dart';
import '../widgets/widgets.dart';

/// Clipboard tab: send text to the other device and keep what it sends you.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendClipboard(LinkController link) async {
    final error = await link.sendClipboard();
    if (mounted) _toast(error ?? 'Clipboard sent');
  }

  Future<void> _sendTyped(LinkController link) async {
    final error = await link.sendText(_text.text);
    if (!mounted) return;
    if (error == null) _text.clear();
    _toast(error ?? 'Sent');
  }

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListenableBuilder(
          listenable: link,
          builder: (context, _) {
            final cs = Theme.of(context).colorScheme;
            final tt = Theme.of(context).textTheme;
            final peer = link.activePeer;
            final clips = link.clips;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: gapped([
                ZCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CardHeader('Share text'),
                      Text(
                        peer == null
                            ? 'Connect a device to share text.'
                            : 'Text goes straight to ${peer.name}, encrypted.',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: peer == null ? null : () => _sendClipboard(link),
                        icon: const Icon(Icons.content_paste_go_rounded),
                        label: const Text('Send my clipboard'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _text,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Or type something to send',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: 'Send',
                            icon: const Icon(Icons.send_rounded),
                            onPressed: peer == null ? null : () => _sendTyped(link),
                          ),
                        ),
                      ),
                      ToggleRow(
                        title: 'Share clipboard automatically',
                        subtitle: 'Copy on one device, paste on the other. Works while Zephlink is open.',
                        value: link.autoClipboard,
                        onChanged: link.setAutoClipboard,
                      ),
                    ],
                  ),
                ),
                ZCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CardHeader('Received text'),
                      if (clips.isEmpty)
                        Text(
                          'Nothing received yet.',
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        )
                      else
                        for (final clip in clips)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        clip.text,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '${clip.from} · ${timeAgo(clip.time)}',
                                        style: tt.bodySmall?.copyWith(
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Copy',
                                  icon: const Icon(Icons.copy_rounded),
                                  onPressed: () async {
                                    await Clipboard.setData(ClipboardData(text: clip.text));
                                    if (mounted) _toast('Copied');
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Remove',
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: () => link.removeClip(clip),
                                ),
                              ],
                            ),
                          ),
                    ],
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}
