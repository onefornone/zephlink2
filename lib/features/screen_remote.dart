import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../link/models.dart';
import '../link/secure_session.dart';
import '../platform/android_screen.dart';
import '../platform/h264_viewer.dart';
import '../platform/windows_actions.dart';
import '../platform/windows_native.dart';

/// Picture frames travel as raw bytes starting with this number. File
/// transfers use small numbers, so the two never mix.
const int screenFrameId = 0xFFFFFF01;

/// H.264 video pieces use this number. The first byte after it is 2 for a
/// full picture and 3 for a change.
const int screenVideoId = 0xFFFFFF02;

/// How sharp and how fast the shared screen is.
class ScreenQuality {
  const ScreenQuality(this.name, this.maxSide, this.jpeg, this.fps);

  final String name;

  /// Longest side of the picture in pixels.
  final int maxSide;
  final int jpeg;
  final int fps;

  static const ScreenQuality smooth = ScreenQuality('Smooth', 800, 50, 12);
  static const ScreenQuality balanced = ScreenQuality('Balanced', 1080, 65, 10);
  static const ScreenQuality sharp = ScreenQuality('Sharp', 1440, 80, 6);
  static const List<ScreenQuality> all = [smooth, balanced, sharp];
}

/// Screen mirroring and remote control between the two devices.
///
/// Rules that keep it safe:
/// * The device that shares its screen always decides. On Windows a question
///   appears on screen; on Android the system asks for permission.
/// * Control (mouse, keyboard, taps) is a separate permission, off unless the
///   person on the controlled device turned it on, and it ends with the link.
/// * Everything travels inside the encrypted link.
class ScreenRemoteService extends ChangeNotifier {
  ScreenRemoteService({
    required this.ask,
    required this.peerName,
    required this.peerPlatform,
    SharedPreferences? prefs,
  })  : _prefs = prefs,
        alwaysAllowView = prefs?.getBool('zl_always_view') ?? false,
        autoView = prefs?.getBool('zl_auto_view') ?? false;

  final SharedPreferences? _prefs;

  /// This device lets the linked device see its screen without asking each
  /// time (view only, never control). On Android the system still shows its
  /// own "Start now" box each time sharing begins.
  bool alwaysAllowView;

  /// Open the other device's screen by itself when the Screen tab is shown.
  bool autoView;

  Future<void> setAlwaysAllowView(bool value) async {
    alwaysAllowView = value;
    notifyListeners();
    await _prefs?.setBool('zl_always_view', value);
  }

  Future<void> setAutoView(bool value) async {
    autoView = value;
    notifyListeners();
    await _prefs?.setBool('zl_auto_view', value);
  }

  final Future<ConsentAnswer> Function(ConsentRequest request) ask;
  final String Function() peerName;
  final String Function() peerPlatform;

  SecureSession? _session;
  StreamSubscription<Map<String, dynamic>>? _messageSub;
  StreamSubscription<Uint8List>? _binarySub;

  /// The newest picture of the other device's screen (viewer side).
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  ScreenQuality quality = ScreenQuality.balanced;

  /// A short note for the screen (why something did not work).
  String? notice;

  // Sharing side.
  bool _sharing = false;
  bool _starting = false;
  bool _watched = false;
  bool _controlGranted = false;
  bool _controlFromShare = false;
  int _inFlight = 0;
  VoidCallback? _stopCapture;
  WindowsInput? _windowsInput;
  final List<DateTime> _inputTimes = [];

  // Viewing side.
  bool _viewing = false;
  bool _asked = false;
  bool _peerControl = false;
  Timer? _askTimer;

  // H.264 video.
  bool preferH264 = true;
  String _codec = 'jpeg';
  H264Viewer? _video;
  Timer? _videoTimer;
  bool _needKey = false;

  /// Apps on the phone we control (filled after [requestApps]).
  List<Map<String, String>> peerApps = const [];

  /// This build can play smooth H.264 video (Windows build only).
  bool get canH264 => H264Viewer.available;

  /// "h264" or "jpeg": how the picture we are watching is being sent.
  String get codec => _codec;
  H264Viewer? get video => _video;

  bool get connected => _session != null;
  bool get supportsSharing => Platform.isAndroid || Platform.isWindows;

  /// This device is sending its screen.
  bool get sharing => _sharing;
  bool get starting => _starting;

  /// The other device may control this one.
  bool get controlGranted => _controlGranted;

  /// This device is showing the other device's screen.
  bool get viewing => _viewing;

  /// We asked to see the other screen and are waiting for the answer.
  bool get waiting => _asked && !_viewing;

  /// This device may control the other one.
  bool get peerControl => _peerControl;

  // ---- Link life ------------------------------------------------------------

  void attach(SecureSession session) {
    detach();
    _session = session;
    _messageSub = session.messages.listen(_onMessage);
    _binarySub = session.binary.listen(_onBinary);
    notifyListeners();
    if (autoView) {
      // Give the other device a moment to finish connecting, then look.
      Timer(const Duration(seconds: 2), () {
        if (identical(_session, session) && !_viewing && !_asked) {
          unawaited(requestView());
        }
      });
    }
  }

  void detach() {
    unawaited(_messageSub?.cancel());
    unawaited(_binarySub?.cancel());
    _messageSub = null;
    _binarySub = null;
    _stopSharingLocal();
    _askTimer?.cancel();
    _disposeVideo();
    _viewing = false;
    _asked = false;
    _peerControl = false;
    _controlGranted = false;
    _controlFromShare = false;
    peerApps = const [];
    frame.value = null;
    _session = null;
    notifyListeners();
  }

  void _disposeVideo() {
    _videoTimer?.cancel();
    _videoTimer = null;
    final viewer = _video;
    _video = null;
    _codec = 'jpeg';
    if (viewer != null) unawaited(viewer.dispose());
  }

  void setPreferH264(bool value) {
    preferH264 = value;
    notifyListeners();
  }

  /// Switches the video we are watching back to small pictures.
  Future<void> useSimpleVideo({String? why}) async {
    _disposeVideo();
    if (why != null) notice = why;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'scr-want', 'codec': 'jpeg'});
  }

  @override
  void dispose() {
    detach();
    frame.dispose();
    super.dispose();
  }

  Future<void> _send(Map<String, dynamic> message) async {
    final session = _session;
    if (session == null) return;
    await session.send(message);
  }

  // ---- Sharing this device's screen ---------------------------------------

  /// Starts sending this device's screen. The other device still has to
  /// agree to watch. With [allowControl] it may also control this device.
  Future<String?> startSharing({required bool allowControl}) async {
    if (_session == null) return 'Connect a device first.';
    if (!supportsSharing) return 'This device cannot share its screen.';
    if (_sharing) return null;
    if (_starting) return 'Starting. Please wait.';
    _starting = true;
    notice = null;
    notifyListeners();
    String? error;
    try {
      error = await _startCapture();
    } catch (_) {
      error = 'Could not start screen sharing.';
    }
    _starting = false;
    if (error != null) {
      notice = error;
      notifyListeners();
      return error;
    }
    if (_session == null) {
      // The link ended while the system permission box was open.
      _stopSharingLocal();
      notifyListeners();
      return 'The link closed.';
    }
    _sharing = true;
    _watched = false;
    _inFlight = 0;
    _controlGranted = allowControl;
    _controlFromShare = allowControl;
    if (allowControl && Platform.isAndroid) {
      final on = await AndroidScreen.controlEnabled();
      if (!on) {
        notice = 'Control needs "Zephlink remote control" turned on in '
            'Android Accessibility settings.';
      }
    }
    await _send(<String, dynamic>{
      't': 'scr-offer',
      'ctl': allowControl,
      'plat': platformName,
    });
    notifyListeners();
    return null;
  }

  Future<String?> _startCapture() async {
    final q = quality;
    if (Platform.isAndroid) {
      final error = await AndroidScreen.start(
        maxSide: q.maxSide,
        quality: q.jpeg,
        fps: q.fps,
        onFrame: _onCaptured,
        onStopped: () {
          if (_sharing) unawaited(stopSharing());
        },
        onVideoFailed: () {
          unawaited(AndroidScreen.setCodec('jpeg'));
          unawaited(_send(<String, dynamic>{'t': 'scr-codec', 'codec': 'jpeg'}));
        },
      );
      if (error == null) {
        _stopCapture = () => unawaited(AndroidScreen.stop());
      }
      return error;
    }
    if (Platform.isWindows) {
      final grabber = await WindowsScreenGrabber.start(
        maxSide: q.maxSide,
        quality: q.jpeg,
        fps: q.fps,
        onFrame: _onCaptured,
      );
      if (grabber == null) return 'Could not capture this screen.';
      _stopCapture = grabber.stop;
      return null;
    }
    return 'This device cannot share its screen.';
  }

  /// [data] is a JPEG picture (starts with 0xFF) or an H.264 piece (first
  /// byte 2 = full picture, 3 = change).
  void _onCaptured(Uint8List data) {
    if (!_sharing || !_watched || data.isEmpty) return;
    final session = _session;
    if (session == null) return;
    final jpeg = data[0] == 0xFF;
    if (jpeg) {
      if (_inFlight >= 2) return;
    } else {
      final key = data[0] == 2;
      if (_needKey && !key) return;
      if (_inFlight >= 10) {
        // Dropping a piece breaks the video until the next full picture.
        _needKey = true;
        unawaited(AndroidScreen.requestKeyFrame());
        return;
      }
      if (key) _needKey = false;
    }
    _inFlight++;
    final out = Uint8List(4 + data.length);
    ByteData.sublistView(out)
        .setUint32(0, jpeg ? screenFrameId : screenVideoId);
    out.setRange(4, out.length, data);
    unawaited(session.sendBytes(out));
  }

  /// Stops sharing and tells the other device.
  Future<void> stopSharing() async {
    final wasSharing = _sharing;
    _stopSharingLocal();
    notifyListeners();
    if (wasSharing) await _send(<String, dynamic>{'t': 'scr-stop'});
  }

  void _stopSharingLocal() {
    _stopCapture?.call();
    _stopCapture = null;
    _sharing = false;
    _watched = false;
    _inFlight = 0;
    if (_controlFromShare) _controlGranted = false;
    _controlFromShare = false;
  }

  // ---- Watching the other device's screen ---------------------------------

  /// Asks the other device to share its screen with us.
  Future<void> requestView() async {
    if (_session == null || _viewing) return;
    _asked = true;
    notice = null;
    _askTimer?.cancel();
    _askTimer = Timer(const Duration(seconds: 70), () {
      if (_asked && !_viewing) {
        _asked = false;
        notice = 'No answer from ${peerName()}.';
        notifyListeners();
      }
    });
    notifyListeners();
    await _send(<String, dynamic>{'t': 'scr-req'});
  }

  /// Stops watching (and ends the other device's sharing).
  Future<void> stopViewing() async {
    final wasOn = _viewing || _asked;
    _askTimer?.cancel();
    _disposeVideo();
    _viewing = false;
    _asked = false;
    _peerControl = false;
    frame.value = null;
    notifyListeners();
    if (wasOn) await _send(<String, dynamic>{'t': 'scr-unwatch'});
  }

  // ---- Remote control without a screen (phone as a touchpad) -------------

  /// Asks the other device for permission to control it.
  Future<void> requestControl() async {
    if (_session == null || _peerControl) return;
    notice = null;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'rc-req'});
  }

  /// Gives up control of the other device.
  Future<void> releaseControl() async {
    if (!_peerControl) return;
    _peerControl = false;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'rc-end'});
  }

  /// The person on this device takes back the control they allowed.
  Future<void> revokeControl() async {
    if (!_controlGranted) return;
    _controlGranted = false;
    _controlFromShare = false;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'rc-end'});
  }

  /// Sends one mouse, key or touch message to the controlled device.
  void sendInput(Map<String, dynamic> input) {
    if (!_peerControl) return;
    final session = _session;
    if (session == null) return;
    unawaited(session.send(<String, dynamic>{'t': 'rc', ...input}));
  }

  // ---- Incoming messages ------------------------------------------------------

  void _onMessage(Map<String, dynamic> m) {
    final type = m['t'];
    if (type is! String) return;
    switch (type) {
      case 'scr-req':
        unawaited(_onViewRequested());
      case 'scr-offer':
        unawaited(_onOffer(m));
      case 'scr-watch':
        if (_sharing) {
          _watched = true;
          _inFlight = 0;
          _needKey = false;
          unawaited(_chooseCodec(m['codec']));
        }
      case 'scr-want':
        if (_sharing) unawaited(_chooseCodec(m['codec']));
      case 'scr-key':
        if (_sharing) unawaited(AndroidScreen.requestKeyFrame());
      case 'scr-codec':
        if (m['codec'] == 'jpeg' && _codec != 'jpeg') {
          _disposeVideo();
          notice = 'Smooth video was not available, so simple video is used.';
          notifyListeners();
        }
      case 'scr-ack':
        if (_inFlight > 0) _inFlight--;
      case 'scr-unwatch':
        if (_sharing) {
          _stopSharingLocal();
          notice = '${peerName()} stopped watching.';
          notifyListeners();
        }
      case 'scr-no':
        _asked = false;
        _askTimer?.cancel();
        final why = m['why'];
        notice = why is String ? why : '${peerName()} did not allow it.';
        if (_sharing && !_watched) _stopSharingLocal();
        notifyListeners();
      case 'scr-stop':
        _askTimer?.cancel();
        _disposeVideo();
        if (_viewing || _asked) {
          _viewing = false;
          _asked = false;
          _peerControl = false;
          frame.value = null;
          notice = '${peerName()} stopped sharing.';
          notifyListeners();
        }
      case 'rc-req':
        unawaited(_onControlRequested());
      case 'rc-ok':
        _peerControl = true;
        notifyListeners();
      case 'rc-no':
        notice = '${peerName()} did not allow control.';
        notifyListeners();
      case 'rc-end':
        var changed = false;
        if (_peerControl) {
          _peerControl = false;
          notice = '${peerName()} ended control.';
          changed = true;
        }
        if (_controlGranted) {
          _controlGranted = false;
          _controlFromShare = false;
          changed = true;
        }
        if (changed) notifyListeners();
      case 'rc':
        _onInput(m);
      case 'qc':
        unawaited(_onQuick(m));
      case 'qc-r':
        final quickWhy = m['why'];
        notice = m['ok'] == true
            ? 'Done.'
            : (quickWhy is String ? quickWhy : 'That did not work.');
        notifyListeners();
      case 'qc-apps':
        unawaited(_onAppsRequested());
      case 'qc-apps-r':
        final raw = m['apps'];
        if (raw is List) {
          peerApps = <Map<String, String>>[
            for (final item in raw)
              if (item is Map && item['label'] is String && item['pkg'] is String)
                <String, String>{
                  'label': item['label'] as String,
                  'pkg': item['pkg'] as String,
                },
          ];
          notifyListeners();
        }
    }
  }

  /// Sharing side: use H.264 only when the viewer can play it and this
  /// phone can make it. Otherwise tell the viewer to use pictures.
  Future<void> _chooseCodec(Object? want) async {
    if (want == 'h264') {
      var ok = false;
      if (Platform.isAndroid) ok = await AndroidScreen.setCodec('h264');
      if (!ok) {
        await _send(<String, dynamic>{'t': 'scr-codec', 'codec': 'jpeg'});
      }
    } else if (Platform.isAndroid) {
      await AndroidScreen.setCodec('jpeg');
    }
  }

  void _onBinary(Uint8List data) {
    if (data.length <= 4) return;
    final id = ByteData.sublistView(data).getUint32(0);
    if (!_viewing) return;
    if (id == screenFrameId) {
      frame.value = Uint8List.sublistView(data, 4);
      unawaited(_send(<String, dynamic>{'t': 'scr-ack'}));
    } else if (id == screenVideoId && data.length > 5) {
      final viewer = _video;
      if (viewer != null) {
        viewer.add(Uint8List.sublistView(data, 5), data[4] == 2);
        _videoTimer ??= Timer(const Duration(seconds: 8), () {
          final current = _video;
          if (_viewing && current != null && !current.hasPicture) {
            unawaited(useSimpleVideo(
              why: 'Smooth video did not start, so simple video is used.',
            ));
          }
        });
      }
      unawaited(_send(<String, dynamic>{'t': 'scr-ack'}));
    }
  }

  Future<void> _onViewRequested() async {
    if (!supportsSharing) {
      await _send(<String, dynamic>{
        't': 'scr-no',
        'why': 'This device cannot share its screen.',
      });
      return;
    }
    if (_sharing) {
      await _send(<String, dynamic>{
        't': 'scr-offer',
        'ctl': _controlGranted,
        'plat': platformName,
      });
      return;
    }
    if (_starting) return;
    if (alwaysAllowView) {
      final error = await startSharing(allowControl: false);
      if (error != null) {
        await _send(<String, dynamic>{'t': 'scr-no', 'why': error});
      }
      return;
    }
    final answer = await ask(
      ConsentRequest(
        title: 'Show your screen to ${peerName()}?',
        message: '${peerName()} wants to see what is on this screen. '
            'You can stop at any time.',
        allowLabel: 'Show my screen',
        optionLabel: 'Also let ${peerName()} control this device',
        platform: peerPlatform(),
      ),
    );
    if (!answer.allow) {
      await _send(<String, dynamic>{'t': 'scr-no'});
      return;
    }
    final error = await startSharing(allowControl: answer.option);
    if (error != null) {
      await _send(<String, dynamic>{'t': 'scr-no', 'why': error});
    }
  }

  Future<void> _onOffer(Map<String, dynamic> m) async {
    if (_viewing) {
      _peerControl = m['ctl'] == true;
      notifyListeners();
      return;
    }
    var accept = _asked;
    if (!accept) {
      final answer = await ask(
        ConsentRequest(
          title: '${peerName()} is sharing its screen',
          message: 'Watch it on this device?',
          allowLabel: 'Watch',
          platform: peerPlatform(),
        ),
      );
      accept = answer.allow;
    }
    if (!accept) {
      await _send(<String, dynamic>{'t': 'scr-no'});
      return;
    }
    _askTimer?.cancel();
    var want = 'jpeg';
    if (preferH264 && H264Viewer.available) {
      final viewer = H264Viewer(
        onNeedKeyFrame: () => unawaited(_send(<String, dynamic>{'t': 'scr-key'})),
      );
      if (await viewer.start()) {
        _video = viewer;
        want = 'h264';
      } else {
        await viewer.dispose();
      }
    }
    _codec = want;
    _asked = false;
    _viewing = true;
    _peerControl = m['ctl'] == true;
    notice = null;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'scr-watch', 'codec': want});
  }

  Future<void> _onControlRequested() async {
    if (_session == null) return;
    if (Platform.isAndroid) {
      final on = await AndroidScreen.controlEnabled();
      if (!on) {
        await _send(<String, dynamic>{'t': 'rc-no'});
        return;
      }
    } else if (!Platform.isWindows) {
      await _send(<String, dynamic>{'t': 'rc-no'});
      return;
    }
    final answer = await ask(
      ConsentRequest(
        title: 'Let ${peerName()} control this device?',
        message: Platform.isWindows
            ? '${peerName()} will be able to move the mouse and type on this PC '
                'until you stop it or the link closes.'
            : '${peerName()} will be able to tap and swipe on this phone '
                'until you stop it or the link closes.',
        allowLabel: 'Allow control',
        platform: peerPlatform(),
      ),
    );
    if (!answer.allow) {
      await _send(<String, dynamic>{'t': 'rc-no'});
      return;
    }
    _controlGranted = true;
    _controlFromShare = false;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'rc-ok'});
  }

  void _onInput(Map<String, dynamic> m) {
    if (!_controlGranted) return;
    // Slow down a flood of messages: at most about 300 a second.
    final now = DateTime.now();
    _inputTimes.removeWhere(
      (time) => now.difference(time) > const Duration(seconds: 1),
    );
    if (_inputTimes.length >= 300) return;
    _inputTimes.add(now);

    if (Platform.isWindows) {
      _windowsInput ??= WindowsInput.tryCreate();
      _windowsInput?.apply(m);
    } else if (Platform.isAndroid) {
      unawaited(AndroidScreen.apply(Map<String, dynamic>.of(m)));
    }
  }

  // ---- Quick actions (lock, power, open an app, ...) -------------------------

  /// Asks the other device to do a one-tap action such as "lock".
  Future<void> sendQuick(String action, {String? argument}) async {
    if (!_peerControl) return;
    notice = null;
    notifyListeners();
    await _send(<String, dynamic>{
      't': 'qc',
      'a': action,
      if (argument != null) 's': argument,
    });
  }

  /// Asks the phone for the list of its apps.
  Future<void> requestApps() async {
    if (!_peerControl) return;
    await _send(<String, dynamic>{'t': 'qc-apps'});
  }

  Future<void> _onQuick(Map<String, dynamic> m) async {
    final action = m['a'];
    final raw = m['s'];
    if (action is! String || action.length > 32) return;
    final argument = raw is String && raw.length <= 2000 ? raw : null;
    Future<void> reply(String? error) => _send(<String, dynamic>{
          't': 'qc-r',
          'ok': error == null,
          if (error != null) 'why': error,
        });
    if (!_controlGranted) {
      await reply('Control is not allowed on that device.');
      return;
    }
    String? error;
    if (Platform.isWindows) {
      if (WindowsActions.isPower(action)) {
        final answer = await ask(
          ConsentRequest(
            title: 'Let ${peerName()} ${WindowsActions.label(action)} this PC?',
            message: 'It happens in 30 seconds. Choose Deny to stop it. '
                'You can also cancel from the phone.',
            allowLabel: 'Allow',
            platform: peerPlatform(),
          ),
        );
        if (!answer.allow || !_controlGranted) {
          await reply('The owner of the PC said no.');
          return;
        }
      }
      if (action == 'screenoff') {
        _windowsInput ??= WindowsInput.tryCreate();
        final input = _windowsInput;
        if (input == null) {
          error = 'Could not reach Windows.';
        } else {
          input.screenOff();
        }
      } else {
        error = await WindowsActions.run(action, argument: argument);
      }
    } else if (Platform.isAndroid) {
      error = await AndroidScreen.quick(action, argument: argument);
    } else {
      error = 'This device does not support that.';
    }
    await reply(error);
  }

  Future<void> _onAppsRequested() async {
    if (!_controlGranted || !Platform.isAndroid) return;
    final apps = await AndroidScreen.listApps();
    await _send(<String, dynamic>{'t': 'qc-apps-r', 'apps': apps});
  }

  /// Handy for the screens: the aspect of the latest picture is read from
  /// the picture itself, so nothing is stored here.
  static double clampUnit(double value) => math.min(1, math.max(0, value));
}
