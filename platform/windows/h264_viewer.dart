import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Plays the H.264 video that the phone sends, using media_kit (mpv).
///
/// The video bytes are handed to the player through a tiny web address that
/// only this PC can reach (127.0.0.1). The Windows build workflow copies this
/// file over lib/platform/h264_viewer.dart and adds the media_kit packages.
class H264Viewer {
  H264Viewer({this.onNeedKeyFrame});

  static bool _ready = false;

  /// Whether this build can play H.264 at all.
  static bool get available => Platform.isWindows;

  /// Called when the player needs a fresh full picture from the sender.
  final void Function()? onNeedKeyFrame;

  /// Size of the video once it is known.
  final ValueNotifier<Size?> size = ValueNotifier<Size?>(null);

  Player? _player;
  VideoController? _controller;
  HttpServer? _server;
  HttpResponse? _response;
  bool _synced = false;
  bool _disposed = false;
  int _width = 0;
  int _height = 0;
  final List<StreamSubscription<int?>> _subs = [];

  bool get hasPicture => size.value != null;

  Future<bool> start() async {
    try {
      if (!_ready) {
        MediaKit.ensureInitialized();
        _ready = true;
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_onRequest, onError: (Object _) {});

      final player = Player();
      _player = player;
      final dynamic native = player.platform;
      for (final option in const <List<String>>[
        ['profile', 'low-latency'],
        ['untimed', 'yes'],
        ['cache', 'no'],
        ['demuxer-lavf-format', 'h264'],
        ['demuxer-lavf-probesize', '32768'],
        ['demuxer-readahead-secs', '0'],
      ]) {
        try {
          await native.setProperty(option[0], option[1]);
        } catch (_) {
          // An option this player build does not know. Carry on.
        }
      }
      _controller = VideoController(player);
      _subs.add(player.stream.width.listen((int? value) {
        _width = value ?? 0;
        _publishSize();
      }));
      _subs.add(player.stream.height.listen((int? value) {
        _height = value ?? 0;
        _publishSize();
      }));
      await player.open(
        Media('http://127.0.0.1:${server.port}/live.h264'),
        play: true,
      );
      return true;
    } catch (_) {
      await dispose();
      return false;
    }
  }

  void _publishSize() {
    if (_disposed) return;
    if (_width > 0 && _height > 0) {
      size.value = Size(_width.toDouble(), _height.toDouble());
    }
  }

  void _onRequest(HttpRequest request) {
    if (_disposed) {
      request.response.close();
      return;
    }
    final old = _response;
    if (old != null) {
      unawaited(old.close().catchError((Object _) => old));
    }
    final response = request.response;
    response.bufferOutput = false;
    response.headers.contentType = ContentType('video', 'h264');
    response.done.then((_) {}, onError: (Object _) {});
    _response = response;
    // The player always starts at a full picture, so ask for one.
    _synced = false;
    onNeedKeyFrame?.call();
  }

  void add(Uint8List data, bool key) {
    final response = _response;
    if (response == null || _disposed) return;
    if (!_synced) {
      if (!key) return;
      _synced = true;
    }
    try {
      response.add(data);
    } catch (_) {
      _response = null;
    }
  }

  Widget buildView() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return Video(
      controller: controller,
      fit: BoxFit.fill,
      controls: NoVideoControls,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    try {
      await _response?.close();
    } catch (_) {
      // Already closed.
    }
    _response = null;
    try {
      await _server?.close(force: true);
    } catch (_) {
      // Already closed.
    }
    _server = null;
    try {
      await _player?.dispose();
    } catch (_) {
      // Already closed.
    }
    _player = null;
    _controller = null;
    size.dispose();
  }
}
