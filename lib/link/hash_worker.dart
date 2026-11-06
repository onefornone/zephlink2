import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Works out the SHA-256 checksum of a file as its pieces go by.
///
/// Big files are hashed in a second "thread" (an isolate) so the screen stays
/// smooth. Small files are hashed right away because starting a helper would
/// cost more than the hashing.
abstract class FileHasher {
  /// A hasher suited to a file of [size] bytes.
  static Future<FileHasher> create(int size) async {
    if (size < 512 * 1024) return _InlineHasher();
    try {
      return await _WorkerHasher.start();
    } catch (_) {
      return _InlineHasher();
    }
  }

  /// Adds the next piece. Completes when it has been taken into account, so
  /// waiting for it keeps memory use small.
  Future<void> add(List<int> data);

  /// The finished checksum as 64 hex characters.
  Future<String> finish();

  /// Frees the helper. Safe to call many times.
  void dispose();
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

class _InlineHasher implements FileHasher {
  final HashSink _sink = Sha256().toSync().newHashSink();

  @override
  Future<void> add(List<int> data) {
    _sink.add(data);
    return Future<void>.value();
  }

  @override
  Future<String> finish() async {
    _sink.close();
    final digest = await _sink.hash();
    return _hex(digest.bytes);
  }

  @override
  void dispose() {}
}

class _WorkerHasher implements FileHasher {
  _WorkerHasher._(this._isolate, this._commands, this._replies, this._exit);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final ReceivePort _exit;
  final Map<int, Completer<List<Object?>>> _pending = {};
  int _nextId = 0;
  bool _disposed = false;

  static Future<_WorkerHasher> start() async {
    final replies = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    _WorkerHasher? worker;

    replies.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is List<Object?>) {
        worker?._onReply(message);
      }
    });
    exit.listen((Object? _) => worker?._failAll('The checksum helper stopped'));

    try {
      final isolate = await Isolate.spawn<SendPort>(
        _hashMain,
        replies.sendPort,
        onExit: exit.sendPort,
      );
      final commands = await ready.future.timeout(const Duration(seconds: 10));
      worker = _WorkerHasher._(isolate, commands, replies, exit);
      return worker;
    } catch (_) {
      replies.close();
      exit.close();
      rethrow;
    }
  }

  void _onReply(List<Object?> reply) {
    final id = reply[0];
    if (id is! int) return;
    final waiter = _pending.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete(reply);
  }

  void _failAll(String why) {
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final waiter in waiting) {
      if (!waiter.isCompleted) waiter.completeError(StateError(why));
    }
  }

  Future<List<Object?>> _call(int op, Uint8List? data) {
    if (_disposed) return Future<List<Object?>>.error(StateError('Closed'));
    final id = _nextId++;
    final waiter = Completer<List<Object?>>();
    _pending[id] = waiter;
    _commands.send(<Object?>[
      id,
      op,
      data == null ? null : TransferableTypedData.fromList([data]),
    ]);
    return waiter.future;
  }

  @override
  Future<void> add(List<int> data) async {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final reply = await _call(0, bytes);
    if (reply[1] != true) throw StateError('${reply[2]}');
  }

  @override
  Future<String> finish() async {
    final reply = await _call(1, null);
    if (reply[1] != true) throw StateError('${reply[2]}');
    return reply[2]! as String;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failAll('Closed');
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    _exit.close();
  }
}

/// Runs inside the helper isolate.
Future<void> _hashMain(SendPort replyTo) async {
  final commands = ReceivePort();
  replyTo.send(commands.sendPort);
  final sink = Sha256().toSync().newHashSink();

  await for (final Object? raw in commands) {
    if (raw is! List<Object?>) {
      commands.close();
      break;
    }
    final id = raw[0]! as int;
    final op = raw[1]! as int;
    try {
      if (op == 0) {
        final data =
            (raw[2]! as TransferableTypedData).materialize().asUint8List();
        sink.add(data);
        replyTo.send(<Object?>[id, true, null]);
      } else {
        sink.close();
        final digest = await sink.hash();
        replyTo.send(<Object?>[id, true, _hex(digest.bytes)]);
      }
    } catch (error) {
      replyTo.send(<Object?>[id, false, error.toString()]);
    }
  }
}
