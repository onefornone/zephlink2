import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// One opened (decrypted) message.
class OpenedFrame {
  OpenedFrame(this.kind, this.payload);

  /// 1 = text message, 2 = raw bytes.
  final int kind;
  final Uint8List payload;
}

class _Lane {
  _Lane(this.isolate, this.commands, this.replies, this.exit);

  final Isolate isolate;
  final SendPort commands;
  final ReceivePort replies;
  final ReceivePort exit;
}

/// Does all the heavy encrypting and decrypting on other "threads" (isolates),
/// so the screen never freezes while a big file goes through. Two or three
/// helpers share the work, which makes big transfers faster on phones and PCs
/// with several processor cores.
///
/// The message numbers are handed out here, in the order messages are sent
/// and received, so the wire format is the same as with a single helper and
/// nothing about the link changes for the other device.
class CryptoWorker {
  CryptoWorker._(this._lanes);

  final List<_Lane> _lanes;
  final Map<int, Completer<List<Object?>>> _pending = {};
  int _nextId = 0;
  int _nextLane = 0;
  int _sendSeq = 0;
  int _recvSeq = 0;
  bool _disposed = false;

  /// How many helpers to use by default.
  static int get defaultLanes =>
      math.max(1, math.min(3, Platform.numberOfProcessors ~/ 2));

  static Future<CryptoWorker> start({
    required List<int> sendKey,
    required List<int> recvKey,
    required List<int> sendAad,
    required List<int> recvAad,
    int? lanes,
  }) async {
    final count = math.max(1, lanes ?? defaultLanes);
    final built = <_Lane>[];
    CryptoWorker? worker;
    try {
      for (var index = 0; index < count; index++) {
        final replies = ReceivePort();
        final exit = ReceivePort();
        final ready = Completer<SendPort>();
        replies.listen((Object? message) {
          if (message is SendPort) {
            if (!ready.isCompleted) ready.complete(message);
          } else if (message is List<Object?>) {
            worker?._onReply(message);
          }
        });
        exit.listen(
          (Object? _) => worker?._failAll('The encryption helper stopped'),
        );
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
          final commands =
              await ready.future.timeout(const Duration(seconds: 10));
          built.add(_Lane(isolate, commands, replies, exit));
        } catch (_) {
          replies.close();
          exit.close();
          rethrow;
        }
      }
      worker = CryptoWorker._(built);
      return worker;
    } catch (_) {
      for (final lane in built) {
        lane.isolate.kill(priority: Isolate.immediate);
        lane.replies.close();
        lane.exit.close();
      }
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

  Future<List<Object?>> _call(int op, int kind, int seq, List<int> data) {
    if (_disposed) return Future<List<Object?>>.error(StateError('Closed'));
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final id = _nextId++;
    final waiter = Completer<List<Object?>>();
    _pending[id] = waiter;
    final lane = _lanes[_nextLane];
    _nextLane = (_nextLane + 1) % _lanes.length;
    lane.commands.send(
      <Object?>[id, op, kind, TransferableTypedData.fromList([bytes]), seq],
    );
    return waiter.future;
  }

  /// Numbers, labels and seals one message. Gives back the bytes to send.
  /// The number is taken the moment this is called, so call it in the order
  /// the messages must be sent.
  Future<Uint8List> seal(int kind, List<int> payload) async {
    final seq = _sendSeq++;
    final reply = await _call(0, kind, seq, payload);
    if (reply[1] != true) throw StateError('${reply[2]}');
    return (reply[3]! as TransferableTypedData).materialize().asUint8List();
  }

  /// Opens one received message and checks its number. Call it in the order
  /// the messages arrive; several can be in progress at the same time.
  Future<OpenedFrame> open(List<int> frame) async {
    final expected = _recvSeq++;
    final reply = await _call(1, 0, expected, frame);
    if (reply[1] != true) throw StateError('${reply[2]}');
    if (reply[4] != expected) throw StateError('Message out of order');
    final kind = reply[2]! as int;
    final payload =
        (reply[3]! as TransferableTypedData).materialize().asUint8List();
    return OpenedFrame(kind, payload);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failAll('Closed');
    for (final lane in _lanes) {
      lane.isolate.kill(priority: Isolate.immediate);
      lane.replies.close();
      lane.exit.close();
    }
  }
}

/// Runs inside a helper isolate.
Future<void> _workerMain(List<Object?> setup) async {
  final replyTo = setup[0]! as SendPort;
  final sendKey = SecretKey(setup[1]! as Uint8List);
  final recvKey = SecretKey(setup[2]! as Uint8List);
  final sendAad = setup[3]! as Uint8List;
  final recvAad = setup[4]! as Uint8List;
  final cipher = Chacha20.poly1305Aead();

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
      final seq = raw[4]! as int;
      if (op == 0) {
        final kind = raw[2]! as int;
        final clear = Uint8List(9 + data.length);
        ByteData.sublistView(clear).setUint64(0, seq);
        clear[8] = kind;
        clear.setRange(9, clear.length, data);
        final box = await cipher.encrypt(clear, secretKey: sendKey, aad: sendAad);
        replyTo.send(<Object?>[
          id,
          true,
          0,
          TransferableTypedData.fromList([box.concatenation()]),
          seq,
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
        final number = ByteData.sublistView(clear).getUint64(0);
        replyTo.send(<Object?>[
          id,
          true,
          clear[8],
          TransferableTypedData.fromList([Uint8List.sublistView(clear, 9)]),
          number,
        ]);
      }
    } catch (error) {
      replyTo.send(<Object?>[id, false, error.toString(), null, -1]);
    }
  }
}
