import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Windows only: moving the mouse, pressing keys and taking pictures of the
// screen. These call Windows directly (user32, gdi32 and gdiplus). Nothing
// here runs on other systems.
// ---------------------------------------------------------------------------

typedef _GetSystemMetricsC = Int32 Function(Int32);
typedef _GetSystemMetricsD = int Function(int);
typedef _SetCursorPosC = Int32 Function(Int32, Int32);
typedef _SetCursorPosD = int Function(int, int);
typedef _MouseEventC = Void Function(Uint32, Uint32, Uint32, Uint32, IntPtr);
typedef _MouseEventD = void Function(int, int, int, int, int);
typedef _KeybdEventC = Void Function(Uint8, Uint8, Uint32, IntPtr);
typedef _KeybdEventD = void Function(int, int, int, int);
typedef _SendInputC = Uint32 Function(Uint32, Pointer<Uint8>, Int32);
typedef _SendInputD = int Function(int, Pointer<Uint8>, int);
typedef _PostMessageC = Int32 Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _PostMessageD = int Function(int, int, int, int);
typedef _GetDcC = IntPtr Function(IntPtr);
typedef _GetDcD = int Function(int);
typedef _ReleaseDcC = Int32 Function(IntPtr, IntPtr);
typedef _ReleaseDcD = int Function(int, int);

typedef _CreateCompatibleDcC = IntPtr Function(IntPtr);
typedef _CreateCompatibleDcD = int Function(int);
typedef _CreateCompatibleBitmapC = IntPtr Function(IntPtr, Int32, Int32);
typedef _CreateCompatibleBitmapD = int Function(int, int, int);
typedef _SelectObjectC = IntPtr Function(IntPtr, IntPtr);
typedef _SelectObjectD = int Function(int, int);
typedef _SetStretchBltModeC = Int32 Function(IntPtr, Int32);
typedef _SetStretchBltModeD = int Function(int, int);
typedef _StretchBltC = Int32 Function(
  IntPtr,
  Int32,
  Int32,
  Int32,
  Int32,
  IntPtr,
  Int32,
  Int32,
  Int32,
  Int32,
  Uint32,
);
typedef _StretchBltD = int Function(
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
);
typedef _DeleteObjectC = Int32 Function(IntPtr);
typedef _DeleteObjectD = int Function(int);

typedef _GdiplusStartupC = Int32 Function(
  Pointer<IntPtr>,
  Pointer<Uint8>,
  Pointer<Void>,
);
typedef _GdiplusStartupD = int Function(
  Pointer<IntPtr>,
  Pointer<Uint8>,
  Pointer<Void>,
);
typedef _GdiplusShutdownC = Void Function(IntPtr);
typedef _GdiplusShutdownD = void Function(int);
typedef _GdipFromHbitmapC = Int32 Function(IntPtr, IntPtr, Pointer<IntPtr>);
typedef _GdipFromHbitmapD = int Function(int, int, Pointer<IntPtr>);
typedef _GdipSaveC = Int32 Function(
  IntPtr,
  Pointer<Utf16>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _GdipSaveD = int Function(
  int,
  Pointer<Utf16>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _GdipDisposeC = Int32 Function(IntPtr);
typedef _GdipDisposeD = int Function(int);

// ---------------------------------------------------------------------------
// Mouse and keyboard
// ---------------------------------------------------------------------------

/// Moves the mouse, clicks, scrolls and types on this PC. Only used after the
/// person on this PC has allowed the other device to control it.
class WindowsInput {
  WindowsInput._() {
    final user32 = DynamicLibrary.open('user32.dll');
    _metrics = user32.lookupFunction<_GetSystemMetricsC, _GetSystemMetricsD>(
      'GetSystemMetrics',
    );
    _setCursor = user32.lookupFunction<_SetCursorPosC, _SetCursorPosD>(
      'SetCursorPos',
    );
    _mouse = user32.lookupFunction<_MouseEventC, _MouseEventD>('mouse_event');
    _key = user32.lookupFunction<_KeybdEventC, _KeybdEventD>('keybd_event');
    _sendInput = user32.lookupFunction<_SendInputC, _SendInputD>('SendInput');
    _post = user32.lookupFunction<_PostMessageC, _PostMessageD>('PostMessageW');
  }

  /// Null when this is not Windows or Windows could not be reached.
  static WindowsInput? tryCreate() {
    if (!Platform.isWindows) return null;
    try {
      return WindowsInput._();
    } catch (_) {
      return null;
    }
  }

  late final _GetSystemMetricsD _metrics;
  late final _SetCursorPosD _setCursor;
  late final _MouseEventD _mouse;
  late final _KeybdEventD _key;
  late final _SendInputD _sendInput;
  late final _PostMessageD _post;

  /// Turns the monitors off (they wake again when the mouse moves).
  void screenOff() {
    // HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off.
    _post(0xFFFF, 0x0112, 0xF170, 2);
  }

  static const int _leftDown = 0x0002;
  static const int _leftUp = 0x0004;
  static const int _rightDown = 0x0008;
  static const int _rightUp = 0x0010;
  static const int _middleDown = 0x0020;
  static const int _middleUp = 0x0040;
  static const int _wheel = 0x0800;
  static const int _move = 0x0001;
  static const int _keyUp = 0x0002;
  static const int _extended = 0x0001;

  /// Keys the other device may press. Anything else is ignored.
  static bool _allowedKey(int vk) {
    if (vk >= 0x30 && vk <= 0x39) return true; // 0-9
    if (vk >= 0x41 && vk <= 0x5A) return true; // A-Z
    if (vk >= 0x70 && vk <= 0x7B) return true; // F1-F12
    if (vk >= 0x21 && vk <= 0x28) return true; // page, end, home, arrows
    if (vk >= 0xAD && vk <= 0xB3) return true; // volume and media
    return const {
      0x08, // backspace
      0x09, // tab
      0x0D, // enter
      0x10, // shift
      0x11, // ctrl
      0x12, // alt
      0x1B, // escape
      0x20, // space
      0x2E, // delete
    }.contains(vk);
  }

  static bool _isExtendedKey(int vk) =>
      (vk >= 0x21 && vk <= 0x28) || vk == 0x2E || (vk >= 0xAD && vk <= 0xB3);

  int get screenWidth => _metrics(0);
  int get screenHeight => _metrics(1);

  /// Carries out one message from the controlling device.
  void apply(Map<String, dynamic> m) {
    final kind = m['k'];
    switch (kind) {
      case 'abs':
        final x = _unit(m['x']);
        final y = _unit(m['y']);
        if (x == null || y == null) return;
        _setCursor(
          (x * (screenWidth - 1)).round(),
          (y * (screenHeight - 1)).round(),
        );
      case 'rel':
        final dx = _small(m['dx']);
        final dy = _small(m['dy']);
        if (dx == null || dy == null) return;
        _mouse(_move, dx & 0xFFFFFFFF, dy & 0xFFFFFFFF, 0, 0);
      case 'down':
        _button(m['b'], true);
      case 'up':
        _button(m['b'], false);
      case 'click':
        _button(m['b'], true);
        _button(m['b'], false);
      case 'dbl':
        for (var i = 0; i < 2; i++) {
          _button('l', true);
          _button('l', false);
        }
      case 'wheel':
        final ticks = _small(m['d']);
        if (ticks == null) return;
        final steps = math.min(20, math.max(-20, ticks));
        final amount = steps * 120;
        _mouse(_wheel, 0, 0, amount & 0xFFFFFFFF, 0);
      case 'key':
        final vk = m['vk'];
        final down = m['down'];
        if (vk is! int || down is! bool || !_allowedKey(vk)) return;
        _pressKey(vk, down);
      case 'tap':
        final tapVk = m['vk'];
        if (tapVk is! int || !_allowedKey(tapVk)) return;
        _pressKey(tapVk, true);
        _pressKey(tapVk, false);
      case 'text':
        final text = m['s'];
        if (text is String) {
          _typeText(text.length > 500 ? text.substring(0, 500) : text);
        }
    }
  }

  double? _unit(Object? value) {
    if (value is! num) return null;
    final v = value.toDouble();
    if (v.isNaN) return null;
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  int? _small(Object? value) {
    if (value is! num) return null;
    final v = value.round();
    return v < -2000 ? -2000 : (v > 2000 ? 2000 : v);
  }

  void _button(Object? which, bool down) {
    switch (which) {
      case 'r':
        _mouse(down ? _rightDown : _rightUp, 0, 0, 0, 0);
      case 'm':
        _mouse(down ? _middleDown : _middleUp, 0, 0, 0, 0);
      default:
        _mouse(down ? _leftDown : _leftUp, 0, 0, 0, 0);
    }
  }

  void _pressKey(int vk, bool down) {
    final flags = (down ? 0 : _keyUp) | (_isExtendedKey(vk) ? _extended : 0);
    _key(vk, 0, flags, 0);
  }

  /// Types text, including letters outside the keyboard, with SendInput.
  void _typeText(String text) {
    final units = text.codeUnits;
    if (units.isEmpty) return;
    const inputSize = 40; // size of the INPUT structure on 64-bit Windows
    final count = units.length * 2;
    final memory = calloc<Uint8>(count * inputSize);
    try {
      final view = ByteData.sublistView(memory.asTypedList(count * inputSize));
      var index = 0;
      for (final unit in units) {
        for (final up in const [false, true]) {
          final base = index * inputSize;
          view.setUint32(base, 1, Endian.little); // INPUT_KEYBOARD
          view.setUint16(base + 8, 0, Endian.little); // wVk
          view.setUint16(base + 10, unit, Endian.little); // wScan
          // KEYEVENTF_UNICODE (0x4), plus KEYEVENTF_KEYUP (0x2) on release.
          view.setUint32(base + 12, up ? 0x6 : 0x4, Endian.little);
          index++;
        }
      }
      _sendInput(count, memory, inputSize);
    } finally {
      calloc.free(memory);
    }
  }
}

// ---------------------------------------------------------------------------
// Taking pictures of the screen
// ---------------------------------------------------------------------------

/// Takes a picture of the PC screen again and again, as small JPEG files, in
/// a background isolate so the app never stutters.
class WindowsScreenGrabber {
  WindowsScreenGrabber._(this._isolate, this._frames, this._control);

  final Isolate _isolate;
  final ReceivePort _frames;
  final SendPort _control;

  static bool get supported => Platform.isWindows;

  /// Starts taking pictures. [onFrame] gets each JPEG. Returns null when the
  /// screen could not be reached.
  static Future<WindowsScreenGrabber?> start({
    required int maxSide,
    required int quality,
    required int fps,
    required void Function(Uint8List jpeg) onFrame,
  }) async {
    if (!supported) return null;
    final frames = ReceivePort();
    final ready = Completer<SendPort>();
    frames.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is TransferableTypedData) {
        onFrame(message.materialize().asUint8List());
      } else if (message == 'failed') {
        if (!ready.isCompleted) ready.completeError(StateError('No screen'));
      }
    });
    try {
      final isolate = await Isolate.spawn<List<Object?>>(
        _grabMain,
        <Object?>[frames.sendPort, maxSide, quality, fps],
      );
      final control = await ready.future.timeout(const Duration(seconds: 6));
      return WindowsScreenGrabber._(isolate, frames, control);
    } catch (_) {
      frames.close();
      return null;
    }
  }

  void stop() {
    _control.send('stop');
    // Give the isolate a moment to free the GDI+ objects, then end it.
    Timer(const Duration(milliseconds: 600), () {
      _isolate.kill(priority: Isolate.immediate);
      _frames.close();
    });
  }
}

void _writeGuid(
  Pointer<Uint8> target,
  int data1,
  int data2,
  int data3,
  List<int> data4,
) {
  final view = ByteData.sublistView(target.asTypedList(16));
  view.setUint32(0, data1, Endian.little);
  view.setUint16(4, data2, Endian.little);
  view.setUint16(6, data3, Endian.little);
  for (var i = 0; i < 8; i++) {
    view.setUint8(8 + i, data4[i]);
  }
}

Future<void> _grabMain(List<Object?> setup) async {
  final reply = setup[0]! as SendPort;
  final maxSide = setup[1]! as int;
  final quality = setup[2]! as int;
  final fps = setup[3]! as int;

  final control = ReceivePort();
  var stopped = false;
  control.listen((Object? message) {
    if (message == 'stop') stopped = true;
  });

  late final _GetSystemMetricsD metrics;
  late final _GetDcD getDc;
  late final _ReleaseDcD releaseDc;
  late final _CreateCompatibleDcD createDc;
  late final _CreateCompatibleBitmapD createBitmap;
  late final _SelectObjectD selectObject;
  late final _SetStretchBltModeD setStretchMode;
  late final _StretchBltD stretchBlt;
  late final _DeleteObjectD deleteObject;
  late final _DeleteObjectD deleteDc;
  late final _GdiplusStartupD gdiStartup;
  late final _GdiplusShutdownD gdiShutdown;
  late final _GdipFromHbitmapD fromHbitmap;
  late final _GdipSaveD saveImage;
  late final _GdipDisposeD disposeImage;

  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final gdi32 = DynamicLibrary.open('gdi32.dll');
    final gdiplus = DynamicLibrary.open('gdiplus.dll');
    metrics = user32.lookupFunction<_GetSystemMetricsC, _GetSystemMetricsD>(
      'GetSystemMetrics',
    );
    getDc = user32.lookupFunction<_GetDcC, _GetDcD>('GetDC');
    releaseDc = user32.lookupFunction<_ReleaseDcC, _ReleaseDcD>('ReleaseDC');
    createDc = gdi32.lookupFunction<_CreateCompatibleDcC, _CreateCompatibleDcD>(
      'CreateCompatibleDC',
    );
    createBitmap = gdi32.lookupFunction<_CreateCompatibleBitmapC,
        _CreateCompatibleBitmapD>('CreateCompatibleBitmap');
    selectObject = gdi32.lookupFunction<_SelectObjectC, _SelectObjectD>(
      'SelectObject',
    );
    setStretchMode =
        gdi32.lookupFunction<_SetStretchBltModeC, _SetStretchBltModeD>(
      'SetStretchBltMode',
    );
    stretchBlt = gdi32.lookupFunction<_StretchBltC, _StretchBltD>('StretchBlt');
    deleteObject = gdi32.lookupFunction<_DeleteObjectC, _DeleteObjectD>(
      'DeleteObject',
    );
    deleteDc = gdi32.lookupFunction<_DeleteObjectC, _DeleteObjectD>('DeleteDC');
    gdiStartup = gdiplus.lookupFunction<_GdiplusStartupC, _GdiplusStartupD>(
      'GdiplusStartup',
    );
    gdiShutdown = gdiplus.lookupFunction<_GdiplusShutdownC, _GdiplusShutdownD>(
      'GdiplusShutdown',
    );
    fromHbitmap = gdiplus.lookupFunction<_GdipFromHbitmapC, _GdipFromHbitmapD>(
      'GdipCreateBitmapFromHBITMAP',
    );
    saveImage = gdiplus.lookupFunction<_GdipSaveC, _GdipSaveD>(
      'GdipSaveImageToFile',
    );
    disposeImage = gdiplus.lookupFunction<_GdipDisposeC, _GdipDisposeD>(
      'GdipDisposeImage',
    );
  } catch (_) {
    reply.send('failed');
    return;
  }

  // Start GDI+, which turns the picture into a JPEG.
  final token = calloc<IntPtr>();
  final startupInput = calloc<Uint8>(32);
  ByteData.sublistView(startupInput.asTypedList(32))
      .setUint32(0, 1, Endian.little); // GdiplusVersion = 1
  if (gdiStartup(token, startupInput, nullptr) != 0) {
    calloc.free(token);
    calloc.free(startupInput);
    reply.send('failed');
    return;
  }
  calloc.free(startupInput);

  // JPEG encoder id and the "quality" setting.
  final jpegClsid = calloc<Uint8>(16);
  _writeGuid(jpegClsid, 0x557CF401, 0x1A04, 0x11D3,
      const [0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E]);
  final qualityValue = calloc<Uint32>();
  qualityValue.value = math.min(95, math.max(10, quality));
  final encoderParams = calloc<Uint8>(40);
  {
    final view = ByteData.sublistView(encoderParams.asTypedList(40));
    view.setUint32(0, 1, Endian.little); // one parameter
    // Parameter starts at byte 8: GUID, count of values, type, pointer.
    _writeGuid(
      Pointer<Uint8>.fromAddress(encoderParams.address + 8),
      0x1D5BE4B5,
      0xFA4A,
      0x452D,
      const [0x9C, 0xDD, 0x5D, 0xB3, 0x51, 0x05, 0xE7, 0xEB],
    );
    view.setUint32(24, 1, Endian.little);
    view.setUint32(28, 4, Endian.little); // EncoderParameterValueTypeLong
    view.setUint64(32, qualityValue.address, Endian.little);
  }

  final path =
      '${Directory.systemTemp.path}\\zephlink_screen_$pid.jpg';
  final pathNative = path.toNativeUtf16();
  final bitmapOut = calloc<IntPtr>();

  reply.send(control.sendPort);

  final frameTime = Duration(milliseconds: (1000 / math.max(1, fps)).round());
  const srcCopy = 0x00CC0020;
  const captureBlt = 0x40000000;
  try {
    while (!stopped) {
      final started = DateTime.now();
      try {
        final width = metrics(0);
        final height = metrics(1);
        if (width > 0 && height > 0) {
          final scale = math.min(1.0, maxSide / math.max(width, height));
          final outW = math.max(2, (width * scale).round() & ~1);
          final outH = math.max(2, (height * scale).round() & ~1);
          final screenDc = getDc(0);
          final memDc = createDc(screenDc);
          final bitmap = createBitmap(screenDc, outW, outH);
          final old = selectObject(memDc, bitmap);
          setStretchMode(memDc, 4); // HALFTONE: smoother when shrinking
          stretchBlt(memDc, 0, 0, outW, outH, screenDc, 0, 0, width, height,
              srcCopy | captureBlt);
          selectObject(memDc, old);
          if (fromHbitmap(bitmap, 0, bitmapOut) == 0) {
            final image = bitmapOut.value;
            final status = saveImage(image, pathNative, jpegClsid, encoderParams);
            disposeImage(image);
            if (status == 0) {
              final bytes = File(path).readAsBytesSync();
              reply.send(TransferableTypedData.fromList([bytes]));
            }
          }
          deleteObject(bitmap);
          deleteDc(memDc);
          releaseDc(0, screenDc);
        }
      } catch (_) {
        // Skip this picture and try the next one.
      }
      final spent = DateTime.now().difference(started);
      final wait = frameTime - spent;
      await Future<void>.delayed(
        wait > const Duration(milliseconds: 5)
            ? wait
            : const Duration(milliseconds: 5),
      );
    }
  } finally {
    try {
      gdiShutdown(token.value);
      File(path).deleteSync();
    } catch (_) {
      // Leftover temporary file is harmless.
    }
    calloc.free(token);
    calloc.free(jpegClsid);
    calloc.free(qualityValue);
    calloc.free(encoderParams);
    calloc.free(bitmapOut);
    calloc.free(pathNative);
    control.close();
  }
}
