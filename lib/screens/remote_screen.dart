import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../features/screen_remote.dart';
import '../widgets/find_phone.dart';
import '../widgets/quick_actions.dart';
import '../widgets/widgets.dart';
import 'devices_screen.dart';

/// Remote tab: use the phone as a touchpad, keyboard, media remote and slide
/// clicker for the PC. Nothing works until the PC owner allows it.
class RemoteScreen extends StatelessWidget {
  const RemoteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        final remote = link.remote;
        final tt = Theme.of(context).textTheme;
        final cs = Theme.of(context).colorScheme;
        final peer = link.activePeer;
        final note = remote.notice;

        Widget page(List<Widget> children) => Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: gapped(children),
                ),
              ),
            );

        if (peer == null) {
          return page([
            ZCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CardHeader('Remote control'),
                  const Text(
                    'Link your phone and PC first. Then the phone can work as '
                    'a touchpad, keyboard and slide clicker for the PC.',
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
          ]);
        }

        final noteCard = note == null
            ? null
            : ZCard(
                color: cs.secondaryContainer,
                child: Text(
                  note,
                  style:
                      tt.bodyMedium?.copyWith(color: cs.onSecondaryContainer),
                ),
              );

        // This device is the PC: show who may control it.
        if (peer.platform != 'windows') {
          return page([
            if (noteCard != null) noteCard,
            if (peer.platform == 'android')
              FindPhoneCard(tools: link.tools, peerName: peer.name),
            ZCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CardHeader('Control from your phone'),
                  Text(
                    remote.controlGranted
                        ? '${peer.name} is allowed to control this device '
                            'right now.'
                        : 'Open Zephlink on ${peer.name}, go to Remote and '
                            'choose "Ask to control". You will be asked here '
                            'first, every time.',
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  if (remote.controlGranted) ...[
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: remote.revokeControl,
                      icon: const Icon(Icons.block_rounded),
                      label: const Text('Stop allowing control'),
                    ),
                  ],
                ],
              ),
            ),
            ZCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CardHeader('Control your phone from here'),
                  Text(
                    'Ask the phone to allow control. Then use the quick '
                    'actions below, or open the Screen tab to see the phone '
                    'and click and drag on the picture like a touch screen.',
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  if (remote.peerControl)
                    FilledButton.tonalIcon(
                      onPressed: remote.releaseControl,
                      icon: const Icon(Icons.block_rounded),
                      label: const Text('Stop controlling the phone'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: remote.requestControl,
                      icon: const Icon(Icons.touch_app_rounded),
                      label: Text('Ask to control ${peer.name}'),
                    ),
                ],
              ),
            ),
            if (remote.peerControl)
              QuickActionsCard(
                remote: remote,
                peerPlatform: peer.platform,
                peerName: peer.name,
              ),
          ]);
        }

        // This device is the phone and the other end is a PC.
        if (!remote.peerControl) {
          return page([
            if (noteCard != null) noteCard,
            ZCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CardHeader('Use your phone as a remote'),
                  Text(
                    '${peer.name} will ask its owner before anything works. '
                    'You get a touchpad, a keyboard, media keys and a slide '
                    'clicker.',
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: remote.requestControl,
                    icon: const Icon(Icons.mouse_rounded),
                    label: Text('Ask to control ${peer.name}'),
                  ),
                ],
              ),
            ),
          ]);
        }
        return page([
          if (noteCard != null) noteCard,
          _RemotePad(remote: remote, peerName: peer.name),
          QuickActionsCard(
            remote: remote,
            peerPlatform: peer.platform,
            peerName: peer.name,
          ),
        ]);
      },
    );
  }
}

/// The touchpad, keys and media buttons.
class _RemotePad extends StatefulWidget {
  const _RemotePad({required this.remote, required this.peerName});

  final ScreenRemoteService remote;
  final String peerName;

  @override
  State<_RemotePad> createState() => _RemotePadState();
}

class _RemotePadState extends State<_RemotePad> {
  final TextEditingController _text = TextEditingController();
  double _speed = 1.6;
  double _pendingX = 0;
  double _pendingY = 0;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  double _scrollCarry = 0;

  // Touchpad finger tracking (raw touches, so the page never scrolls).
  final Map<int, Offset> _fingers = {};
  Offset _padStart = Offset.zero;
  DateTime _padDownAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _padMoved = false;
  bool _padScrolled = false;
  bool _holdFired = false;
  int _mostFingers = 0;
  Timer? _holdTimer;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _send(Map<String, dynamic> input) => widget.remote.sendInput(input);

  void _padDown(PointerDownEvent event) {
    _fingers[event.pointer] = event.position;
    _mostFingers = math.max(_mostFingers, _fingers.length);
    if (_fingers.length == 1) {
      _padStart = event.position;
      _padDownAt = DateTime.now();
      _padMoved = false;
      _padScrolled = false;
      _holdFired = false;
      _mostFingers = 1;
      _holdTimer?.cancel();
      _holdTimer = Timer(const Duration(milliseconds: 550), () {
        if (!_padMoved && _fingers.length == 1) {
          _holdFired = true;
          _send(<String, dynamic>{'k': 'click', 'b': 'r'});
        }
      });
    } else {
      _holdTimer?.cancel();
    }
  }

  void _padMove(PointerMoveEvent event) {
    if (!_fingers.containsKey(event.pointer)) return;
    _fingers[event.pointer] = event.position;
    if (_fingers.length >= 2) {
      // Two fingers scroll.
      _padScrolled = true;
      _scroll(event.delta.dy / _fingers.length);
      return;
    }
    if (!_padMoved && (event.position - _padStart).distance > 6) {
      _padMoved = true;
      _holdTimer?.cancel();
    }
    if (_padMoved) _move(event.delta);
  }

  void _padUp(PointerEvent event) {
    _fingers.remove(event.pointer);
    if (_fingers.isNotEmpty) return;
    _holdTimer?.cancel();
    final quick =
        DateTime.now().difference(_padDownAt) < const Duration(milliseconds: 300);
    if (_mostFingers >= 2) {
      // A quick two-finger tap is a right click.
      if (!_padScrolled && !_padMoved && quick) {
        _send(<String, dynamic>{'k': 'click', 'b': 'r'});
      }
    } else if (!_padMoved && !_holdFired && quick) {
      // Two quick taps in a row become a double click on the PC.
      _send(<String, dynamic>{'k': 'click', 'b': 'l'});
    }
    _mostFingers = 0;
  }

  void _tapKey(int vk) => _send(<String, dynamic>{'k': 'tap', 'vk': vk});

  void _combo(int modifier, int key) {
    _send(<String, dynamic>{'k': 'key', 'vk': modifier, 'down': true});
    _tapKey(key);
    _send(<String, dynamic>{'k': 'key', 'vk': modifier, 'down': false});
  }

  void _move(Offset delta) {
    _pendingX += delta.dx * _speed;
    _pendingY += delta.dy * _speed;
    final now = DateTime.now();
    if (now.difference(_lastMove) < const Duration(milliseconds: 16)) return;
    _lastMove = now;
    final dx = _pendingX.round();
    final dy = _pendingY.round();
    _pendingX -= dx;
    _pendingY -= dy;
    if (dx != 0 || dy != 0) {
      _send(<String, dynamic>{'k': 'rel', 'dx': dx, 'dy': dy});
    }
  }

  void _scroll(double dy) {
    _scrollCarry += dy;
    const step = 14.0;
    final ticks = (_scrollCarry / step).truncate();
    if (ticks == 0) return;
    _scrollCarry -= ticks * step;
    // Dragging down scrolls the page up, like on a phone.
    _send(<String, dynamic>{'k': 'wheel', 'd': -ticks});
  }

  void _sendText() {
    final text = _text.text;
    if (text.isEmpty) return;
    _send(<String, dynamic>{'k': 'text', 's': text});
    _text.clear();
  }

  Widget _key(String label, VoidCallback onTap, {IconData? icon}) {
    return FilledButton.tonal(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: icon != null ? Icon(icon, size: 20) : Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: gapped([
        ZCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardHeader(
                'Touchpad',
                trailing: TextButton(
                  onPressed: widget.remote.releaseControl,
                  child: const Text('Stop'),
                ),
              ),
              SizedBox(
                height: 240,
                child: Row(
                  children: [
                    Expanded(
                      child: _Eager(
                        onDown: _padDown,
                        onMove: _padMove,
                        onUp: _padUp,
                        onCancel: _padUp,
                        child: Container(
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Drag to move. Tap to click.\n'
                            'Hold for right-click. Two fingers to scroll.',
                            textAlign: TextAlign.center,
                            style: tt.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _Eager(
                      onMove: (event) => _scroll(event.delta.dy),
                      child: Container(
                        width: 44,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.unfold_more_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () =>
                          _send(<String, dynamic>{'k': 'click', 'b': 'l'}),
                      child: const Text('Left click'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () =>
                          _send(<String, dynamic>{'k': 'click', 'b': 'r'}),
                      child: const Text('Right click'),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.speed_rounded, size: 18),
                  Expanded(
                    child: Slider(
                      value: _speed,
                      min: 0.8,
                      max: 3.5,
                      onChanged: (value) => setState(() => _speed = value),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        ZCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CardHeader('Keyboard'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      decoration: const InputDecoration(
                        hintText: 'Type here, then Send',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sendText,
                    child: const Text('Send'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _key('Esc', () => _tapKey(0x1B)),
                  _key('Tab', () => _tapKey(0x09)),
                  _key('Enter', () => _tapKey(0x0D)),
                  _key('Bksp', () => _tapKey(0x08)),
                  _key('Del', () => _tapKey(0x2E)),
                  _key('', () => _tapKey(0x25), icon: Icons.arrow_left_rounded),
                  _key('', () => _tapKey(0x26), icon: Icons.arrow_drop_up_rounded),
                  _key('', () => _tapKey(0x28),
                      icon: Icons.arrow_drop_down_rounded),
                  _key('', () => _tapKey(0x27),
                      icon: Icons.arrow_right_rounded),
                  _key('Copy', () => _combo(0x11, 0x43)),
                  _key('Paste', () => _combo(0x11, 0x56)),
                  _key('Undo', () => _combo(0x11, 0x5A)),
                  _key('All', () => _combo(0x11, 0x41)),
                ],
              ),
            ],
          ),
        ),
        ZCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CardHeader('Media'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _key('', () => _tapKey(0xB1),
                      icon: Icons.skip_previous_rounded),
                  _key('', () => _tapKey(0xB3),
                      icon: Icons.play_arrow_rounded),
                  _key('', () => _tapKey(0xB0), icon: Icons.skip_next_rounded),
                  _key('', () => _tapKey(0xAE), icon: Icons.volume_down_rounded),
                  _key('', () => _tapKey(0xAF), icon: Icons.volume_up_rounded),
                  _key('', () => _tapKey(0xAD), icon: Icons.volume_off_rounded),
                ],
              ),
            ],
          ),
        ),
        ZCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CardHeader('Slide clicker'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _key('Previous', () => _tapKey(0x25)),
                  _key('Next', () => _tapKey(0x27)),
                  _key('Start (F5)', () => _tapKey(0x74)),
                  _key('End (Esc)', () => _tapKey(0x1B)),
                ],
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Takes every touch for itself, so a scrolling page around it cannot steal
/// the finger half way through a drag.
class _Eager extends StatelessWidget {
  const _Eager({
    required this.child,
    this.onDown,
    this.onMove,
    this.onUp,
    this.onCancel,
  });

  final Widget child;
  final void Function(PointerDownEvent event)? onDown;
  final void Function(PointerMoveEvent event)? onMove;
  final void Function(PointerUpEvent event)? onUp;
  final void Function(PointerCancelEvent event)? onCancel;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
          EagerGestureRecognizer.new,
          (EagerGestureRecognizer instance) {},
        ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: onDown,
        onPointerMove: onMove,
        onPointerUp: onUp,
        onPointerCancel: onCancel,
        child: child,
      ),
    );
  }
}
