import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../features/device_tools.dart';
import '../widgets/format.dart';

/// Looks inside the other device's folders and asks it to send a file.
/// Read-only: nothing here can change or delete anything over there.
class RemoteFilesScreen extends StatefulWidget {
  const RemoteFilesScreen({super.key});

  @override
  State<RemoteFilesScreen> createState() => _RemoteFilesScreenState();
}

class _RemoteFilesScreenState extends State<RemoteFilesScreen> {
  final TextEditingController _search = TextEditingController();
  RemoteListing? _listing;
  bool _loading = true;
  String _path = '';
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open('');
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    final tools = AppScope.linkOf(context).tools;
    setState(() {
      _loading = true;
      _path = path;
      _search.clear();
    });
    final listing = await tools.listFolder(path);
    if (!mounted) return;
    setState(() {
      _listing = listing;
      _loading = false;
    });
  }

  bool get _atTop {
    final listing = _listing;
    return listing == null || !listing.ok || listing.isRoot;
  }

  void _up() {
    final listing = _listing;
    if (listing == null || !listing.ok || listing.isRoot) return;
    _open(listing.parent ?? '');
  }

  String _join(String folder, String name) {
    final sep = folder.contains('\\') ? '\\' : '/';
    return folder.endsWith(sep) ? '$folder$name' : '$folder$sep$name';
  }

  void _tap(RemoteEntry entry) {
    final listing = _listing;
    if (listing == null) return;
    final full = entry.path ?? _join(listing.path, entry.name);
    if (entry.isDir) {
      _open(full);
    } else {
      _download(entry, full);
    }
  }

  Future<void> _download(RemoteEntry entry, String full) async {
    final link = AppScope.linkOf(context);
    await link.tools.download(full);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Asked ${link.activePeer?.name ?? 'the other device'} to send '
            '"${entry.name}". It will show up in Files.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final peerName = link.activePeer?.name ?? 'Other device';
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final listing = _listing;
        final query = _search.text.trim().toLowerCase();
        final shown = <RemoteEntry>[
          if (listing != null && listing.ok)
            for (final entry in listing.items)
              if (query.isEmpty || entry.name.toLowerCase().contains(query))
                entry,
        ];
        final atTop = _atTop;
        return PopScope(
          canPop: atTop,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _up();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text('$peerName files'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () {
                  if (atTop) {
                    Navigator.of(context).pop();
                  } else {
                    _up();
                  }
                },
              ),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : () => _open(_path),
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (listing == null || !listing.ok || listing.isRoot)
                                ? 'Drives and storage'
                                : listing.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: tt.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _search,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search_rounded),
                              hintText: 'Search in this folder',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _body(listing, shown, cs, tt, link.connected)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(
    RemoteListing? listing,
    List<RemoteEntry> shown,
    ColorScheme cs,
    TextTheme tt,
    bool connected,
  ) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!connected) {
      return const _Message(
        icon: Icons.link_off_rounded,
        text: 'The link closed. Connect again to keep browsing.',
      );
    }
    if (listing == null || !listing.ok) {
      return _Message(
        icon: Icons.lock_outline_rounded,
        text: listing?.why ?? 'Could not open that.',
        action: FilledButton.tonal(
          onPressed: () => _open(_path),
          child: const Text('Try again'),
        ),
      );
    }
    if (shown.isEmpty) {
      return const _Message(
        icon: Icons.folder_off_outlined,
        text: 'Nothing to show here.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      itemCount: shown.length,
      itemBuilder: (context, index) {
        final entry = shown[index];
        final details = entry.isDir
            ? null
            : [
                formatBytes(entry.size),
                if (entry.modified > 0)
                  _date(DateTime.fromMillisecondsSinceEpoch(entry.modified)),
              ].join('  ·  ');
        return ListTile(
          leading: Icon(
            entry.isDir ? Icons.folder_rounded : _iconFor(entry.name),
            color: entry.isDir ? cs.primary : cs.onSurfaceVariant,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: details == null ? null : Text(details),
          trailing: entry.isDir
              ? const Icon(Icons.chevron_right_rounded)
              : IconButton(
                  tooltip: 'Get this file',
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () => _tap(entry),
                ),
          onTap: () => _tap(entry),
        );
      },
    );
  }

  String _date(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  IconData _iconFor(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic']
        .contains(ext)) {
      return Icons.image_outlined;
    }
    if (const ['mp4', 'mkv', 'avi', 'mov', 'webm', '3gp'].contains(ext)) {
      return Icons.movie_outlined;
    }
    if (const ['mp3', 'wav', 'flac', 'm4a', 'ogg', 'aac'].contains(ext)) {
      return Icons.music_note_outlined;
    }
    if (const ['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return Icons.folder_zip_outlined;
    }
    if (const ['pdf', 'doc', 'docx', 'txt', 'xls', 'xlsx', 'ppt', 'pptx']
        .contains(ext)) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}
