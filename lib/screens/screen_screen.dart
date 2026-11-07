import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_scope.dart';
import '../features/screen_remote.dart';
import '../link/link_controller.dart';
import '../platform/android_screen.dart';
import '../platform/h264_viewer.dart';
import '../widgets/quick_actions.dart';
import '../widgets/widgets.dart';
import 'devices_screen.dart';

/// Screen tab: see the other device's screen, and share this one.
class ScreenScreen extends StatelessWidget {
  const ScreenScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final remote = link.remote;
        if (!link.connected) {
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ZCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const CardHeader('Screen mirroring'),
                        const Text(
                          'Link your phone and PC first. Then you can see one '
                          'screen on the other, and control it if you allow it.',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => openDevices(context),
                          icon: const Icon(Icons.devices_rounded),
                          label: const Text('Open Devices'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        if (remote.viewing) {
          return _ViewerPage(
            remote: remote,
            peerPlatform: link.activePeer?.platform ?? 'other',
            peerName: link.activePeer?.name ?? 'the other device',
          );
        }
        return _ShareControls(link: link);
      },
    );
  }
}

/// The two cards: watch the other screen, share this one.
class _ShareControls extends StatefulWidget {
  const _ShareControls({required this.link});

  final LinkController link;

  @override
  State<_ShareControls> createState() => _ShareControlsState();
}

class _ShareControlsState extends State<_ShareControls>
    with WidgetsBindingObserver {
  bool _allowControl = false;
  bool _serviceOn = true;
  bool _overlayOn = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshService();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshService();
  }

  Future<void> _refreshService() async {
    if (!AndroidScreen.supported) return;
    final on = await AndroidScreen.controlEnabled();
    final overlay = await AndroidScreen.overlayAllowed();
    if (mounted) {
      setState(() {
        _serviceOn = on;
        _overlayOn = overlay;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final remote = link.remote;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final peerName = link.activePeer?.name ?? 'the other device';
    final note = remote.notice;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: gapped([
            if (note != null)
              ZCard(
                color: cs.secondaryContainer,
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        color: cs.onSecondaryContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        note,
                        style: tt.bodyMedium
                            ?.copyWith(color: cs.onSecondaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ZCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CardHeader('See $peerName\'s screen'),
                  Text(
                    '$peerName will ask its owner first. You see its screen '
                    'here, and can control it only if they allow that.',
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  ToggleRow(
                    title: 'Open their screen automatically',
                    subtitle: 'As soon as we are linked, ask to see it. '
                        'Works with "view anytime" turned on there.',
                    value: remote.autoView,
                    onChanged: remote.setAutoView,
                  ),
                  if (remote.canH264)
                    ToggleRow(
                      title: 'Smooth video (H.264)',
                      subtitle: 'Much less Wi-Fi and smoother. Experimental: '
                          'it switches back to simple video by itself if it '
                          'does not start.',
                      value: remote.preferH264,
                      onChanged: remote.setPreferH264,
                    ),
                  const SizedBox(height: 12),
                  if (remote.waiting)
                    Row(
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Waiting for $peerName to allow it...'),
                        ),
                        TextButton(
                          onPressed: remote.stopViewing,
                          child: const Text('Cancel'),
                        ),
                      ],
                    )
                  else
                    FilledButton.icon(
                      onPressed: remote.requestView,
                      icon: const Icon(Icons.visibility_rounded),
                      label: const Text('Ask to see their screen'),
                    ),
                ],
              ),
            ),
            if (remote.supportsSharing)
              ZCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const CardHeader('Share this screen'),
                    Text(
                      remote.sharing
                          ? 'Sharing. Only $peerName can see it, and only '
                              'while they are watching.'
                          : 'Choose how it looks, then start. You can stop at '
                              'any time.',
                      style:
                          tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<ScreenQuality>(
                      segments: [
                        for (final q in ScreenQuality.all)
                          ButtonSegment<ScreenQuality>(
                            value: q,
                            label: Text(q.name),
                          ),
                      ],
                      selected: {remote.quality},
                      onSelectionChanged: remote.sharing
                          ? null
                          : (selection) {
                              remote.quality = selection.first;
                              setState(() {});
                            },
                    ),
                    const SizedBox(height: 8),
                    ToggleRow(
                      title: 'Let $peerName view this screen anytime',
                      subtitle: AndroidScreen.supported
                          ? 'View only, no questions asked. Android still shows '
                              'its own "Start now" box each time sharing begins.'
                          : 'View only, no questions asked, whenever the '
                              'linked device asks. Control is always asked.',
                      value: remote.alwaysAllowView,
                      onChanged: remote.setAlwaysAllowView,
                    ),
                    ToggleRow(
                      title: 'Allow $peerName to control this device',
                      subtitle: AndroidScreen.supported
                          ? 'Taps and swipes. Needs the remote control '
                              'service turned on in Android settings.'
                          : 'Mouse and keyboard on this PC.',
                      value: remote.sharing
                          ? remote.controlGranted
                          : _allowControl,
                      onChanged: remote.sharing
                          ? (on) {
                              if (!on) remote.revokeControl();
                            }
                          : (on) => setState(() => _allowControl = on),
                    ),
                    if (AndroidScreen.supported && !_overlayOn)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: FilledButton.tonalIcon(
                          onPressed: AndroidScreen.openOverlaySettings,
                          icon: const Icon(Icons.layers_outlined),
                          label: const Text(
                            'Allow opening apps and files from the PC',
                          ),
                        ),
                      ),
                    if (AndroidScreen.supported && !_serviceOn)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: FilledButton.tonalIcon(
                          onPressed: AndroidScreen.openControlSettings,
                          icon: const Icon(Icons.accessibility_new_rounded),
                          label: const Text('Turn on remote control service'),
                        ),
                      ),
                    const SizedBox(height: 4),
                    if (remote.sharing)
                      FilledButton.tonalIcon(
                        onPressed: remote.stopSharing,
                        icon: const Icon(Icons.stop_screen_share_rounded),
                        label: const Text('Stop sharing'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: remote.starting
                            ? null
                            : () =>
                                remote.startSharing(allowControl: _allowControl),
                        icon: const Icon(Icons.screen_share_rounded),
                        label: Text(
                          remote.starting ? 'Starting...' : 'Start sharing',
                        ),
                      ),
                  ],
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The other device's screen, with controls when allowed.
class _ViewerPage extends StatefulWidget {
  const _ViewerPage({
    required this.remote,
    required this.peerPlatform,
    required this.peerName,
    this.fullscreen = false,
  });

  final ScreenRemoteService remote;
  final String peerPlatform;
  final String peerName;

  /// True on the full-screen page (no tab bar, controls float on top).
  final bool fullscreen;

  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  final TextEditingController _text = TextEditingController();

  // Phone-on-PC dragging.
  bool _dragging = false;

  // PC-on-phone pointer tracking.
  Offset? _downAt;
  DateTime? _downTime;
  Offset? _lastAt;

  bool _hideBar = false;
  bool _rotated = false;
  bool _landscape = false;

  @override
  void dispose() {
    _text.dispose();
    if (_rotated) {
      unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]));
    }
    super.dispose();
  }

  bool get _peerIsAndroid => widget.peerPlatform == 'android';

  void _abs(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    widget.remote.sendInput(<String, dynamic>{
      'k': 'abs',
      'x': ScreenRemoteService.clampUnit(local.dx / size.width),
      'y': ScreenRemoteService.clampUnit(local.dy / size.height),
    });
  }

  Map<String, double> _norm(Offset local, Size size) => <String, double>{
        'x': ScreenRemoteService.clampUnit(local.dx / size.width),
        'y': ScreenRemoteService.clampUnit(local.dy / size.height),
      };

  // -- Pointer handling when the other device is an Android phone ----------

  void _androidDown(PointerDownEvent event) {
    _downAt = event.localPosition;
    _lastAt = event.localPosition;
    _downTime = DateTime.now();
    if (event.buttons == kSecondaryMouseButton) {
      widget.remote.sendInput(<String, dynamic>{'k': 'nav', 'a': 'back'});
      _downAt = null;
    }
  }

  void _androidMove(PointerMoveEvent event) => _lastAt = event.localPosition;

  void _androidUp(PointerUpEvent event, Size size) {
    final start = _downAt;
    final began = _downTime;
    _downAt = null;
    if (start == null || began == null || size.width <= 0) return;
    final end = event.localPosition;
    final elapsed = DateTime.now().difference(began).inMilliseconds;
    final moved = (end - start).distance;
    if (moved < 10) {
      final point = _norm(start, size);
      widget.remote.sendInput(<String, dynamic>{
        'k': elapsed > 500 ? 'long' : 'tap',
        ...point,
      });
    } else {
      final from = _norm(start, size);
      final to = _norm(end, size);
      widget.remote.sendInput(<String, dynamic>{
        'k': 'swipe',
        'x1': from['x'],
        'y1': from['y'],
        'x2': to['x'],
        'y2': to['y'],
        'ms': elapsed.clamp(120, 900),
      });
    }
  }

  void _androidSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent || size.height <= 0) return;
    final point = _norm(event.localPosition, size);
    final up = event.scrollDelta.dy < 0;
    // Mouse wheel down moves the content up, like a finger swipe upward.
    final y = point['y'] ?? 0.5;
    final length = 0.25;
    final y2 = up ? (y + length) : (y - length);
    widget.remote.sendInput(<String, dynamic>{
      'k': 'swipe',
      'x1': point['x'],
      'y1': y,
      'x2': point['x'],
      'y2': ScreenRemoteService.clampUnit(y2),
      'ms': 220,
    });
  }

  // -- Touch handling when the other device is a Windows PC ---------------

  Widget _windowsOverlay(Size size) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        _abs(details.localPosition, size);
        widget.remote.sendInput(<String, dynamic>{'k': 'click', 'b': 'l'});
      },
      onLongPressStart: (details) {
        _abs(details.localPosition, size);
        widget.remote.sendInput(<String, dynamic>{'k': 'click', 'b': 'r'});
      },
      onPanStart: (details) {
        _dragging = true;
        _abs(details.localPosition, size);
        widget.remote.sendInput(<String, dynamic>{'k': 'down', 'b': 'l'});
      },
      onPanUpdate: (details) {
        if (_dragging) _abs(details.localPosition, size);
      },
      onPanEnd: (_) {
        if (_dragging) {
          widget.remote.sendInput(<String, dynamic>{'k': 'up', 'b': 'l'});
        }
        _dragging = false;
      },
    );
  }

  Widget _overlay(Size area) {
    if (_peerIsAndroid) {
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _androidDown,
        onPointerMove: _androidMove,
        onPointerUp: (event) => _androidUp(event, area),
        onPointerSignal: (event) => _androidSignal(event, area),
        child: const SizedBox.expand(),
      );
    }
    return _windowsOverlay(area);
  }

  Widget _videoPicture(H264Viewer video) {
    return ValueListenableBuilder<Size?>(
      valueListenable: video.size,
      builder: (context, size, _) {
        final ratio = (size == null || size.height <= 0)
            ? 9 / 16
            : size.width / size.height;
        return AspectRatio(
          aspectRatio: ratio,
          child: LayoutBuilder(
            builder: (context, box) {
              final area = Size(box.maxWidth, box.maxHeight);
              return Stack(
                fit: StackFit.expand,
                children: [
                  video.buildView(),
                  if (widget.remote.peerControl) _overlay(area),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _picture() {
    final video = widget.remote.video;
    if (widget.remote.codec == 'h264' && video != null) {
      return _videoPicture(video);
    }
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: widget.remote.frame,
      builder: (context, bytes, _) {
        if (bytes == null) {
          return const AspectRatio(
            aspectRatio: 16 / 9,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final size = jpegSize(bytes) ?? const Size(16, 9);
        return AspectRatio(
          aspectRatio: size.width / size.height,
          child: LayoutBuilder(
            builder: (context, box) {
              final area = Size(box.maxWidth, box.maxHeight);
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    bytes,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                  if (widget.remote.peerControl) _overlay(area),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _toolbar(BuildContext context) {
    final remote = widget.remote;
    final bar = _controlsBar(context);
    if (remote.codec != 'h264') return bar;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => remote.useSimpleVideo(),
            icon: const Icon(Icons.image_outlined),
            label: const Text('Video looks wrong? Switch to simple video'),
          ),
        ),
        bar,
      ],
    );
  }

  Widget _controlsBar(BuildContext context) {
    final remote = widget.remote;
    if (!remote.peerControl) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'View only. ${widget.peerName} has not allowed control.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    void send(Map<String, dynamic> input) => remote.sendInput(input);
    final buttons = _peerIsAndroid
        ? <Widget>[
            IconButton.filledTonal(
              tooltip: 'Back',
              onPressed: () => send({'k': 'nav', 'a': 'back'}),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'Home',
              onPressed: () => send({'k': 'nav', 'a': 'home'}),
              icon: const Icon(Icons.circle_outlined),
            ),
            IconButton.filledTonal(
              tooltip: 'Recent apps',
              onPressed: () => send({'k': 'nav', 'a': 'recents'}),
              icon: const Icon(Icons.crop_square_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'Notifications',
              onPressed: () => send({'k': 'nav', 'a': 'notifications'}),
              icon: const Icon(Icons.notifications_none_rounded),
            ),
          ]
        : <Widget>[
            IconButton.filledTonal(
              tooltip: 'Scroll up',
              onPressed: () => send({'k': 'wheel', 'd': 3}),
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'Scroll down',
              onPressed: () => send({'k': 'wheel', 'd': -3}),
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'Right click',
              onPressed: () => send({'k': 'click', 'b': 'r'}),
              icon: const Icon(Icons.mouse_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'Escape',
              onPressed: () => send({'k': 'tap', 'vk': 0x1B}),
              icon: const Icon(Icons.keyboard_return_rounded),
            ),
          ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: buttons),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  decoration: InputDecoration(
                    hintText: _peerIsAndroid
                        ? 'Type into the selected field on the phone'
                        : 'Type on the PC',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _sendText(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _sendText, child: const Text('Send')),
            ],
          ),
        ],
      ),
    );
  }

  void _sendText() {
    final text = _text.text;
    if (text.isEmpty) return;
    widget.remote.sendInput(<String, dynamic>{'k': 'text', 's': text});
    _text.clear();
  }

  // -- Extra controls ------------------------------------------------------

  static Future<void> _systemFullscreen(bool on) async {
    try {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(on);
      } else if (Platform.isAndroid) {
        await SystemChrome.setEnabledSystemUIMode(
          on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      }
    } catch (_) {
      // The window could not change. The picture still shows.
    }
  }

  Future<void> _enterFullscreen() async {
    await _systemFullscreen(true);
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenPage(
          remote: widget.remote,
          peerPlatform: widget.peerPlatform,
          peerName: widget.peerName,
        ),
      ),
    );
    await _systemFullscreen(false);
  }

  Future<void> _rotate() async {
    _landscape = !_landscape;
    _rotated = true;
    await SystemChrome.setPreferredOrientations(
      _landscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp],
    );
    if (mounted) setState(() {});
  }

  Future<void> _screenshot() async {
    final messenger = ScaffoldMessenger.of(context);
    final link = AppScope.linkOf(context);
    final bytes = widget.remote.frame.value;
    void say(String text) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    if (bytes == null) {
      say(widget.remote.codec == 'h264'
          ? 'Screenshots work in simple video mode.'
          : 'There is no picture to save yet.');
      return;
    }
    try {
      final folder = await link.hub.folderPath();
      final name = 'Zephlink-screen-${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File('$folder${Platform.pathSeparator}$name')
          .writeAsBytes(bytes, flush: true);
      say('Saved $name in your Zephlink folder.');
    } catch (_) {
      say('Could not save the screenshot.');
    }
  }

  void _quickSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: QuickActionsCard(
            remote: widget.remote,
            peerPlatform: widget.peerPlatform,
            peerName: widget.peerName,
          ),
        ),
      ),
    );
  }

  /// Shown on the picture area: fits inside the space, never scrolls.
  Widget _stage() {
    final picture = Center(child: _picture());
    if (widget.remote.peerControl) return picture;
    // View only: pinch or scroll to zoom in.
    return InteractiveViewer(minScale: 1, maxScale: 6, child: picture);
  }

  List<Widget> _tools({required bool inFullscreen}) {
    final remote = widget.remote;
    return <Widget>[
      IconButton(
        tooltip: 'Save a screenshot',
        onPressed: _screenshot,
        icon: const Icon(Icons.photo_camera_outlined),
      ),
      if (Platform.isAndroid)
        IconButton(
          tooltip: _landscape ? 'Portrait' : 'Landscape',
          onPressed: _rotate,
          icon: Icon(_landscape
              ? Icons.stay_current_portrait_rounded
              : Icons.stay_current_landscape_rounded),
        ),
      if (remote.peerControl)
        IconButton(
          tooltip: 'Quick actions',
          onPressed: _quickSheet,
          icon: const Icon(Icons.bolt_rounded),
        ),
      if (inFullscreen)
        IconButton(
          tooltip: 'Exit full screen',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.fullscreen_exit_rounded),
        )
      else
        IconButton(
          tooltip: 'Full screen',
          onPressed: _enterFullscreen,
          icon: const Icon(Icons.fullscreen_rounded),
        ),
    ];
  }

  Widget _fullscreenBody() {
    final remote = widget.remote;
    final nav = remote.peerControl && _peerIsAndroid && !_hideBar;
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: Colors.black, child: _stage()),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: SafeArea(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.45),
                borderRadius: BorderRadius.circular(24),
              ),
              child: IconTheme(
                data: const IconThemeData(color: Colors.white),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_hideBar) ..._tools(inFullscreen: true),
                    IconButton(
                      tooltip: _hideBar ? 'Show controls' : 'Hide controls',
                      onPressed: () => setState(() => _hideBar = !_hideBar),
                      icon: Icon(_hideBar
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (nav)
          Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: IconTheme(
                    data: const IconThemeData(color: Colors.white),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Back',
                          onPressed: () => remote
                              .sendInput({'k': 'nav', 'a': 'back'}),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        IconButton(
                          tooltip: 'Home',
                          onPressed: () => remote
                              .sendInput({'k': 'nav', 'a': 'home'}),
                          icon: const Icon(Icons.circle_outlined),
                        ),
                        IconButton(
                          tooltip: 'Recent apps',
                          onPressed: () => remote
                              .sendInput({'k': 'nav', 'a': 'recents'}),
                          icon: const Icon(Icons.crop_square_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fullscreen) return _fullscreenBody();
    final remote = widget.remote;
    final tt = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.peerName}\'s screen',
                      style: tt.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ..._tools(inFullscreen: false),
                  FilledButton.tonalIcon(
                    onPressed: remote.stopViewing,
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Stop'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: Colors.black,
                    child: SizedBox.expand(child: _stage()),
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 230),
                child: SingleChildScrollView(child: _toolbar(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The picture on its own page, using the whole window or screen.
class _FullscreenPage extends StatelessWidget {
  const _FullscreenPage({
    required this.remote,
    required this.peerPlatform,
    required this.peerName,
  });

  final ScreenRemoteService remote;
  final String peerPlatform;
  final String peerName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: Focus(
          autofocus: true,
          child: ListenableBuilder(
            listenable: remote,
            builder: (context, _) {
              if (!remote.viewing) {
                // Sharing ended: leave full screen.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) Navigator.of(context).maybePop();
                });
              }
              return _ViewerPage(
                remote: remote,
                peerPlatform: peerPlatform,
                peerName: peerName,
                fullscreen: true,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Reads the width and height of a JPEG picture without decoding it.
Size? jpegSize(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    // Start-of-frame markers hold the size.
    if ((marker >= 0xC0 && marker <= 0xC3) ||
        (marker >= 0xC5 && marker <= 0xC7) ||
        (marker >= 0xC9 && marker <= 0xCB) ||
        (marker >= 0xCD && marker <= 0xCF)) {
      final height = (b[i + 5] << 8) | b[i + 6];
      final width = (b[i + 7] << 8) | b[i + 8];
      if (width > 0 && height > 0) {
        return Size(width.toDouble(), height.toDouble());
      }
      return null;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final length = (b[i + 2] << 8) | b[i + 3];
    i += 2 + length;
  }
  return null;
}
