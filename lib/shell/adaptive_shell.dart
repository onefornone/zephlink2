import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../link/models.dart';
import '../screens/connect_screen.dart';
import '../screens/files_screen.dart';
import '../screens/inbox_screen.dart';
import '../screens/more_screen.dart';
import '../screens/remote_screen.dart';
import '../screens/screen_screen.dart';
import '../screens/tools_screen.dart';
import '../theme/zeph_colors.dart';
import '../widgets/widgets.dart';

/// Every tab the app has. The order matches [_pages].
enum ZTab { home, files, screen, inbox, remote, tools, more }

class _TabInfo {
  const _TabInfo(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const Map<ZTab, _TabInfo> _info = {
  ZTab.home: _TabInfo('Home', Icons.link_rounded, Icons.link_rounded),
  ZTab.files: _TabInfo('Files', Icons.folder_outlined, Icons.folder_rounded),
  ZTab.screen: _TabInfo(
    'Screen',
    Icons.desktop_windows_outlined,
    Icons.desktop_windows_rounded,
  ),
  ZTab.inbox: _TabInfo('Inbox', Icons.inbox_outlined, Icons.inbox_rounded),
  ZTab.remote: _TabInfo('Remote', Icons.mouse_outlined, Icons.mouse_rounded),
  ZTab.tools: _TabInfo(
    'Clipboard',
    Icons.content_paste_outlined,
    Icons.content_paste_rounded,
  ),
  ZTab.more: _TabInfo('More', Icons.more_horiz_rounded, Icons.more_horiz_rounded),
};

/// Tabs on a wide window (Windows): Home, Files, Screen, Inbox, Remote, Clipboard.
const List<ZTab> _wideTabs = [
  ZTab.home,
  ZTab.files,
  ZTab.screen,
  ZTab.inbox,
  ZTab.remote,
  ZTab.tools,
];

/// Tabs on a narrow window (phone): Connect, Files, Screen, Remote, More.
const List<ZTab> _narrowTabs = [
  ZTab.home,
  ZTab.files,
  ZTab.screen,
  ZTab.remote,
  ZTab.more,
];

const List<Widget> _pages = [
  ConnectScreen(),
  FilesScreen(),
  ScreenScreen(),
  InboxScreen(),
  RemoteScreen(),
  ToolsScreen(),
  MoreScreen(),
];

/// Windows at least this wide get the top tab bar.
const double _wideBreakpoint = 1100;

class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({super.key});

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  ZTab _current = ZTab.home;

  /// Makes sure the selected tab exists in the layout that is showing.
  ZTab _fit(ZTab tab, bool wide) {
    if (wide) {
      return tab == ZTab.more ? ZTab.home : tab;
    }
    if (tab == ZTab.inbox || tab == ZTab.tools) return ZTab.more;
    return tab;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;
        final tab = _fit(_current, wide);
        final body = IndexedStack(
          index: ZTab.values.indexOf(tab),
          sizing: StackFit.expand,
          children: _pages,
        );
        if (wide) {
          return _WideLayout(
            current: tab,
            width: constraints.maxWidth,
            onSelect: (t) => setState(() => _current = t),
            body: body,
          );
        }
        return _NarrowLayout(
          current: tab,
          onSelect: (t) => setState(() => _current = t),
          body: body,
        );
      },
    );
  }
}

/// Phone layout: a header, the page, and a bottom navigation bar.
class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({
    required this.current,
    required this.onSelect,
    required this.body,
  });

  final ZTab current;
  final ValueChanged<ZTab> onSelect;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final isHome = current == ZTab.home;
    final title = isHome ? 'Zephlink' : (_info[current]?.label ?? '');
    var selectedIndex = _narrowTabs.indexOf(current);
    if (selectedIndex < 0) selectedIndex = 0;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                child: Row(
                  children: [
                    if (isHome) ...[
                      const ZLogo(size: 32),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        style: tt.headlineSmall?.copyWith(color: cs.onSurface),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => openSettings(context),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) => onSelect(_narrowTabs[index]),
        destinations: [
          for (final tab in _narrowTabs)
            NavigationDestination(
              icon: Icon(_info[tab]!.icon),
              selectedIcon: Icon(_info[tab]!.selectedIcon),
              label: tab == ZTab.home ? 'Connect' : _info[tab]!.label,
            ),
        ],
      ),
    );
  }
}

/// PC layout: a top tab bar, the page, and a status bar.
class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.current,
    required this.width,
    required this.onSelect,
    required this.body,
  });

  final ZTab current;
  final double width;
  final ValueChanged<ZTab> onSelect;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: Column(
        children: [
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            color: cs.surfaceContainer,
            child: Row(
              children: [
                const ZLogo(size: 30),
                const SizedBox(width: 10),
                Text('Zephlink', style: tt.titleLarge),
                const SizedBox(width: 24),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final tab in _wideTabs)
                          _TopTab(
                            info: _info[tab]!,
                            selected: tab == current,
                            onTap: () => onSelect(tab),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                if (width >= 1300) ...[
                  OutlinedButton.icon(
                    onPressed: () => comingSoon(context, 'Search'),
                    icon: const Icon(Icons.search_rounded, size: 18),
                    label: const Text('Search or run a command · Ctrl+K'),
                  ),
                  const SizedBox(width: 12),
                ],
                ListenableBuilder(
                  listenable: AppScope.linkOf(context),
                  builder: (context, _) {
                    final link = AppScope.linkOf(context);
                    final connected = link.status == LinkStatus.connected;
                    return Pill(
                      connected
                          ? '${link.activePeer?.name ?? 'Device'} · Connected'
                          : (link.status == LinkStatus.unpaired
                              ? 'Not paired'
                              : 'Searching'),
                      dotColor: connected ? kOnlineDot : cs.amber,
                      bold: true,
                    );
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => openSettings(context),
                ),
              ],
            ),
          ),
          Expanded(child: body),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            color: cs.surfaceContainer,
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: cs.success,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ListenableBuilder(
                    listenable: AppScope.linkOf(context),
                    builder: (context, _) => Text(
                      AppScope.linkOf(context).statusLine,
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                Text(
                  'Zephlink 0.2.0',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopTab extends StatelessWidget {
  const _TopTab({
    required this.info,
    required this.selected,
    required this.onTap,
  });

  final _TabInfo info;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final fg = selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Semantics(
        button: true,
        selected: selected,
        label: info.label,
        child: Material(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? info.selectedIcon : info.icon,
                    size: 18,
                    color: fg,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    info.label,
                    style: tt.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
