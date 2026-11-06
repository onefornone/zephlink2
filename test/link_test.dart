import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:zephlink/features/transfer_hub.dart';
import 'package:zephlink/link/crypto_worker.dart';
import 'package:zephlink/link/hash_worker.dart';
import 'package:zephlink/link/identity.dart';
import 'package:zephlink/link/models.dart';
import 'package:zephlink/link/secure_session.dart';

/// A pretend device that listens for links, used to test the real handshake
/// over the computer's own loopback network.
class _Rig {
  _Rig(this.me, this.store);

  final Identity me;
  final PeerStore store;
  PairingWindow? window;
  bool Function()? allowApprove;
  final LinkServer server = LinkServer();
  final List<Completer<LinkResult>> results = [];

  Future<void> start() {
    return server.start((socket) async {
      final done = Completer<LinkResult>();
      done.future.then((_) {}, onError: (Object _) {});
      results.add(done);
      try {
        done.complete(
          await acceptPeer(
            ws: socket,
            me: me,
            myName: 'Test PC',
            store: store,
            pairing: () => window,
            allowApprove: allowApprove,
          ),
        );
      } catch (error) {
        done.completeError(error);
      }
    }, preferredPort: 0);
  }

  Future<LinkResult> get lastResult => results.last.future;
}

Future<LinkResult> _dial(
  Identity me,
  PeerStore store,
  _Rig rig,
  String mode, {
  String? pin,
}) {
  return dialPeer(
    me: me,
    myName: 'Test Phone',
    store: store,
    address: InternetAddress.loopbackIPv4,
    port: rig.server.port,
    mode: mode,
    pin: pin,
  );
}

void main() {
  late Identity phone;
  late Identity pc;
  late PeerStore phoneStore;
  late PeerStore pcStore;
  late _Rig rig;

  setUp(() async {
    phone = await Identity.generate();
    pc = await Identity.generate();
    phoneStore = PeerStore(null);
    pcStore = PeerStore(null);
    rig = _Rig(pc, pcStore);
    await rig.start();
    addTearDown(rig.server.stop);
  });

  test('pairing with the right code links both sides and they can talk',
      () async {
    rig.window = PairingWindow('123456');
    final client = await _dial(phone, phoneStore, rig, 'pair', pin: '123456');
    final server = await rig.lastResult;

    expect(client.newlyPaired, isTrue);
    expect(client.requiresApproval, isTrue);
    expect(client.peer.id, pc.id);
    expect(server.peer.id, phone.id);
    expect(server.requiresApproval, isTrue);
    expect(rig.window!.open, isFalse, reason: 'a code works only once');

    client.session.start();
    server.session.start();

    final heard = server.session.messages.first;
    await client.session.send(<String, dynamic>{'t': 'hello', 'x': 42});
    final message = await heard.timeout(const Duration(seconds: 5));
    expect(message['x'], 42);

    final rtt = await client.session.ping();
    expect(rtt.inSeconds, lessThan(4));

    client.session.close();
    server.session.close();
  });

  test('nearby pairing creates a matching approval code on both devices',
      () async {
    final client = await _dial(phone, phoneStore, rig, 'approve');
    final server = await rig.lastResult;

    expect(client.newlyPaired, isTrue);
    expect(server.newlyPaired, isTrue);
    expect(client.requiresApproval, isTrue);
    expect(server.requiresApproval, isTrue);
    expect(client.verificationCode, isNotNull);
    expect(client.verificationCode, hasLength(6));
    expect(client.verificationCode, server.verificationCode);

    client.session.close();
    server.session.close();
  });

  test('a nearby request is refused while the device is busy', () async {
    rig.allowApprove = () => false;
    await expectLater(
      _dial(phone, phoneStore, rig, 'approve'),
      throwsA(isA<HandshakeError>()),
    );
  });

  test('a link reports how long it has been quiet', () async {
    final client = await _dial(phone, phoneStore, rig, 'approve');
    final server = await rig.lastResult;
    client.session.start();
    server.session.start();
    await client.session.ping();
    expect(client.session.silence.inSeconds, lessThan(5));
    client.session.close();
    server.session.close();
  });

  test('the background encryption helper round-trips and keeps order',
      () async {
    final keyA = List<int>.generate(32, (i) => i);
    final keyB = List<int>.generate(32, (i) => 255 - i);
    final aad1 = utf8.encode('a-to-b');
    final aad2 = utf8.encode('b-to-a');
    final a = await CryptoWorker.start(
        sendKey: keyA, recvKey: keyB, sendAad: aad1, recvAad: aad2);
    final b = await CryptoWorker.start(
        sendKey: keyB, recvKey: keyA, sendAad: aad2, recvAad: aad1);
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    final first = await a.seal(1, utf8.encode('hello'));
    final second = await a.seal(2, [1, 2, 3, 4]);
    final one = await b.open(first);
    final two = await b.open(second);
    expect(one.kind, 1);
    expect(utf8.decode(one.payload), 'hello');
    expect(two.kind, 2);
    expect(two.payload, [1, 2, 3, 4]);

    // Replaying a message that was already accepted must fail.
    await expectLater(b.open(first), throwsA(isA<StateError>()));
  });

  test('the checksum helper matches a normal SHA-256', () async {
    final data = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024 + 11, (i) => (i * 7 + 3) & 255),
    );
    final hasher = await FileHasher.create(data.length);
    addTearDown(hasher.dispose);
    for (var at = 0; at < data.length; at += 1024 * 1024) {
      final end = at + 1024 * 1024 > data.length ? data.length : at + 1024 * 1024;
      await hasher.add(data.sublist(at, end));
    }
    final got = await hasher.finish();
    final want = (await Sha256().hash(data))
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(got, want);
  });

  test('a wrong code is refused and counted', () async {
    rig.window = PairingWindow('123456');
    await expectLater(
      _dial(phone, phoneStore, rig, 'pair', pin: '000000'),
      throwsA(isA<HandshakeError>()),
    );
    expect(rig.window!.failures, 1);
  });

  test('three wrong codes close the pairing window', () async {
    rig.window = PairingWindow('123456');
    for (var i = 0; i < 3; i++) {
      await expectLater(
        _dial(phone, phoneStore, rig, 'pair', pin: '00000$i'),
        throwsA(isA<HandshakeError>()),
      );
    }
    expect(rig.window!.open, isFalse);
    await expectLater(
      _dial(phone, phoneStore, rig, 'pair', pin: '123456'),
      throwsA(isA<HandshakeError>()),
    );
  });

  test('pairing is refused when no code is showing', () async {
    rig.window = null;
    await expectLater(
      _dial(phone, phoneStore, rig, 'pair', pin: '123456'),
      throwsA(isA<HandshakeError>()),
    );
  });

  test('trusted reconnects do not ask for approval again', () async {
    rig.window = PairingWindow('654321');
    final first = await _dial(phone, phoneStore, rig, 'pair', pin: '654321');
    final firstServer = await rig.lastResult;
    await phoneStore.put(first.peer);
    await pcStore.put(firstServer.peer);
    first.session.close();
    firstServer.session.close();

    final second = await _dial(phone, phoneStore, rig, 'link');
    final secondServer = await rig.lastResult;
    expect(second.newlyPaired, isFalse);
    expect(second.requiresApproval, isFalse);
    expect(secondServer.requiresApproval, isFalse);
    expect(second.peer.id, pc.id);
    expect(secondServer.peer.id, phone.id);
    second.session.close();
    secondServer.session.close();
  });

  test('an unpaired device cannot use link mode', () async {
    await expectLater(
      _dial(phone, phoneStore, rig, 'link'),
      throwsA(isA<HandshakeError>()),
    );
  });

  test('a device with a different key cannot pose as a paired one', () async {
    final stranger = await Identity.generate();
    // The PC knows the phone's id but pinned a different public key for it.
    await pcStore.put(
      PairedPeer(
        id: stranger.id,
        name: 'Stranger',
        platform: 'android',
        publicKey: phone.publicKey,
      ),
    );
    await expectLater(
      _dial(stranger, PeerStore(null), rig, 'link'),
      throwsA(isA<HandshakeError>()),
    );
  });

  test('the info address lets other devices recognise us', () async {
    final server = LinkServer();
    await server.start(
      (socket) => socket.close(),
      preferredPort: 0,
      info: () => jsonEncode({
        'z': 1,
        'id': pc.id,
        'name': 'Test PC',
        'plat': 'windows',
        'port': 1
      }),
    );
    addTearDown(server.stop);
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}$linkPath/info'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    expect((jsonDecode(body) as Map<String, dynamic>)['id'], pc.id);
  });

  test('a file arrives complete and identical', () async {
    rig.window = PairingWindow('111222');
    final client = await _dial(phone, phoneStore, rig, 'pair', pin: '111222');
    final server = await rig.lastResult;

    final temp = await Directory.systemTemp.createTemp('zephlink_test');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/photo.bin');
    final data = Uint8List.fromList(
      List<int>.generate(12 * 1024 * 1024 + 123, (i) => (i * 31 + 7) & 255),
    );
    await source.writeAsBytes(data);

    final sender = TransferHub(
      onChanged: () {},
      onActivity: (_, __) {},
      autoReceive: () => true,
    );
    var notifiedFile = '';
    final receiver = TransferHub(
      onChanged: () {},
      onActivity: (_, __) {},
      autoReceive: () => true,
      onFileReceived: (item) async {
        notifiedFile = item.name;
      },
      fixedReceiveDir: Directory('${temp.path}/inbox'),
    );
    sender.attach(client.session);
    receiver.attach(server.session);
    client.session.start();
    server.session.start();

    await sender.sendSources([
      TransferSource(
        file: XFile(source.path),
        relativePath: 'sample-folder/photos/photo.bin',
      ),
    ]);
    final watch = Stopwatch()..start();
    while (sender.items.isEmpty ||
        sender.items.first.running ||
        receiver.items.isEmpty ||
        receiver.items.first.running) {
      expect(watch.elapsed.inSeconds, lessThan(60),
          reason: 'transfer too slow');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(sender.items.first.state, TransferState.done);
    expect(receiver.items.first.state, TransferState.done);
    expect(
      receiver.items.first.path,
      endsWith(
        '${Platform.pathSeparator}sample-folder'
        '${Platform.pathSeparator}photos'
        '${Platform.pathSeparator}photo.bin',
      ),
    );
    expect(notifiedFile, endsWith('photo.bin'));
    expect(sender.items.first.path, source.path);
    final saved = await File(receiver.items.first.path!).readAsBytes();
    expect(saved.length, data.length);
    expect(saved, data);

    sender.detach();
    receiver.detach();
    client.session.close();
    server.session.close();
  });

  test('a transfer resumes from the receiver partial file after reconnect',
      () async {
    rig.window = PairingWindow('333444');
    final firstClient =
        await _dial(phone, phoneStore, rig, 'pair', pin: '333444');
    final firstServer = await rig.lastResult;
    await phoneStore.put(firstClient.peer);
    await pcStore.put(firstServer.peer);

    final temp = await Directory.systemTemp.createTemp('zephlink_resume_test');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/large.bin');
    final data = Uint8List.fromList(
      List<int>.generate(32 * 1024 * 1024 + 57, (i) => (i * 13 + 19) & 255),
    );
    await source.writeAsBytes(data);

    final sender = TransferHub(
      onChanged: () {},
      onActivity: (_, __) {},
      autoReceive: () => true,
    );
    final receiver = TransferHub(
      onChanged: () {},
      onActivity: (_, __) {},
      autoReceive: () => true,
      fixedReceiveDir: Directory('${temp.path}/inbox'),
    );
    sender.attach(firstClient.session);
    receiver.attach(firstServer.session);
    firstClient.session.start();
    firstServer.session.start();

    final firstAck = firstClient.session.messages.firstWhere(
      (message) => message['t'] == 'file-ack',
    );
    await sender.sendFiles([XFile(source.path)]);
    await firstAck.timeout(const Duration(seconds: 30));
    firstClient.session.close();
    firstServer.session.close();
    sender.detach();
    receiver.detach();

    final pauseWatch = Stopwatch()..start();
    while (sender.items.first.state != TransferState.paused ||
        receiver.items.first.state != TransferState.paused) {
      expect(pauseWatch.elapsed.inSeconds, lessThan(15));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(receiver.items.single.bytes, greaterThan(0));
    expect(receiver.items.single.bytes, lessThan(data.length));

    final nextClient = await _dial(phone, phoneStore, rig, 'link');
    final nextServer = await rig.lastResult;
    sender.attach(nextClient.session);
    receiver.attach(nextServer.session);
    nextClient.session.start();
    nextServer.session.start();
    await sender.resume(sender.items.single);

    final resumeWatch = Stopwatch()..start();
    while (sender.items.single.running || receiver.items.single.running) {
      expect(resumeWatch.elapsed.inSeconds, lessThan(60));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(sender.items.single.state, TransferState.done);
    expect(receiver.items.single.state, TransferState.done);
    expect(await File(receiver.items.single.path!).readAsBytes(), data);

    sender.detach();
    receiver.detach();
    nextClient.session.close();
    nextServer.session.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
