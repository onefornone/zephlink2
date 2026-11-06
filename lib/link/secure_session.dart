import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_util.dart';
import 'crypto_worker.dart';
import 'identity.dart';
import 'models.dart';

/// Web address path and the port we try first.
const String linkPath = '/zephlink';
const int defaultLinkPort = 47475;

/// A problem with a message the person can understand.
class HandshakeError implements Exception {
  const HandshakeError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a finished handshake gives back.
class LinkResult {
  LinkResult({
    required this.session,
    required this.peer,
    required this.newlyPaired,
    required this.requiresApproval,
    this.verificationCode,
  });

  final SecureSession session;
  final PairedPeer peer;
  final bool newlyPaired;
  final bool requiresApproval;
  final String? verificationCode;
}

// ---------------------------------------------------------------------------
// Reading messages one at a time during the handshake
// ---------------------------------------------------------------------------

/// Listens to a socket once. During the handshake we ask for the next
/// message; afterwards the session takes over with [attach].
class Inbox {
  Inbox(Stream<dynamic> stream) {
    stream.listen(
      _onData,
      onDone: _onDone,
      onError: (Object _) => _onDone(),
      cancelOnError: true,
    );
  }

  final List<dynamic> _queue = [];
  Completer<dynamic>? _waiter;
  void Function(dynamic)? _handler;
  void Function()? _onClosed;
  bool closed = false;

  void _onData(dynamic data) {
    final handler = _handler;
    if (handler != null) {
      handler(data);
      return;
    }
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.complete(data);
    } else {
      _queue.add(data);
    }
  }

  void _onDone() {
    closed = true;
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(const SocketException('Connection closed'));
    }
    _onClosed?.call();
  }

  Future<dynamic> next({Duration timeout = const Duration(seconds: 10)}) {
    if (_queue.isNotEmpty) return Future<dynamic>.value(_queue.removeAt(0));
    if (closed) {
      return Future<dynamic>.error(const SocketException('Connection closed'));
    }
    final waiter = Completer<dynamic>();
    _waiter = waiter;
    return waiter.future.timeout(timeout);
  }

  void attach({
    required void Function(dynamic) onData,
    required void Function() onClosed,
  }) {
    _handler = onData;
    _onClosed = onClosed;
    final waiting = List<dynamic>.of(_queue);
    _queue.clear();
    waiting.forEach(onData);
    if (closed) onClosed();
  }
}

// ---------------------------------------------------------------------------
// The encrypted connection
// ---------------------------------------------------------------------------

/// An encrypted, numbered, two-way message channel to one other device.
/// Every message is sealed with ChaCha20-Poly1305. Someone on the same
/// Wi-Fi sees only noise and cannot change or replay messages.
class SecureSession {
  SecureSession({
    required WebSocket ws,
    required Inbox inbox,
    required CryptoWorker worker,
    required this.peerId,
    required this.initiatorId,
  })  : _ws = ws,
        _inbox = inbox,
        _worker = worker;

  /// Id of the device on the other end.
  final String peerId;

  /// Id of the device that opened the connection.
  final String initiatorId;

  final WebSocket _ws;
  final Inbox _inbox;
  final CryptoWorker _worker;

  int _pingId = 0;
  DateTime _lastHeard = DateTime.now();
  bool _closed = false;
  Future<void> _sendChain = Future<void>.value();
  Future<void> _recvChain = Future<void>.value();
  final Map<int, Completer<void>> _pongs = {};
  final Completer<void> _closedCompleter = Completer<void>();
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();

  /// True when the other side said goodbye on purpose.
  bool byeReceived = false;

  bool _started = false;
  final StreamController<Uint8List> _binary =
      StreamController<Uint8List>.broadcast();

  /// Messages from the other device (pings are handled for you).
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Raw data chunks from the other device (used for file transfer).
  Stream<Uint8List> get binary => _binary.stream;

  /// Completes when the connection ends for any reason.
  Future<void> get closed => _closedCompleter.future;

  bool get isClosed => _closed;

  /// How long since anything at all arrived from the other device.
  Duration get silence => DateTime.now().difference(_lastHeard);

  /// Starts reading. Subscribe to [messages] and [binary] first, then call
  /// this. Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;
    _inbox.attach(
      onData: (data) {
        _lastHeard = DateTime.now();
        _recvChain = _recvChain.then((_) => _receive(data));
      },
      onClosed: _finish,
    );
  }

  /// Sends one message. Never throws; a broken connection just closes.
  Future<void> send(Map<String, dynamic> message) =>
      _enqueue(1, utf8.encode(jsonEncode(message)));

  /// Sends raw bytes (a file chunk).
  Future<void> sendBytes(List<int> data) => _enqueue(2, data);

  Future<void> _enqueue(int kind, List<int> payload) {
    _sendChain = _sendChain.then((_) => _sendNow(kind, payload));
    return _sendChain;
  }

  /// Every sealed frame holds: 8 bytes message number, 1 byte kind
  /// (1 = text message, 2 = raw bytes), then the content. Sealing is done by
  /// the worker, away from the screen, so big files never freeze the app.
  Future<void> _sendNow(int kind, List<int> payload) async {
    if (_closed) return;
    try {
      final frame = await _worker.seal(kind, payload);
      if (_closed) return;
      _ws.add(frame);
    } catch (_) {
      close();
    }
  }

  Future<void> _receive(dynamic data) async {
    if (_closed) return;
    try {
      if (data is! List<int>) throw const FormatException('Unexpected text');
      final opened = await _worker.open(data);
      if (_closed) return;
      if (opened.kind == 1) {
        final decoded = jsonDecode(utf8.decode(opened.payload));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Bad message');
        }
        _dispatch(decoded);
      } else if (opened.kind == 2) {
        if (!_binary.isClosed) _binary.add(opened.payload);
      } else {
        throw const FormatException('Unknown message kind');
      }
    } catch (_) {
      // Anything that fails to decrypt or is out of order ends the link.
      close();
    }
  }

  void _dispatch(Map<String, dynamic> message) {
    final type = message['t'];
    if (type == 'ping') {
      send(<String, dynamic>{'t': 'pong', 'n': message['n']});
    } else if (type == 'pong') {
      _pongs.remove(message['n'])?.complete();
    } else if (type == 'bye') {
      byeReceived = true;
      close();
    } else if (!_messages.isClosed) {
      _messages.add(message);
    }
  }

  /// Round-trip time to the other device. Throws if it does not answer.
  Future<Duration> ping() async {
    final id = _pingId++;
    final waiter = Completer<void>();
    _pongs[id] = waiter;
    final watch = Stopwatch()..start();
    await send(<String, dynamic>{'t': 'ping', 'n': id});
    try {
      await waiter.future.timeout(const Duration(seconds: 8));
    } finally {
      _pongs.remove(id);
    }
    return watch.elapsed;
  }

  void close() {
    if (_closed) return;
    unawaited(_closeSocket());
    _finish();
  }

  Future<void> _closeSocket() async {
    try {
      await _ws.close();
    } catch (_) {
      // Already closed.
    }
  }

  void _finish() {
    _closed = true;
    _worker.dispose();
    if (!_messages.isClosed) unawaited(_messages.close());
    if (!_binary.isClosed) unawaited(_binary.close());
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
  }
}

// ---------------------------------------------------------------------------
// The handshake
// ---------------------------------------------------------------------------

/// The first message each side sends.
class _Hello {
  _Hello({
    required this.id,
    required this.name,
    required this.platform,
    required this.idPub,
    required this.eph,
    required this.nonce,
    required this.mode,
  });

  final String id;
  final String name;
  final String platform;
  final List<int> idPub;
  final List<int> eph;
  final List<int> nonce;

  /// "pair" (typed code), "approve" (nearby), or "link" (trusted device).
  final String mode;

  Map<String, dynamic> toJson() => {
        'v': 1,
        't': 'hello',
        'id': id,
        'name': name,
        'plat': platform,
        'idpub': b64(idPub),
        'eph': b64(eph),
        'nonce': b64(nonce),
        'mode': mode,
      };

  static _Hello parse(dynamic frame) {
    if (frame is! String) {
      throw const HandshakeError('The other device sent something unexpected.');
    }
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, dynamic>) {
        throw const HandshakeError(
            'The other device sent something unexpected.');
      }
      if (decoded['t'] == 'error') {
        throw HandshakeError(
          decoded['msg']?.toString() ?? 'The other device refused the link.',
        );
      }
      if (decoded['t'] != 'hello' || decoded['v'] != 1) {
        throw const HandshakeError(
          'The other device uses an incompatible Zephlink connection protocol.',
        );
      }
      final id = decoded['id'];
      final name = decoded['name'];
      final mode = decoded['mode'];
      if (id is! String ||
          id.length != 16 ||
          name is! String ||
          mode is! String) {
        throw const HandshakeError(
            'The other device sent something unexpected.');
      }
      final idPub = unb64(decoded['idpub']);
      final eph = unb64(decoded['eph']);
      final nonce = unb64(decoded['nonce']);
      if (idPub.length != 32 || eph.length != 32 || nonce.length != 16) {
        throw const HandshakeError(
            'The other device sent something unexpected.');
      }
      return _Hello(
        id: id,
        name: name.length > 60 ? name.substring(0, 60) : name,
        platform: (decoded['plat'] as String?) ?? 'other',
        idPub: idPub,
        eph: eph,
        nonce: nonce,
        mode: mode,
      );
    } on FormatException {
      throw const HandshakeError('The other device sent something unexpected.');
    }
  }
}

List<int> _parseAuth(dynamic frame) {
  if (frame is! String) {
    throw const HandshakeError('The other device sent something unexpected.');
  }
  try {
    final decoded = jsonDecode(frame);
    if (decoded is! Map<String, dynamic>) {
      throw const HandshakeError('The other device sent something unexpected.');
    }
    if (decoded['t'] == 'error') {
      throw HandshakeError(
        decoded['msg']?.toString() ?? 'The other device refused the link.',
      );
    }
    if (decoded['t'] != 'auth') {
      throw const HandshakeError('The other device sent something unexpected.');
    }
    return unb64(decoded['proof']);
  } on FormatException {
    throw const HandshakeError('The other device sent something unexpected.');
  }
}

/// A fingerprint of everything both sides said. Both compute the same one.
Future<List<int>> _transcript(_Hello client, _Hello server) async {
  final data = <int>[
    ...utf8.encode('zephlink-v1'),
    ...utf8.encode(client.id),
    ...client.idPub,
    ...client.eph,
    ...client.nonce,
    ...utf8.encode(server.id),
    ...server.idPub,
    ...server.eph,
    ...server.nonce,
  ];
  final hash = await Sha256().hash(data);
  return hash.bytes;
}

String _verificationCode(List<int> transcript) {
  var value = 0;
  for (final byte in transcript.take(4)) {
    value = (value << 8) | byte;
  }
  return (value % 1000000).toString().padLeft(6, '0');
}

/// The typed-code flow proves possession of the shared code. Nearby pairing
/// and trusted reconnects sign the transcript with the device identity key.
Future<List<int>> _makeProof({
  required String mode,
  required String label,
  required List<int> transcript,
  required Identity me,
  String? pin,
}) async {
  final data = <int>[...utf8.encode(label), ...transcript];
  if (mode == 'pair') {
    final mac = await Hmac.sha256().calculateMac(
      data,
      secretKey: SecretKey(utf8.encode('zephlink-pair:$pin')),
    );
    return mac.bytes;
  }
  final signature = await Ed25519().sign(data, keyPair: me.keyPair);
  return signature.bytes;
}

Future<bool> _checkProof({
  required String mode,
  required String label,
  required List<int> transcript,
  required List<int> proof,
  required List<int> peerIdPub,
  String? pin,
}) async {
  final data = <int>[...utf8.encode(label), ...transcript];
  if (mode == 'pair') {
    final mac = await Hmac.sha256().calculateMac(
      data,
      secretKey: SecretKey(utf8.encode('zephlink-pair:$pin')),
    );
    return constantTimeEquals(mac.bytes, proof);
  }
  return Ed25519().verify(
    data,
    signature: Signature(
      proof,
      publicKey: SimplePublicKey(peerIdPub, type: KeyPairType.ed25519),
    ),
  );
}

void _requirePinned(PeerStore store, _Hello hello) {
  final pinned = store.byId(hello.id);
  if (pinned == null || !constantTimeEquals(pinned.publicKey, hello.idPub)) {
    throw const HandshakeError(
      'These devices are not paired. Pair them again from the Devices screen.',
    );
  }
}

Future<LinkResult> _buildResult({
  required WebSocket ws,
  required Inbox inbox,
  required SimpleKeyPair eph,
  required _Hello client,
  required _Hello server,
  required List<int> transcript,
  required bool isClient,
  required bool newlyPaired,
  required bool requiresApproval,
  required String? verificationCode,
}) async {
  final peer = isClient ? server : client;
  final secret = await X25519().sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(peer.eph, type: KeyPairType.x25519),
  );
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final clientToServer = await hkdf.deriveKey(
    secretKey: secret,
    nonce: transcript,
    info: utf8.encode('c2s'),
  );
  final serverToClient = await hkdf.deriveKey(
    secretKey: secret,
    nonce: transcript,
    info: utf8.encode('s2c'),
  );
  final worker = await CryptoWorker.start(
    sendKey: await (isClient ? clientToServer : serverToClient).extractBytes(),
    recvKey: await (isClient ? serverToClient : clientToServer).extractBytes(),
    sendAad: utf8.encode(isClient ? 'c2s' : 's2c'),
    recvAad: utf8.encode(isClient ? 's2c' : 'c2s'),
  );
  final session = SecureSession(
    ws: ws,
    inbox: inbox,
    worker: worker,
    peerId: peer.id,
    initiatorId: client.id,
  );
  return LinkResult(
    session: session,
    peer: PairedPeer(
      id: peer.id,
      name: peer.name,
      platform: peer.platform,
      publicKey: peer.idPub,
    ),
    newlyPaired: newlyPaired,
    requiresApproval: requiresApproval,
    verificationCode: verificationCode,
  );
}

/// A new pairing requires visible approval on both devices. A trusted link
/// proves the peer's pinned identity and reconnects without asking again.
Future<LinkResult> dialPeer({
  required Identity me,
  required String myName,
  required PeerStore store,
  required InternetAddress address,
  required int port,
  required String mode,
  String? pin,
}) async {
  WebSocket? ws;
  try {
    ws = await WebSocket.connect('ws://${address.address}:$port$linkPath')
        .timeout(const Duration(seconds: 5));
    ws.pingInterval = const Duration(seconds: 20);
    final inbox = Inbox(ws);

    final eph = await X25519().newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;
    final client = _Hello(
      id: me.id,
      name: myName,
      platform: platformName,
      idPub: me.publicKey,
      eph: ephPub,
      nonce: randomBytes(16),
      mode: mode,
    );
    final helloText = jsonEncode(client.toJson());
    final _Hello server;
    if (mode == 'approve') {
      // Commit to our values first and reveal them only after the other
      // device has answered. Nobody in the middle can then pick values that
      // make both check codes come out the same.
      final commit = await Sha256().hash(utf8.encode(helloText));
      ws.add(jsonEncode({'t': 'commit', 'v': 1, 'h': b64(commit.bytes)}));
      server = _Hello.parse(await inbox.next());
      if (server.mode != 'approve') {
        throw const HandshakeError('The other device sent something unexpected.');
      }
      ws.add(helloText);
    } else {
      ws.add(helloText);
      server = _Hello.parse(await inbox.next());
    }
    if (mode == 'link') _requirePinned(store, server);
    final transcript = await _transcript(client, server);

    final myProof = await _makeProof(
      mode: mode,
      label: 'C',
      transcript: transcript,
      me: me,
      pin: pin,
    );
    ws.add(jsonEncode({'t': 'auth', 'proof': b64(myProof)}));

    final theirProof = _parseAuth(await inbox.next());
    final ok = await _checkProof(
      mode: mode,
      label: 'S',
      transcript: transcript,
      proof: theirProof,
      peerIdPub: server.idPub,
      pin: pin,
    );
    if (!ok) {
      throw HandshakeError(
        mode == 'pair'
            ? 'The code did not match.'
            : 'Could not verify the other device.',
      );
    }
    return await _buildResult(
      ws: ws,
      inbox: inbox,
      eph: eph,
      client: client,
      server: server,
      transcript: transcript,
      isClient: true,
      newlyPaired: mode != 'link',
      requiresApproval: mode != 'link',
      verificationCode: _verificationCode(transcript),
    );
  } catch (_) {
    try {
      await ws?.close();
    } catch (_) {
      // Already closed.
    }
    rethrow;
  }
}

/// Returns the commitment when the first message asks to connect by
/// approval ("approve" mode), or null for any other first message.
List<int>? _parseCommit(dynamic frame) {
  if (frame is! String) return null;
  try {
    final decoded = jsonDecode(frame);
    if (decoded is Map<String, dynamic> &&
        decoded['t'] == 'commit' &&
        decoded['v'] == 1) {
      final hash = unb64(decoded['h']);
      return hash.length == 32 ? hash : null;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// Handles another device connecting to us. [allowApprove] says whether we
/// are ready for a "connect by approval" request right now (one at a time).
Future<LinkResult> acceptPeer({
  required WebSocket ws,
  required Identity me,
  required String myName,
  required PeerStore store,
  required PairingWindow? Function() pairing,
  bool Function()? allowApprove,
}) async {
  ws.pingInterval = const Duration(seconds: 20);
  final inbox = Inbox(ws);
  try {
    final first = await inbox.next(timeout: const Duration(seconds: 8));
    final commit = _parseCommit(first);
    final eph = await X25519().newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;

    final String mode;
    final _Hello client;
    final _Hello server;
    PairingWindow? window;

    if (commit != null) {
      if (allowApprove != null && !allowApprove()) {
        throw const HandshakeError(
          'That device is busy with another request. Try again in a moment.',
        );
      }
      mode = 'approve';
      server = _Hello(
        id: me.id,
        name: myName,
        platform: platformName,
        idPub: me.publicKey,
        eph: ephPub,
        nonce: randomBytes(16),
        mode: mode,
      );
      ws.add(jsonEncode(server.toJson()));
      final reveal = await inbox.next(timeout: const Duration(seconds: 8));
      if (reveal is! String) {
        throw const HandshakeError('The other device sent something unexpected.');
      }
      final digest = await Sha256().hash(utf8.encode(reveal));
      if (!constantTimeEquals(digest.bytes, commit)) {
        throw const HandshakeError('The other device sent something unexpected.');
      }
      client = _Hello.parse(reveal);
      if (client.mode != 'approve') {
        throw const HandshakeError('The other device sent something unexpected.');
      }
    } else {
      client = _Hello.parse(first);
      mode = client.mode;
      if (mode == 'pair') {
        window = pairing();
        if (window == null || !window.open) {
          throw const HandshakeError(
            'Pairing is not open on that device. Tap "Show a code" there first.',
          );
        }
      } else if (mode == 'link') {
        _requirePinned(store, client);
      } else if (mode == 'approve') {
        throw const HandshakeError(
          'Update Zephlink on both devices to the same version, then try again.',
        );
      } else {
        throw const HandshakeError('The other device sent something unexpected.');
      }
      server = _Hello(
        id: me.id,
        name: myName,
        platform: platformName,
        idPub: me.publicKey,
        eph: ephPub,
        nonce: randomBytes(16),
        mode: mode,
      );
      ws.add(jsonEncode(server.toJson()));
    }
    final transcript = await _transcript(client, server);

    final theirProof = _parseAuth(
      await inbox.next(timeout: const Duration(seconds: 8)),
    );
    final ok = await _checkProof(
      mode: mode,
      label: 'C',
      transcript: transcript,
      proof: theirProof,
      peerIdPub: client.idPub,
      pin: window?.pin,
    );
    if (!ok) {
      if (window != null) window.failures++;
      throw HandshakeError(
        mode == 'pair'
            ? 'The code did not match.'
            : 'Could not verify the other device.',
      );
    }
    if (window != null) window.used = true;

    final myProof = await _makeProof(
      mode: mode,
      label: 'S',
      transcript: transcript,
      me: me,
      pin: window?.pin,
    );
    ws.add(jsonEncode({'t': 'auth', 'proof': b64(myProof)}));

    return await _buildResult(
      ws: ws,
      inbox: inbox,
      eph: eph,
      client: client,
      server: server,
      transcript: transcript,
      isClient: false,
      newlyPaired: mode != 'link',
      requiresApproval: mode != 'link',
      verificationCode: _verificationCode(transcript),
    );
  } catch (error) {
    try {
      if (error is HandshakeError) {
        ws.add(jsonEncode({'t': 'error', 'msg': error.message}));
      }
      await ws.close();
    } catch (_) {
      // Already closed.
    }
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// The listening side
// ---------------------------------------------------------------------------

/// A small web server that only accepts WebSocket links at /zephlink.
class LinkServer {
  HttpServer? _http;

  /// The port actually in use (0 if the server could not start).
  int port = 0;

  /// [info] returns a small piece of JSON describing this device. Other
  /// devices read it to find us when they scan the Wi-Fi.
  Future<void> start(
    void Function(WebSocket socket) onSocket, {
    int preferredPort = defaultLinkPort,
    String Function()? info,
  }) async {
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    final http = _http!;
    port = http.port;
    http.listen(
      (request) async {
        try {
          if (request.uri.path == linkPath &&
              WebSocketTransformer.isUpgradeRequest(request)) {
            final socket = await WebSocketTransformer.upgrade(request);
            onSocket(socket);
          } else if (info != null &&
              request.method == 'GET' &&
              request.uri.path == '$linkPath/info') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(info());
            await request.response.close();
          } else {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
          }
        } catch (_) {
          // A broken request must never stop the server.
        }
      },
      onError: (Object _) {},
    );
  }

  Future<void> stop() async {
    final http = _http;
    _http = null;
    port = 0;
    if (http != null) {
      try {
        await http.close(force: true);
      } catch (_) {
        // Already closed.
      }
    }
  }
}
