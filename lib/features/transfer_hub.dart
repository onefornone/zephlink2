import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../link/hash_worker.dart';
import '../link/secure_session.dart';
import '../platform/android_file_picker.dart';

enum TransferState { waiting, active, paused, done, failed, cancelled }

class TransferSource {
  const TransferSource({required this.file, this.relativePath});

  final XFile file;
  final String? relativePath;
}

/// One file going to or coming from the other device.
class TransferItem {
  TransferItem({
    required this.id,
    required this.name,
    required this.size,
    required this.outgoing,
    required this.resumeKey,
    this.path,
    this.relativePath,
  });

  int id;
  final String name;
  final int size;
  final bool outgoing;
  final String resumeKey;

  /// Local path for opening a received file or previewing a sent one.
  String? path;
  final String? relativePath;
  String? externalUri;

  int bytes = 0;
  TransferState state = TransferState.waiting;
  String? error;
  final DateTime started = DateTime.now();
  DateTime? finished;

  double get progress {
    if (size <= 0) return state == TransferState.done ? 1.0 : 0.0;
    return math.min(1.0, math.max(0.0, bytes / size));
  }

  bool get running =>
      state == TransferState.waiting || state == TransferState.active;

  /// Average speed in bytes per second.
  double get speed {
    final end = finished ?? DateTime.now();
    final seconds = end.difference(started).inMilliseconds / 1000;
    return seconds <= 0 ? 0 : bytes / seconds;
  }
}

extension _TryComplete<T> on Completer<T> {
  void tryComplete(T value) {
    if (!isCompleted) complete(value);
  }
}

class _Outgoing {
  _Outgoing(this.item);

  final TransferItem item;
  final Completer<int?> accept = Completer<int?>();
  final Completer<void> done = Completer<void>();
  Completer<void>? ackWait;
  int sent = 0;
  int acked = 0;
  bool cancelled = false;
  bool connectionLost = false;

  void wake() {
    final waiter = ackWait;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}

class _Incoming {
  _Incoming(
    this.item,
    this.sink,
    this.file,
    this.hasher, {
    required this.resumable,
  });

  final TransferItem item;
  final IOSink sink;
  final File file;
  final FileHasher hasher;
  final bool resumable;
  Future<void> writeChain = Future<void>.value();
  int received = 0;
  int sinceAck = 0;
  Object? writeError;
  bool stopped = false;
}

/// Sends and receives files over a [SecureSession], with progress.
class TransferHub {
  static final math.Random _secureRandom = math.Random.secure();

  TransferHub({
    required this.onChanged,
    required this.onActivity,
    required this.autoReceive,
    this.fixedReceiveDir,
    this.onFileReceived,
  });

  final void Function() onChanged;
  final void Function(String text, String kind) onActivity;
  final Future<void> Function(TransferItem item)? onFileReceived;
  final bool Function() autoReceive;

  /// Save received files here instead of the usual folder (used by tests).
  final Directory? fixedReceiveDir;

  /// Newest first.
  final List<TransferItem> items = [];

  /// Folder where received files are saved (known after the first receive).
  String? receiveFolder;

  static const int _window = 4 * 1024 * 1024;
  static const int _ackEvery = 1024 * 1024;
  static const int _chunkSize = 1024 * 1024;

  SecureSession? _session;
  StreamSubscription<Map<String, dynamic>>? _messageSub;
  StreamSubscription<Uint8List>? _binarySub;
  final Map<int, _Outgoing> _outgoing = {};
  final Map<int, _Incoming> _incoming = {};
  Future<void> _queue = Future<void>.value();
  int _nextId = 1;
  Timer? _throttle;
  Directory? _dir;

  // ---- Connection ---------------------------------------------------------

  /// Subscribes to the session. Call before the session starts reading.
  void attach(SecureSession session) {
    detach();
    _session = session;
    _messageSub = session.messages.listen(_onMessage);
    _binarySub = session.binary.listen(_onBinary);
  }

  void detach() {
    unawaited(_messageSub?.cancel());
    unawaited(_binarySub?.cancel());
    _messageSub = null;
    _binarySub = null;
    _session = null;
    for (final incoming in _incoming.values) {
      unawaited(_pauseIncoming(incoming));
    }
    _incoming.clear();
    for (final out in _outgoing.values) {
      out.connectionLost = true;
      out.cancelled = true;
      out.wake();
      out.accept.tryComplete(null);
      if (!out.done.isCompleted) out.done.complete();
    }
    for (final item in items) {
      if (item.running &&
          !_outgoing.values.any((out) => identical(out.item, item))) {
        _pauseItem(item);
      }
    }
    _changed();
  }

  void _changed() {
    _throttle ??= Timer(const Duration(milliseconds: 150), () {
      _throttle = null;
      onChanged();
    });
  }

  // ---- Sending ------------------------------------------------------------

  Future<void> sendFiles(List<XFile> files) async {
    await sendSources(files.map((file) => TransferSource(file: file)).toList());
  }

  Future<void> sendSources(List<TransferSource> sources) async {
    final session = _session;
    if (session == null || sources.isEmpty) return;
    for (final source in sources) {
      final file = source.file;
      try {
        final size = await file.length();
        final relativePath = _safeRelativePath(source.relativePath);
        final name = relativePath?.split('/').last ?? file.name;
        final item = TransferItem(
          id: _nextId++,
          name: _safeName(name),
          size: size,
          outgoing: true,
          resumeKey: _newResumeKey(),
          path: file.path,
          relativePath: relativePath,
        );
        items.insert(0, item);
        _changed();
        _queue = _queue.then((_) => _sendOne(session, item, file));
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'Zephlink folder transfer',
            context: ErrorDescription('while preparing a file to send'),
          ),
        );
      }
    }
  }

  Future<void> _sendOne(
    SecureSession session,
    TransferItem item,
    XFile file,
  ) async {
    if (!item.running) return;
    if (!identical(session, _session) || session.isClosed) {
      _pauseItem(item);
      return;
    }
    final out = _Outgoing(item);
    _outgoing[item.id] = out;
    FileHasher? hasherToFree;
    try {
      await session.send(<String, dynamic>{
        't': 'file-offer',
        'id': item.id,
        'name': item.name,
        'size': item.size,
        'resumeKey': item.resumeKey,
        if (item.relativePath != null) 'relativePath': item.relativePath,
      });
      final offset =
          await out.accept.future.timeout(const Duration(seconds: 30));
      if (offset == null) {
        if (out.connectionLost || session.isClosed) {
          _pauseItem(item);
        } else {
          _finishItem(item, TransferState.cancelled, 'Not accepted');
        }
        return;
      }
      if (offset < 0 || offset > item.size) {
        _finishItem(item, TransferState.failed, 'Invalid resume position');
        return;
      }
      item.state = TransferState.active;
      item.bytes = offset;
      out.sent = offset;
      out.acked = offset;
      _changed();

      final hasher = await FileHasher.create(item.size);
      hasherToFree = hasher;
      if (offset > 0) {
        await for (final chunk in _fileChunks(file.openRead(0, offset))) {
          await hasher.add(chunk);
        }
      }
      await for (final chunk in _fileChunks(file.openRead(offset))) {
        if (out.cancelled || session.isClosed) break;
        while (out.sent - out.acked > _window &&
            !out.cancelled &&
            !session.isClosed) {
          final waiter = Completer<void>();
          out.ackWait = waiter;
          await waiter.future.timeout(const Duration(seconds: 30));
        }
        if (out.cancelled || session.isClosed) break;
        final frame = Uint8List(4 + chunk.length);
        ByteData.sublistView(frame).setUint32(0, item.id);
        frame.setRange(4, frame.length, chunk);
        // The checksum is worked out in a helper while the chunk is sent.
        final hashing = hasher.add(chunk);
        await session.sendBytes(frame);
        await hashing;
        out.sent += chunk.length;
        item.bytes = out.sent;
        _changed();
      }

      if (out.connectionLost || session.isClosed) {
        _pauseItem(item);
        return;
      }
      if (out.cancelled) {
        _finishItem(item, TransferState.cancelled, 'Cancelled');
        return;
      }
      final checksum = await hasher.finish();
      await session.send(<String, dynamic>{
        't': 'file-end',
        'id': item.id,
        'sha256': checksum,
      });
      await out.done.future.timeout(const Duration(seconds: 60));
      if (out.connectionLost || session.isClosed) {
        _pauseItem(item);
        return;
      }
      if (out.cancelled) {
        _finishItem(item, TransferState.cancelled, 'Cancelled');
        return;
      }
      item.bytes = item.size;
      _finishItem(item, TransferState.done, null);
      onActivity('Sent ${item.name}', 'send');
    } on TimeoutException {
      if (out.connectionLost || session.isClosed) {
        _pauseItem(item);
      } else {
        _finishItem(
          item,
          TransferState.failed,
          'The other device stopped answering',
        );
      }
    } catch (_) {
      if (out.connectionLost || session.isClosed) {
        _pauseItem(item);
      } else {
        _finishItem(item, TransferState.failed, 'Could not send');
      }
    } finally {
      hasherToFree?.dispose();
      _outgoing.remove(item.id);
      if (item.state == TransferState.done ||
          item.state == TransferState.failed ||
          item.state == TransferState.cancelled) {
        await _cleanupPickedFile(file);
      }
    }
  }

  Future<void> _cleanupPickedFile(XFile file) async {
    if (!Platform.isAndroid || file.path.isEmpty) return;
    try {
      await AndroidFilePicker.deleteAfterTransfer(file.path);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink Android file picker',
          context: ErrorDescription('while cleaning a selected file'),
        ),
      );
    }
  }

  static Stream<Uint8List> _fileChunks(Stream<List<int>> source) async* {
    var buffer = Uint8List(_chunkSize);
    var used = 0;
    await for (final part in source) {
      var offset = 0;
      while (offset < part.length) {
        final count = math.min(_chunkSize - used, part.length - offset);
        buffer.setRange(used, used + count, part, offset);
        used += count;
        offset += count;
        if (used == _chunkSize) {
          yield buffer;
          buffer = Uint8List(_chunkSize);
          used = 0;
        }
      }
    }
    if (used > 0) yield Uint8List.sublistView(buffer, 0, used);
  }

  void _finishItem(TransferItem item, TransferState state, String? error) {
    item.state = state;
    item.error = error;
    item.finished = DateTime.now();
    _changed();
  }

  void _pauseItem(TransferItem item) {
    item.state = TransferState.paused;
    item.error = 'Connection lost. Reconnect and resume to continue.';
    item.finished = null;
    _changed();
  }

  Future<void> _pauseIncoming(_Incoming incoming) async {
    await incoming.writeChain;
    incoming.stopped = true;
    incoming.hasher.dispose();
    try {
      await incoming.sink.flush();
      await incoming.sink.close();
      if (incoming.resumable) {
        _pauseItem(incoming.item);
      } else {
        await incoming.file.delete();
        _finishItem(incoming.item, TransferState.failed, 'Connection lost');
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink transfer',
          context: ErrorDescription('while pausing a received file'),
        ),
      );
      _finishItem(
          incoming.item, TransferState.failed, 'Could not save progress');
    }
  }

  /// Stops a transfer you started or one that is coming in.
  void cancel(TransferItem item) {
    final session = _session;
    if (item.outgoing) {
      final out = _outgoing[item.id];
      if (out != null) {
        out.cancelled = true;
        out.wake();
        out.accept.tryComplete(null);
        if (!out.done.isCompleted) out.done.complete();
      } else if (item.running || item.state == TransferState.paused) {
        _finishItem(item, TransferState.cancelled, 'Cancelled');
        final path = item.path;
        if (path != null) {
          unawaited(_cleanupPickedFile(XFile(path)));
        }
      }
    } else {
      final incoming = _incoming.remove(item.id);
      if (incoming != null) {
        unawaited(
          _closeIncoming(incoming, TransferState.cancelled, 'Cancelled'),
        );
      } else if (item.state == TransferState.paused) {
        unawaited(_partialFile(item.resumeKey).then((file) async {
          if (await file.exists()) await file.delete();
          _finishItem(item, TransferState.cancelled, 'Cancelled');
        }));
      }
    }
    if (session != null && !session.isClosed) {
      unawaited(session.send(<String, dynamic>{
        't': 'file-cancel',
        'id': item.id,
        'resumeKey': item.resumeKey,
      }));
    }
  }

  Future<void> resume(TransferItem item) async {
    final session = _session;
    final path = item.path;
    if (!item.outgoing ||
        item.state != TransferState.paused ||
        session == null ||
        path == null) {
      return;
    }
    if (_outgoing.values.any((out) => identical(out.item, item))) return;
    final file = File(path);
    if (!await file.exists() || await file.length() != item.size) {
      _finishItem(
          item, TransferState.failed, 'The original file is unavailable.');
      return;
    }
    item.id = _nextId++;
    item.state = TransferState.waiting;
    item.error = null;
    item.finished = null;
    _changed();
    _queue = _queue.then((_) => _sendOne(session, item, XFile(path)));
  }

  void clearFinished() {
    items.removeWhere(
      (item) =>
          item.state == TransferState.done ||
          item.state == TransferState.failed ||
          item.state == TransferState.cancelled,
    );
    _changed();
  }

  // ---- Receiving ----------------------------------------------------------

  void _onMessage(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is! int) return;
    switch (m['t']) {
      case 'file-offer':
        unawaited(_onOffer(m, id));
      case 'file-accept':
        final offset = m['n'];
        _outgoing[id]?.accept.tryComplete(offset is int ? offset : 0);
      case 'file-reject':
        _outgoing[id]?.accept.tryComplete(null);
      case 'file-ack':
        final acking = _outgoing[id];
        final n = m['n'];
        if (acking != null && n is int) {
          acking.acked = n;
          acking.wake();
        }
      case 'file-end':
        unawaited(_onEnd(id, m['sha256']));
      case 'file-done':
        final finishing = _outgoing[id];
        if (finishing != null && !finishing.done.isCompleted) {
          finishing.done.complete();
        }
      case 'file-cancel':
        _onCancelled(id, m['resumeKey']);
    }
  }

  void _onCancelled(int id, Object? resumeKey) {
    final incoming = _incoming.remove(id);
    if (incoming != null) {
      unawaited(
        _closeIncoming(
          incoming,
          TransferState.cancelled,
          'Cancelled by the sender',
        ),
      );
    }
    if (incoming == null && resumeKey is String) {
      final item = _findIncomingItem(resumeKey);
      if (item != null) {
        unawaited(_partialFile(item.resumeKey).then((file) async {
          if (await file.exists()) await file.delete();
          _finishItem(item, TransferState.cancelled, 'Cancelled by the sender');
        }));
      }
    }
    final out = _outgoing[id];
    if (out != null) {
      out.cancelled = true;
      out.wake();
      out.accept.tryComplete(null);
      if (!out.done.isCompleted) out.done.complete();
    }
  }

  Future<void> _onOffer(Map<String, dynamic> m, int id) async {
    final session = _session;
    if (session == null) return;
    final name = m['name'];
    final size = m['size'];
    if (name is! String || size is! int || size < 0) return;
    final relativePath = _safeRelativePath(m['relativePath']);
    if (m['relativePath'] != null && relativePath == null) {
      await session.send(<String, dynamic>{'t': 'file-reject', 'id': id});
      return;
    }
    final incomingKey = m['resumeKey'];
    if (incomingKey != null &&
        (incomingKey is! String ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(incomingKey))) {
      await session.send(<String, dynamic>{'t': 'file-reject', 'id': id});
      return;
    }
    final resumable = incomingKey is String;
    final resumeKey = resumable ? incomingKey : _newResumeKey();
    if (!autoReceive() || _incoming.containsKey(id)) {
      await session.send(<String, dynamic>{'t': 'file-reject', 'id': id});
      return;
    }
    if (_incoming.values.any((entry) => entry.item.resumeKey == resumeKey)) {
      await session.send(<String, dynamic>{'t': 'file-reject', 'id': id});
      return;
    }
    try {
      final dir = await _receiveDir();
      final existing = _findIncomingItem(resumeKey);
      if (existing != null &&
          (existing.size != size || existing.relativePath != relativePath)) {
        await session.send(<String, dynamic>{'t': 'file-reject', 'id': id});
        return;
      }
      final finalFile = existing?.path == null
          ? relativePath == null
              ? await _uniqueFile(dir, _safeName(name))
              : await _fileForRelativePath(dir, relativePath)
          : File(existing!.path!);
      final partial = await _partialFile(resumeKey);
      if (await partial.exists() && await partial.length() > size) {
        await partial.delete();
      }
      final offset = await partial.exists() ? await partial.length() : 0;
      final hasher = await FileHasher.create(size);
      if (offset > 0) {
        try {
          await for (final chunk in _fileChunks(partial.openRead())) {
            await hasher.add(chunk);
          }
        } catch (_) {
          hasher.dispose();
          rethrow;
        }
      }
      final item = existing ??
          TransferItem(
            id: id,
            name: finalFile.path.split(Platform.pathSeparator).last,
            size: size,
            outgoing: false,
            resumeKey: resumeKey,
            path: finalFile.path,
            relativePath: relativePath,
          );
      item.id = id;
      item.bytes = offset;
      item.state = TransferState.active;
      item.error = null;
      item.finished = null;
      if (existing == null) items.insert(0, item);
      final incoming = _Incoming(
        item,
        partial.openWrite(mode: FileMode.append),
        partial,
        hasher,
        resumable: resumable,
      );
      incoming.received = offset;
      _incoming[id] = incoming;
      _changed();
      await session.send(
        <String, dynamic>{'t': 'file-accept', 'id': id, 'n': offset},
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink transfer',
          context: ErrorDescription('while preparing a received file'),
        ),
      );
      await session.send(<String, dynamic>{'t': 'file-reject', 'id': id});
    }
  }

  void _onBinary(Uint8List data) {
    if (data.length < 4) return;
    final id = ByteData.sublistView(data).getUint32(0);
    final incoming = _incoming[id];
    if (incoming == null || incoming.stopped) return;
    final payload = Uint8List.sublistView(data, 4);
    final item = incoming.item;
    if (incoming.received + payload.length > item.size) {
      _incoming.remove(id);
      unawaited(
        _closeIncoming(
          incoming,
          TransferState.failed,
          'More data than announced',
        ),
      );
      final session = _session;
      if (session != null) {
        unawaited(
            session.send(<String, dynamic>{'t': 'file-cancel', 'id': id}));
      }
      return;
    }
    incoming.received += payload.length;
    incoming.writeChain = incoming.writeChain.then((_) async {
      if (incoming.stopped) return;
      final hashing = incoming.hasher.add(payload);
      incoming.sink.add(payload);
      await hashing;
      item.bytes += payload.length;
      incoming.sinceAck += payload.length;
      if (incoming.sinceAck >= _ackEvery || item.bytes == item.size) {
        await incoming.sink.flush();
        incoming.sinceAck = 0;
        final session = _session;
        if (session != null && !session.isClosed) {
          await session.send(<String, dynamic>{
            't': 'file-ack',
            'id': id,
            'n': item.bytes,
          });
        }
      }
      _changed();
    }).catchError((Object error, StackTrace stackTrace) {
      if (incoming.writeError != null) return;
      incoming.writeError = error;
      incoming.stopped = true;
      _incoming.remove(id);
      incoming.hasher.dispose();
      _finishItem(item, TransferState.failed, 'Could not save the file');
      final session = _session;
      if (session != null && !session.isClosed) {
        unawaited(
          session.send(<String, dynamic>{'t': 'file-cancel', 'id': id}),
        );
      }
      unawaited(() async {
        try {
          await incoming.sink.close();
          await incoming.file.delete();
        } catch (_) {
          // The partial file may already be gone.
        }
      }());
    });
  }

  Future<void> _onEnd(int id, Object? expectedHash) async {
    final incoming = _incoming[id];
    final session = _session;
    if (incoming == null || session == null) return;
    await incoming.writeChain;
    if (incoming.stopped || incoming.writeError != null) return;
    _incoming.remove(id);
    final item = incoming.item;
    try {
      await incoming.sink.flush();
      await incoming.sink.close();
    } catch (_) {
      incoming.hasher.dispose();
      _finishItem(item, TransferState.failed, 'Could not save the file');
      return;
    }
    if (item.bytes != item.size) {
      incoming.hasher.dispose();
      _finishItem(item, TransferState.failed, 'The file arrived incomplete');
      try {
        await incoming.file.delete();
      } catch (_) {
        // Leave it.
      }
      return;
    }
    if (expectedHash != null) {
      if (expectedHash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash)) {
        incoming.hasher.dispose();
        _finishItem(item, TransferState.failed,
            'The sender provided an invalid file checksum');
        await session.send(<String, dynamic>{'t': 'file-cancel', 'id': id});
        try {
          await incoming.file.delete();
        } catch (_) {
          // Leave the partial file if cleanup is denied.
        }
        return;
      }
      late final String actualHash;
      try {
        actualHash = await incoming.hasher.finish();
        incoming.hasher.dispose();
      } catch (_) {
        incoming.hasher.dispose();
        _finishItem(
            item, TransferState.failed, 'Could not verify the received file');
        await session.send(<String, dynamic>{'t': 'file-cancel', 'id': id});
        try {
          await incoming.file.delete();
        } catch (_) {
          // Leave the received file if cleanup is denied.
        }
        return;
      }
      if (actualHash != expectedHash) {
        _finishItem(item, TransferState.failed,
            'File verification failed; the received file is incomplete or damaged');
        await session.send(<String, dynamic>{'t': 'file-cancel', 'id': id});
        try {
          await incoming.file.delete();
        } catch (_) {
          // Leave the partial file if cleanup is denied.
        }
        return;
      }
    }
    incoming.hasher.dispose();
    try {
      final destination = File(item.path!);
      await destination.parent.create(recursive: true);
      if (await destination.exists()) {
        item.path = (await _uniqueFile(destination.parent,
                destination.path.split(Platform.pathSeparator).last))
            .path;
      }
      await incoming.file.rename(item.path!);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink transfer',
          context: ErrorDescription('while finalizing a received file'),
        ),
      );
      _finishItem(
          item, TransferState.failed, 'Could not finish saving the file');
      return;
    }
    _finishItem(item, TransferState.done, null);
    onActivity('Received ${item.name}', 'receive');
    final notifyReceived = onFileReceived;
    if (notifyReceived != null) unawaited(notifyReceived(item));
    await session.send(<String, dynamic>{'t': 'file-done', 'id': id});
  }

  Future<void> _closeIncoming(
    _Incoming incoming,
    TransferState state,
    String error,
  ) async {
    incoming.stopped = true;
    await incoming.writeChain;
    incoming.hasher.dispose();
    try {
      await incoming.sink.close();
      await incoming.file.delete();
    } catch (_) {
      // The partial file may already be gone.
    }
    _finishItem(incoming.item, state, error);
  }

  // ---- Files and names ----------------------------------------------------

  Future<Directory> _receiveDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final fixed = fixedReceiveDir;
    if (fixed != null) {
      await fixed.create(recursive: true);
      _dir = fixed;
      receiveFolder = fixed.path;
      return fixed;
    }
    Directory base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } else {
      base = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}Zephlink');
    await dir.create(recursive: true);
    _dir = dir;
    receiveFolder = dir.path;
    return dir;
  }

  /// The folder where received files go.
  Future<String> folderPath() {
    if (Platform.isAndroid) return Future<String>.value('Downloads/Zephlink');
    return _folderFuture ??= _receiveDir().then((dir) => dir.path);
  }

  Future<String>? _folderFuture;

  Future<File> _uniqueFile(Directory dir, String name) async {
    var file = File('${dir.path}${Platform.pathSeparator}$name');
    if (!await file.exists()) return file;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var n = 1; n < 1000; n++) {
      file = File('${dir.path}${Platform.pathSeparator}$base ($n)$ext');
      if (!await file.exists()) return file;
    }
    return File(
        '${dir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$name');
  }

  TransferItem? _findIncomingItem(String resumeKey) {
    for (final item in items) {
      if (!item.outgoing && item.resumeKey == resumeKey) return item;
    }
    return null;
  }

  Future<File> _partialFile(String resumeKey) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(resumeKey)) {
      throw const FormatException('Invalid transfer resume key');
    }
    final dir = Directory(
      '${(await _receiveDir()).path}${Platform.pathSeparator}.zephlink_partial',
    );
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$resumeKey.part');
  }

  static String _newResumeKey() => List<int>.generate(
        16,
        (_) => _secureRandom.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<File> _fileForRelativePath(Directory root, String relativePath) async {
    final segments = relativePath.split('/');
    final parent = Directory(
      <String>[
        root.path,
        ...segments.take(segments.length - 1),
      ].join(Platform.pathSeparator),
    );
    await parent.create(recursive: true);
    return _uniqueFile(parent, segments.last);
  }

  static final RegExp _badChars = RegExp(r'[<>:"/\\|?*\x00-\x1f]');
  static final RegExp _reserved =
      RegExp(r'^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$', caseSensitive: false);

  /// Makes a file name safe to save on Windows and Android.
  static String _safeName(String name) {
    var clean = name.replaceAll(_badChars, '_').trim();
    while (clean.endsWith('.')) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (clean.length > 120) clean = clean.substring(clean.length - 120);
    if (clean.isEmpty) clean = 'file';
    if (_reserved.hasMatch(clean)) clean = '_$clean';
    return clean;
  }

  static String? _safeRelativePath(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty || value.length > 1024) return null;
    final normalized = value.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(normalized)) {
      return null;
    }
    final segments = normalized.split('/');
    if (segments.any(
        (segment) => segment.isEmpty || segment == '.' || segment == '..')) {
      return null;
    }
    return segments.map(_safeName).join('/');
  }
}
