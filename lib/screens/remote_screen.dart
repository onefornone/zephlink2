import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../features/screen_remote.dart';
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
                    'Open the Screen tab, see the phone screen, and ask the '
                    'phone to allow control. Then click and drag on the '
                    'picture like a touch screen.',
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
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

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send(Map<String, dynamic> input) => widget.remote.sendInput(input);

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
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (details) => _move(details.delta),
                        onTap: () =>
                            _send(<String, dynamic>{'k': 'click', 'b': 'l'}),
                        onDoubleTap: () =>
                            _send(<String, dynamic>{'k': 'dbl'}),
                        onLongPress: () =>
                            _send(<String, dynamic>{'k': 'click', 'b': 'r'}),
                        child: Container(
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Drag to move\nTap to click, hold to right-click',
                            textAlign: TextAlign.center,
                            style: tt.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) =>
                          _scroll(details.delta.dy),
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
