import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../link/models.dart';
import '../widgets/widgets.dart';

class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return const FeatureSoon(
        icon: Icons.notifications_active_outlined,
        title: 'Phone notifications',
        text:
            'Turn on notification forwarding in Settings to show phone notifications on your paired Windows PC.',
        phase: 'Forwarding is available when connected to Windows',
        points: [
          'Notification access is optional and can be turned off in Settings',
          'Notification content is sent over the encrypted paired link',
          'Reply actions only appear when the source notification supports them',
        ],
      );
    }

    final link = AppScope.linkOf(context);
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final notifications = link.forwardedNotifications;
        if (notifications.isEmpty) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: const ZCard(
                child: FeatureSoon(
                  icon: Icons.inbox_outlined,
                  title: 'Your phone inbox',
                  text:
                      'Forwarding is opt-in. Turn it on in Zephlink Settings on your Android phone and grant Android notification access.',
                  phase: 'Waiting for phone notifications',
                  points: [
                    'Your phone and PC must be connected',
                    'Only notifications received while forwarding is enabled are sent',
                    'Reply and dismiss controls depend on the Android app',
                  ],
                ),
              ),
            ),
          );
        }

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final notification in notifications)
                  _NotificationCard(
                    notification: notification,
                    onReply: (text) =>
                        link.replyToPhoneNotification(notification, text),
                    onDismiss: () =>
                        link.dismissPhoneNotification(notification),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.onReply,
    required this.onDismiss,
  });

  final ForwardedNotification notification;
  final Future<void> Function(String text) onReply;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final code = RegExp(r'\b\d{4,8}\b').firstMatch(notification.text)?.group(0);
    final time = TimeOfDay.fromDateTime(notification.postedAt).format(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ZCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    notification.app,
                    style: tt.labelLarge?.copyWith(color: cs.primary),
                  ),
                ),
                Text(
                  time,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                IconButton(
                  tooltip: 'Dismiss on phone',
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (notification.title.isNotEmpty)
              Text(notification.title, style: tt.titleMedium),
            if (notification.text.isNotEmpty) ...[
              const SizedBox(height: 4),
              SelectableText(notification.text),
            ],
            if (code != null || notification.canReply) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (code != null)
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Code copied')),
                          );
                        }
                      },
                      icon: const Icon(Icons.content_copy_rounded),
                      label: const Text('Copy code'),
                    ),
                  if (notification.canReply)
                    TextButton.icon(
                      onPressed: () async {
                        final reply = await showDialog<String>(
                          context: context,
                          builder: (_) => const _ReplyDialog(),
                        );
                        if (reply != null) await onReply(reply);
                      },
                      icon: const Icon(Icons.reply_rounded),
                      label: const Text('Reply'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReplyDialog extends StatefulWidget {
  const _ReplyDialog();

  @override
  State<_ReplyDialog> createState() => _ReplyDialogState();
}

class _ReplyDialogState extends State<_ReplyDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Reply from Zephlink'),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 2000,
          decoration: const InputDecoration(hintText: 'Type a reply'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('Send'),
          ),
        ],
      );
}
