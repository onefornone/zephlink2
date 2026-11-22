import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../features/phone_service.dart';
import '../widgets/widgets.dart';

/// The phone's text messages on the PC.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final phone = AppScope.linkOf(context).phone;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      phone.clearUnread();
      if (!phone.phoneOpen && phone.connected && !phone.opening) {
        phone.open();
      } else if (phone.phoneOpen) {
        phone.loadConversations();
      }
    });
  }

  String _when(DateTime time) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    if (now.difference(time).inHours < 20 && now.day == time.day) {
      return '${two(time.hour)}:${two(time.minute)}';
    }
    return '${time.day}/${time.month}/${time.year % 100}';
  }

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    final phone = link.phone;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([link, phone]),
      builder: (context, _) {
        if (!phone.connected) {
          return const _Note(
            icon: Icons.link_off_rounded,
            text: 'Connect your phone first, then its texts show up here.',
          );
        }
        if (!phone.phoneOpen) {
          return _Note(
            icon: Icons.sms_outlined,
            text: phone.opening
                ? 'Waiting for the phone. Tap Allow on the phone if it asks.'
                : (phone.openNote ??
                    'Ask the phone to share its texts and calls with this PC.'),
            action: phone.opening
                ? null
                : FilledButton.icon(
                    onPressed: phone.open,
                    icon: const Icon(Icons.phone_android_rounded),
                    label: const Text('Ask the phone'),
                  ),
          );
        }
        if (!phone.smsAllowed) {
          return _Note(
            icon: Icons.lock_outline_rounded,
            text: 'Text messages are not allowed for Zephlink on the phone. '
                'Allow "SMS" in the phone’s app settings for Zephlink, then try again.',
            action: FilledButton.tonal(
              onPressed: phone.open,
              child: const Text('Try again'),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Texts on ${link.activePeer?.name ?? 'your phone'}',
                    style: tt.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed:
                      phone.loadingConversations ? null : phone.loadConversations,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (phone.conversationsNote != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  phone.conversationsNote!,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            if (phone.loadingConversations && phone.conversations.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (phone.conversations.isEmpty)
              Text(
                'No text conversations found.',
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              )
            else
              ZCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final conversation in phone.conversations)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.primaryContainer,
                          foregroundColor: cs.onPrimaryContainer,
                          child: Text(
                            conversation.title.isEmpty
                                ? '?'
                                : conversation.title.substring(0, 1).toUpperCase(),
                          ),
                        ),
                        title: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: conversation.unread
                              ? const TextStyle(fontWeight: FontWeight.bold)
                              : null,
                        ),
                        subtitle: Text(
                          '${conversation.sentByMe ? 'You: ' : ''}${conversation.snippet}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          _when(conversation.date),
                          style: tt.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ThreadScreen(conversation: conversation),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Texts you send here are sent by the phone from its own number. '
              'They may not appear in the phone’s own Messages app.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        );
      },
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ZCard(
      child: Column(
        children: [
          Icon(icon, size: 36, color: cs.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

/// One conversation, with a box to write a reply.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({super.key, required this.conversation});

  final SmsConversation conversation;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<SmsMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  String? _error;
  int _lastTick = -1;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _lastTick = AppScope.linkOf(context).phone.textTick;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final phone = AppScope.linkOf(context).phone;
    final messages = await phone.loadThread(widget.conversation.thread);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (messages == null) {
        _error = 'Could not load this conversation.';
      } else {
        _error = null;
        _messages = messages;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    final phone = AppScope.linkOf(context).phone;
    setState(() {
      _sending = true;
      _error = null;
    });
    final why = await phone.sendText(widget.conversation.address, text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (why == null) {
        _text.clear();
        _messages = [
          ..._messages,
          SmsMessage(id: -1, body: text, date: DateTime.now(), sent: true),
        ];
      } else {
        _error = why;
      }
    });
    if (why == null) {
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = AppScope.linkOf(context).phone;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: phone,
      builder: (context, _) {
        if (phone.textTick != _lastTick) {
          _lastTick = phone.textTick;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _load();
          });
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.conversation.title),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(12),
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final message = _messages[index];
                              return Align(
                                alignment: message.sent
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 3),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  constraints:
                                      const BoxConstraints(maxWidth: 480),
                                  decoration: BoxDecoration(
                                    color: message.sent
                                        ? cs.primaryContainer
                                        : cs.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: SelectableText(
                                    message.body,
                                    style: tt.bodyMedium?.copyWith(
                                      color: message.sent
                                          ? cs.onPrimaryContainer
                                          : cs.onSurface,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _error!,
                        style: tt.bodySmall?.copyWith(color: cs.error),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _text,
                            minLines: 1,
                            maxLines: 4,
                            maxLength: 1000,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              hintText: 'Text from ${AppScope.linkOf(context).activePeer?.name ?? 'your phone'}',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              counterText: '',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _sending ? null : _send,
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
