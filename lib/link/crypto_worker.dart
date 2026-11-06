import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// One opened (decrypted) message.
class OpenedFrame {
  OpenedFrame(this.kind, this.payload);

  /// 1 = text message, 2 = raw bytes.
  final int kind;
  final Uint8List payload;
}

/// Does all the heavy encrypting and decrypting on a second "thread" (an
/// isolate), so the screen never freezes while a big file goes through.
///
/// Each link gets its own worker. The worker keeps the message counters, so
/// messages are numbered and checked in exactly the order they arrive.
class CryptoWorker {
  CryptoWorker._(this._isolate, this._commands, this._replies, this._exit);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final ReceivePort _exit;
  final Map<int, Completer<List<Object?>>> _pending = {};
  int _nextId = 0;
  bool _disposed = false;

  static Future<CryptoWorker> start({
    required List<int> sendKey,
    required List<int> recvKey,
    required List<int> sendAad,
    required List<int> recvAad,
  }) async {
    final replies = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    CryptoWorker? worker;

    replies.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is List<Object?>) {
        worker?._onReply(message);
      }
    });
    exit.listen((Object? _) => worker?._failAll('The encryption helper stopped'));

    try {
      final isolate = await Isolate.spawn<List<Object?>>(
        _workerMain,
        <Object?>[
          replies.sendPort,
          Uint8List.fromList(sendKey),
          Uint8List.fromList(recvKey),
          Uint8List.fromList(sendAad),
          Uint8List.fromList(recvAad),
        ],
        onExit: exit.sendPort,
      );
      final commands = await ready.future.timeout(const Duration(seconds: 10));
      worker = CryptoWorker._(isolate, commands, replies, exit);
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

  Future<List<Object?>> _call(int op, int kind, List<int> data) {
    if (_disposed) return Future<List<Object?>>.error(StateError('Closed'));
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final id = _nextId++;
    final waiter = Completer<List<Object?>>();
    _pending[id] = waiter;
    _commands.send(<Object?>[id, op, kind, TransferableTypedData.fromList([bytes])]);
    return waiter.future;
  }

  /// Numbers, labels and seals one message. Gives back the bytes to send.
  Future<Uint8List> seal(int kind, List<int> payload) async {
    final reply = await _call(0, kind, payload);
    if (reply[1] != true) throw StateError('${reply[2]}');
    return (reply[3]! as TransferableTypedData).materialize().asUint8List();
  }

  /// Opens one received message and checks its number.
  Future<OpenedFrame> open(List<int> frame) async {
    final reply = await _call(1, 0, frame);
    if (reply[1] != true) throw StateError('${reply[2]}');
    final kind = reply[2]! as int;
    final payload =
        (reply[3]! as TransferableTypedData).materialize().asUint8List();
    return OpenedFrame(kind, payload);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failAll('Closed');
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    _exit.close();
  }
}

/// Runs inside the worker isolate.
Future<void> _workerMain(List<Object?> setup) async {
  final replyTo = setup[0]! as SendPort;
  final sendKey = SecretKey(setup[1]! as Uint8List);
  final recvKey = SecretKey(setup[2]! as Uint8List);
  final sendAad = setup[3]! as Uint8List;
  final recvAad = setup[4]! as Uint8List;
  final cipher = Chacha20.poly1305Aead();
  var sendSeq = 0;
  var recvSeq = 0;

  final commands = ReceivePort();
  replyTo.send(commands.sendPort);

  // `await for` handles one request at a time, in the order they were sent.
  await for (final Object? raw in commands) {
    if (raw is! List<Object?>) {
      commands.close();
      break;
    }
    final id = raw[0]! as int;
    final op = raw[1]! as int;
    try {
      final data = (raw[3]! as TransferableTypedData).materialize().asUint8List();
      if (op == 0) {
        final kind = raw[2]! as int;
        final clear = Uint8List(9 + data.length);
        ByteData.sublistView(clear).setUint64(0, sendSeq++);
        clear[8] = kind;
        clear.setRange(9, clear.length, data);
        final box = await cipher.encrypt(clear, secretKey: sendKey, aad: sendAad);
        replyTo.send(<Object?>[
          id,
          true,
          0,
          TransferableTypedData.fromList([box.concatenation()]),
        ]);
      } else {
        final box = SecretBox.fromConcatenation(
          data,
          nonceLength: 12,
          macLength: 16,
        );
        final opened = await cipher.decrypt(box, secretKey: recvKey, aad: recvAad);
        final clear = opened is Uint8List ? opened : Uint8List.fromList(opened);
        if (clear.length < 9) throw const FormatException('Short message');
        if (ByteData.sublistView(clear).getUint64(0) != recvSeq) {
          throw const FormatException('Message out of order');
        }
        recvSeq++;
        replyTo.send(<Object?>[
          id,
          true,
          clear[8],
          TransferableTypedData.fromList([Uint8List.sublistView(clear, 9)]),
        ]);
      }
    } catch (error) {
      replyTo.send(<Object?>[id, false, error.toString(), null]);
    }
  }
}
