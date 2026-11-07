import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/device_tools.dart';
import '../features/screen_remote.dart';
import '../features/transfer_hub.dart';
import '../platform/android_notification_forwarder.dart';
import '../platform/android_received_files.dart';
import '../platform/background.dart';
import '../platform/windows_background_host.dart';
import 'crypto_util.dart';
import 'discovery.dart';
import 'identity.dart';
import 'models.dart';
import 'scanner.dart';
import 'secure_session.dart';

/// The brain of the link: finds devices, pairs, connects, reconnects,
/// sends files and text, and measures the connection. Screens listen to it
/// and rebuild when it changes.
class LinkController extends ChangeNotifier {
  LinkController(
    SharedPreferences prefs, {
    this.onFileReceived,
  })  : _prefs = prefs,
        _peers = PeerStore(prefs) {
    _name = prefs.getString('zl_name') ?? defaultDeviceName();
    _quickConnect = prefs.getBool('zl_quick') ?? true;
    _autoReceive = prefs.getBool('zl_autoreceive') ?? true;
    _autoClipboard = prefs.getBool('zl_autoclip') ?? false;
    _keepRunning = prefs.getBool('zl_keep') ?? true;
    _fileNotifications = prefs.getBool('zl_file_notifications') ?? true;
    _forwardNotifications = prefs.getBool('zl_forward_notifications') ?? false;
    remote = ScreenRemoteService(
      ask: askConsent,
      peerName: () => _active?.name ?? 'The other device',
      peerPlatform: () => _active?.platform ?? 'other',
      prefs: prefs,
    );
    remote.addListener(_notify);
    hub = TransferHub(
      onChanged: _notify,
      onActivity: _log,
      onFileReceived: (item) => _showReceivedNotification(item),
      autoReceive: () => _autoReceive,
    );
    tools = DeviceToolsService(
      ask: askConsent,
      peerName: () => _active?.name ?? 'The other device',
      sendFile: (path) => hub.sendFiles([XFile(path)]),
      prefs: prefs,
    );
    tools.addListener(_notify);
  }

  final Future<void> Function(TransferItem item, String from)? onFileReceived;
  final SharedPreferences _prefs;
  final PeerStore _peers;

  /// Files going to and from the other device.
  late final TransferHub hub;

  /// Screen mirroring and remote control.
  late final ScreenRemoteService remote;

  /// Find my phone and browsing files on the other device.
  late final DeviceToolsService tools;

  late String _name;
  late bool _quickConnect;
  late bool _autoReceive;
  late bool _autoClipboard;
  late bool _keepRunning;
  late bool _fileNotifications;
  late bool _forwardNotifications;

  Identity? _identity;
  Discovery? _discovery;
  LinkServer? _server;
  StreamSubscription<NearbyDevice>? _discoverySub;
  StreamSubscription<Map<String, dynamic>>? _messageSub;
  Timer? _tickTimer;
  Timer? _pingTimer;
  Timer? _clipTimer;
  Timer? _notificationTimer;

  final Map<String, NearbyDevice> _nearby = {};
  final Map<String, DateTime> _firstSeen = {};
  final Map<String, DateTime> _lastAttempt = {};
  final Stopwatch _sinceStart = Stopwatch();
  final List<ActivityEntry> _activity = [];
  final List<ClipEntry> _clips = [];
  final List<ForwardedNotification> _forwardedNotifications = [];
  final List<XFile> _pendingSharedFiles = [];

  SecureSession? _session;
  PairedPeer? _active;
  PairingWindow? _pairing;
  PairRequest? _request;
  ConsentRequest? _consent;
  DateTime _approveBlockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _approveBusy = false;
  Duration? _latency;
  Duration? _quickLinkTime;
  String? _event;
  String? _lastClip;
  List<String> _addresses = const [];
  List<String> _scanAddresses = const [];
  DateTime? _lastScan;

  bool _started = false;
  bool _connecting = false;
  bool _scanning = false;
  bool _fastScan = false;
  bool _hold = false;
  bool _disposed = false;
  bool _notificationPolling = false;

  // ---- What the screens read ----------------------------------------------

  String get deviceName => _name;
  bool get quickConnect => _quickConnect;
  bool get autoReceive => _autoReceive;
  bool get autoClipboard => _autoClipboard;
  bool get keepRunning => _keepRunning;
  bool get fileNotifications => _fileNotifications;
  bool get forwardNotifications => _forwardNotifications;
  int get pendingSharedCount => _pendingSharedFiles.length;
  List<PairedPeer> get pairedPeers => _peers.all;
  PairedPeer? get activePeer => _active;
  PairingWindow? get pairing => _pairing;
  PairRequest? get pendingRequest => _request;
  ConsentRequest? get pendingConsent => _consent;
  Duration? get latency => _latency;
  bool get scanning => _scanning;
  bool get connected => _session != null;
  List<ActivityEntry> get activity => List.unmodifiable(_activity);
  List<ClipEntry> get clips => List.unmodifiable(_clips);
  List<ForwardedNotification> get forwardedNotifications =>
      List.unmodifiable(_forwardedNotifications);
  List<TransferItem> get transfers => List.unmodifiable(hub.items);

  /// This device's addresses on the Wi-Fi, best guess first.
  List<String> get localAddresses => _addresses;

  /// The address to type on the other device.
  String? get primaryAddress => _addresses.isEmpty ? null : _addresses.first;
  String? get pairingQrPayload {
    final window = _pairing;
    final address = primaryAddress;
    final port = _server?.port ?? 0;
    if (window == null || !window.open || address == null || port == 0) {
      return null;
    }
    return jsonEncode({
      'z': 'zephlink-pair',
      'v': 1,
      'host': address,
      'port': port,
      'pin': window.pin,
    });
  }

  /// How long after opening the app the first link was made.
  Duration? get quickLinkTime => _quickLinkTime;

  /// Devices found on the Wi-Fi recently.
  List<NearbyDevice> get nearby {
    final list = _nearby.values.toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  bool isNearby(String id) => _nearby.containsKey(id);

  LinkStatus get status {
    if (_session != null) return LinkStatus.connected;
    if (_connecting) return LinkStatus.connecting;
    if (_peers.all.isEmpty) return LinkStatus.unpaired;
    return LinkStatus.searching;
  }

  /// "2 ms" or "<1 ms".
  String get latencyText {
    final latency = _latency;
    if (latency == null) return '';
    final ms = latency.inMicroseconds / 1000;
    return ms < 1 ? '<1 ms' : '${ms.round()} ms';
  }

  /// One line for the status bar.
  String get statusLine {
    final address = primaryAddress;
    final where = address == null ? '' : ' · this device $address';
    switch (status) {
      case LinkStatus.connected:
        return 'Connected to ${_active?.name ?? 'your device'} · end-to-end encrypted$where';
      case LinkStatus.connecting:
        return 'Connecting…';
      case LinkStatus.searching:
        return 'Looking for your paired device on this Wi-Fi$where';
      case LinkStatus.unpaired:
        return 'Not paired yet. Open Devices to pair$where';
    }
  }

  /// A one-time message such as "Paired with Studio-PC". Reading it clears it.
  String? takeEvent() {
    final value = _event;
    _event = null;
    return value;
  }

  // ---- Starting and stopping ----------------------------------------------

  /// Starts listening and looking. Safe to call once, right after the app opens.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _sinceStart.start();
    try {
      _identity = await Identity.loadOrCreate(_prefs);
    } catch (_) {
      _started = false;
      return;
    }
    if (Platform.isAndroid && _forwardNotifications) {
      try {
        await AndroidNotificationForwarder.setEnabled(true);
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'Zephlink notification forwarding',
            context:
                ErrorDescription('while restoring the notification setting'),
          ),
        );
      }
    }

    final server = LinkServer();
    try {
      await server.start(_onSocket, info: _beacon);
    } catch (_) {
      // Without a server this device can still dial out.
    }
    _server = server;

    final discovery = Discovery();
    _discoverySub = discovery.found.listen(_onFound);
    try {
      await discovery.start(_beacon);
    } catch (_) {
      // Scanning and typing an address still work.
    }
    _discovery = discovery;

    await _loadAddresses();
    _tickTimer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pingNow());
    if (_keepRunning && _peers.all.isNotEmpty) {
      unawaited(BackgroundKeeper.start());
    }
    _notify();
    _tick();
  }

  String _beacon() => jsonEncode({
        'z': 1,
        'id': _identity?.id ?? '',
        'name': _name,
        'plat': platformName,
        'port': _server?.port ?? 0,
      });

  static final RegExp _virtualAdapter = RegExp(
    r'vethernet|virtualbox|vmware|wsl|docker|hyper-v|loopback|bluetooth|rmnet|ccmni|dummy|tun|vpn|pdp',
    caseSensitive: false,
  );

  Future<void> _loadAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final real = <String>[];
      final every = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.address.startsWith('169.254.')) {
            continue;
          }
          every.add(address.address);
          if (!_virtualAdapter.hasMatch(interface.name)) {
            real.add(address.address);
          }
        }
      }
      final list = real.isNotEmpty ? real : every;
      // Home network addresses first.
      list.sort((a, b) {
        final pa = SubnetScanner.isPrivate(a) ? 0 : 1;
        final pb = SubnetScanner.isPrivate(b) ? 0 : 1;
        return pa.compareTo(pb);
      });
      _addresses = list;
      _scanAddresses = list.where(SubnetScanner.isPrivate).toList();
      _notify();
    } catch (_) {
      // The list is only a convenience.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _tickTimer?.cancel();
    _pingTimer?.cancel();
    _clipTimer?.cancel();
    _notificationTimer?.cancel();
    unawaited(_discoverySub?.cancel());
    unawaited(_messageSub?.cancel());
    _discovery?.stop();
    unawaited(_server?.stop());
    hub.detach();
    remote.removeListener(_notify);
    remote.dispose();
    tools.removeListener(_notify);
    tools.dispose();
    _session?.close();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _log(String text, String kind) {
    _activity.insert(0, ActivityEntry(text, kind));
    if (_activity.length > 40) _activity.removeLast();
    _notify();
  }

  // ---- Settings -----------------------------------------------------------

  Future<void> rename(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    _name = clean.length > 40 ? clean.substring(0, 40) : clean;
    await _prefs.setString('zl_name', _name);
    _notify();
  }

  Future<void> setQuickConnect(bool value) async {
    _quickConnect = value;
    await _prefs.setBool('zl_quick', value);
    _notify();
    if (value) _autoConnect();
  }

  Future<void> setAutoReceive(bool value) async {
    _autoReceive = value;
    await _prefs.setBool('zl_autoreceive', value);
    _notify();
  }

  Future<void> setAutoClipboard(bool value) async {
    _autoClipboard = value;
    await _prefs.setBool('zl_autoclip', value);
    _startClipTimer();
    _notify();
  }

  Future<void> setKeepRunning(bool value) async {
    _keepRunning = value;
    await _prefs.setBool('zl_keep', value);
    if (Platform.isAndroid && value) {
      await BackgroundKeeper.start();
    } else if (Platform.isAndroid) {
      await BackgroundKeeper.stop();
    } else if (Platform.isWindows) {
      await WindowsBackgroundHost.setKeepRunning(value);
    }
    _notify();
  }

  Future<void> setFileNotifications(bool value) async {
    _fileNotifications = value;
    await _prefs.setBool('zl_file_notifications', value);
    _notify();
  }

  Future<void> setForwardNotifications(bool value) async {
    _forwardNotifications = value;
    await _prefs.setBool('zl_forward_notifications', value);
    if (Platform.isAndroid) {
      try {
        await AndroidNotificationForwarder.setEnabled(value);
        if (value && !await AndroidNotificationForwarder.hasAccess()) {
          await AndroidNotificationForwarder.openSettings();
        }
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'Zephlink notification forwarding',
            context:
                ErrorDescription('while updating Android notification access'),
          ),
        );
      }
    }
    _startNotificationForwarding();
    _notify();
  }

  // ---- Finding devices ----------------------------------------------------

  /// Scans faster while the Devices page is open.
  void setFastScan(bool value) {
    _fastScan = value;
    if (value) unawaited(scanNow());
  }

  /// Asks every address on the Wi-Fi whether it is Zephlink.
  Future<void> scanNow() async {
    final me = _identity;
    if (me == null || _scanning || _disposed) return;
    _scanning = true;
    _lastScan = DateTime.now();
    _notify();
    try {
      await _loadAddresses();
      final found = await SubnetScanner.scan(
        selfId: me.id,
        addresses: _scanAddresses,
      );
      for (final device in found) {
        _onFound(device);
      }
    } catch (_) {
      // A failed scan just finds nothing.
    } finally {
      _scanning = false;
      _notify();
    }
  }

  // ---- Pairing ------------------------------------------------------------

  /// Shows a one-time code on this device for 5 minutes.
  void startPairing() {
    _pairing = PairingWindow(randomPin());
    _notify();
  }

  void cancelPairing() {
    _pairing = null;
    _notify();
  }

  /// Answers the "allow pairing?" question on screen.
  void answerRequest(bool allow) {
    final request = _request;
    if (request != null && !request.answer.isCompleted) {
      request.answer.complete(allow);
    }
  }

  /// Pairs using an address like "192.168.1.5" or "192.168.1.5:47475".
  /// Returns an error message, or null when it worked.
  Future<String?> pairWithAddress(String text, String pin) {
    final parts = text.trim().split(':');
    final address = InternetAddress.tryParse(parts.first);
    if (address == null) {
      return Future<String?>.value(
          'Type the other device\'s address, like 192.168.1.5');
    }
    final port = parts.length > 1 ? int.tryParse(parts[1]) : defaultLinkPort;
    if (port == null) {
      return Future<String?>.value('That port is not a number.');
    }
    final code = pin.trim();
    if (code.length != 6) {
      return Future<String?>.value(
          'Type the 6-digit code shown on the other device.');
    }
    return _dial(address, port, 'pair', code);
  }

  /// Validates a Zephlink QR payload before opening a pairing connection.
  Future<String?> pairFromQr(String payload) {
    if (payload.length > 2048) {
      return Future<String?>.value(
          'That QR code is too large to be a Zephlink code.');
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic> ||
          decoded['z'] != 'zephlink-pair' ||
          decoded['v'] != 1) {
        return Future<String?>.value('That is not a Zephlink pairing QR code.');
      }
      final host = decoded['host'];
      final port = decoded['port'];
      final pin = decoded['pin'];
      final address = host is String ? InternetAddress.tryParse(host) : null;
      if (address == null ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          pin is! String ||
          !RegExp(r'^\d{6}$').hasMatch(pin)) {
        return Future<String?>.value(
            'The Zephlink QR code is incomplete or invalid.');
      }
      return _dial(address, port, 'pair', pin);
    } on FormatException {
      return Future<String?>.value(
          'That is not a valid Zephlink pairing QR code.');
    }
  }

  /// Shares files received from Android's system share sheet or Windows shell.
  /// Files wait in memory until a paired device is connected.
  Future<void> queueSharedFiles(List<XFile> files) async {
    if (files.isEmpty) return;
    if (_session != null) {
      await hub.sendFiles(files);
      return;
    }
    _pendingSharedFiles.addAll(files);
    _event =
        '${files.length} shared file${files.length == 1 ? '' : 's'} queued. '
        'Connect a device to send.';
    _notify();
  }

  /// Starts pairing with a device found on this Wi-Fi. Both devices must
  /// compare the displayed verification code and approve the request.
  Future<String?> pairNearby(NearbyDevice device) {
    final current = _nearby[device.id];
    if (current == null) {
      return Future<String?>.value(
        '${device.name} is no longer on this Wi-Fi. Scan again and retry.',
      );
    }
    return _dial(current.address, current.port, 'approve', null);
  }

  Future<void> forget(String id) async {
    if (_active?.id == id) {
      _session?.close();
    }
    await _peers.remove(id);
    _notify();
  }

  // ---- Connecting ---------------------------------------------------------

  /// Connects to a paired device by hand. Returns an error message, or null.
  Future<String?> connectPeer(PairedPeer peer) {
    final device = _nearby[peer.id];
    if (device == null) {
      return Future<String?>.value(
        '${peer.name} is not on this Wi-Fi right now. Open Zephlink there and try again.',
      );
    }
    _hold = false;
    return _dial(device.address, device.port, 'link', null);
  }

  /// Ends the link on purpose. Auto-connect stays paused until you connect again.
  Future<void> disconnect() async {
    final session = _session;
    if (session == null) return;
    _hold = true;
    await session.send(<String, dynamic>{'t': 'bye'});
    session.close();
  }

  Future<String?> _dial(
    InternetAddress address,
    int port,
    String mode,
    String? pin,
  ) async {
    final me = _identity;
    if (me == null) return 'Zephlink is still starting. Try again in a moment.';
    if (_connecting) return 'Already connecting. Please wait.';
    _connecting = true;
    _notify();
    try {
      final result = await dialPeer(
        me: me,
        myName: _name,
        store: _peers,
        address: address,
        port: port,
        mode: mode,
        pin: pin,
      );
      if (result.requiresApproval) {
        final ok = await _confirmPairing(result, incoming: false);
        if (!ok) {
          _hold = true;
          result.session.close();
          return result.newlyPaired
              ? 'Pairing was not approved on both devices.'
              : 'Connection was not approved on both devices.';
        }
      }
      await _adopt(result);
      return null;
    } on HandshakeError catch (error) {
      return error.message;
    } on TimeoutException {
      return 'Could not reach the other device. Check the address and that both are on the same Wi-Fi.';
    } on SocketException {
      return 'Could not reach the other device. Check the address and that both are on the same Wi-Fi.';
    } catch (_) {
      return 'Something went wrong while connecting.';
    } finally {
      _connecting = false;
      _notify();
    }
  }

  Future<void> _onSocket(WebSocket socket) async {
    final me = _identity;
    if (me == null) {
      await socket.close();
      return;
    }
    var tookApproveSlot = false;
    try {
      final result = await acceptPeer(
        ws: socket,
        me: me,
        myName: _name,
        store: _peers,
        pairing: () => _pairing,
        allowApprove: () {
          // One approval request at a time, and a short pause after a refusal
          // so nobody on the Wi-Fi can bury the screen in pop-ups.
          if (_approveBusy || _request != null) return false;
          if (DateTime.now().isBefore(_approveBlockedUntil)) return false;
          _approveBusy = true;
          tookApproveSlot = true;
          return true;
        },
      );
      if (result.requiresApproval) {
        final ok = await _confirmPairing(result, incoming: true);
        if (!ok) {
          _hold = true;
          result.session.close();
          _pairing = null;
          _approveBlockedUntil = DateTime.now().add(const Duration(seconds: 8));
          _event = 'Pairing was not approved.';
          _notify();
          return;
        }
      }
      await _adopt(result);
    } catch (_) {
      // acceptPeer already told the other side and closed the socket.
      if (tookApproveSlot) {
        _approveBlockedUntil = DateTime.now().add(const Duration(seconds: 3));
      }
    } finally {
      if (tookApproveSlot) _approveBusy = false;
    }
  }

  /// Both people must say yes, each on their own device.
  Future<bool> _confirmPairing(
    LinkResult result, {
    required bool incoming,
  }) async {
    final session = result.session;
    // Listen for the other side's answer before anything else can arrive.
    final theirs = session.messages
        .where((m) => m['t'] == 'pair-decision')
        .first
        .then((m) => m['ok'] == true)
        .timeout(const Duration(seconds: 90), onTimeout: () => false)
        .catchError((Object _) => false);
    session.start();

    final mine = await _askUser(
      PairRequest(
        peerName: result.peer.name,
        platform: result.peer.platform,
        incoming: incoming,
        reconnecting: !result.newlyPaired,
        verificationCode: result.verificationCode,
      ),
    );
    await session.send(<String, dynamic>{'t': 'pair-decision', 'ok': mine});
    final theirAnswer = await theirs;
    return mine && theirAnswer;
  }

  Future<bool> _askUser(PairRequest request) async {
    // One question at a time. A second request cannot replace the first.
    if (_request != null) return false;
    _request = request;
    WindowsBackgroundHost.bringToFront();
    _notify();
    try {
      return await request.answer.future
          .timeout(const Duration(seconds: 90), onTimeout: () => false);
    } finally {
      _request = null;
      _notify();
    }
  }

  /// Answers the on-screen question from [askConsent].
  void answerConsent(bool allow, bool option) {
    final request = _consent;
    if (request != null && !request.answer.isCompleted) {
      request.answer.complete(ConsentAnswer(allow, option));
    }
  }

  /// Shows a yes/no question on screen (bringing the Windows window forward)
  /// and waits for the answer. One question at a time; no answer means no.
  Future<ConsentAnswer> askConsent(ConsentRequest request) async {
    if (_consent != null) return const ConsentAnswer(false, false);
    _consent = request;
    WindowsBackgroundHost.bringToFront();
    _notify();
    try {
      return await request.answer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => const ConsentAnswer(false, false),
      );
    } finally {
      _consent = null;
      _notify();
    }
  }

  /// Keeps one link per device. If two links open at once (both sides
  /// dialled), both devices keep the one opened by the smaller id.
  Future<void> _adopt(LinkResult result) async {
    final peer = result.peer;
    final session = result.session;
    final existing = _session;
    if (existing != null) {
      final sameDevice = existing.peerId == peer.id;
      final newWins = session.initiatorId.compareTo(existing.initiatorId) < 0;
      if (!sameDevice || !newWins) {
        session.close();
        return;
      }
      existing.close();
    }

    _session = session;
    _active = peer;
    _hold = false;
    _latency = null;
    _quickLinkTime ??= _sinceStart.elapsed;

    // Subscribe first, then start reading, so no message is missed.
    hub.attach(session);
    remote.attach(session);
    tools.attach(session);
    unawaited(_messageSub?.cancel());
    _messageSub = session.messages.listen(_onMessage);
    session.start();
    unawaited(session.closed.then((_) => _onClosed(session)));

    if (result.newlyPaired) {
      await _peers.put(peer);
      _pairing = null;
      _event = 'Paired with ${peer.name}';
      if (_keepRunning) unawaited(BackgroundKeeper.start());
    } else {
      final stored = _peers.byId(peer.id);
      if (stored != null && stored.name != peer.name) {
        stored.name = peer.name;
        await _peers.put(stored);
      }
    }
    await _peers.setLast(peer.id);
    _log('Linked with ${peer.name}', 'link');
    _startClipTimer();
    _startNotificationForwarding();
    unawaited(_pingNow());
    if (_pendingSharedFiles.isNotEmpty) {
      final pending = List<XFile>.of(_pendingSharedFiles);
      _pendingSharedFiles.clear();
      unawaited(hub.sendFiles(pending));
    }
  }

  Future<void> _showReceivedNotification(TransferItem item) async {
    if (Platform.isAndroid && item.path != null) {
      final temporaryFile = File(item.path!);
      try {
        final published = await AndroidReceivedFiles.publish(
          temporaryFile,
          item.name,
        );
        if (published != null) {
          item.externalUri = published.uri;
          item.path = published.uri.startsWith('file://')
              ? Uri.parse(published.uri).toFilePath()
              : published.uri;
          if (await temporaryFile.exists()) await temporaryFile.delete();
          _notify();
        }
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'Zephlink received files',
            context: ErrorDescription(
              'while copying a received file to Downloads/Zephlink',
            ),
          ),
        );
      }
    }
    if (!_fileNotifications) return;
    final notify = onFileReceived;
    if (notify == null) return;
    try {
      await notify(item, _active?.name ?? 'your device');
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink transfer notification',
          context: ErrorDescription('while notifying about a received file'),
        ),
      );
    }
  }

  void _onClosed(SecureSession session) {
    if (!identical(_session, session)) return;
    if (session.byeReceived) _hold = true;
    final name = _active?.name ?? 'your device';
    _session = null;
    _active = null;
    _latency = null;
    hub.detach();
    remote.detach();
    tools.detach();
    unawaited(_messageSub?.cancel());
    _messageSub = null;
    _clipTimer?.cancel();
    _notificationTimer?.cancel();
    _log('Disconnected from $name', 'link');
  }

  Future<void> _pingNow() async {
    final session = _session;
    if (session == null) return;
    try {
      _latency = await session.ping();
    } catch (_) {
      // One missed answer is normal while a big file is going through or the
      // phone is busy. Only give up after a long silence.
      if (session.silence > const Duration(seconds: 25)) session.close();
    }
    if (identical(session, _session)) _notify();
  }

  // ---- Files --------------------------------------------------------------

  Future<void> sendFiles(List<XFile> files) async {
    if (_session == null || files.isEmpty) return;
    await hub.sendFiles(files);
  }

  Future<void> sendSources(List<TransferSource> sources) async {
    if (_session == null || sources.isEmpty) return;
    await hub.sendSources(sources);
  }

  void cancelTransfer(TransferItem item) => hub.cancel(item);

  Future<void> resumeTransfer(TransferItem item) => hub.resume(item);

  /// Sends a failed or cancelled file again. Null when it was queued.
  Future<String?> resendTransfer(TransferItem item) => hub.resend(item);

  /// Sends every failed file again. Returns how many were queued.
  Future<int> resendAllFailed() => hub.resendFailed();

  void clearFinishedTransfers() => hub.clearFinished();

  // ---- Clipboard ----------------------------------------------------------

  /// Sends whatever text is on this device's clipboard.
  Future<String?> sendClipboard() async {
    final session = _session;
    if (session == null) return 'Connect a device first.';
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return 'Your clipboard is empty.';
    return _sendText(session, text);
  }

  /// Sends text you typed.
  Future<String?> sendText(String text) async {
    final session = _session;
    if (session == null) return 'Connect a device first.';
    if (text.trim().isEmpty) return 'Type something to send.';
    return _sendText(session, text);
  }

  Future<String?> _sendText(SecureSession session, String text) async {
    if (text.length > 1000000) {
      return 'That text is too long to send (limit 1 MB).';
    }
    await session.send(<String, dynamic>{'t': 'clip', 'text': text});
    _lastClip = text;
    _log('Sent text to ${_active?.name ?? 'your device'}', 'send');
    return null;
  }

  void removeClip(ClipEntry clip) {
    _clips.remove(clip);
    _notify();
  }

  Future<void> replyToPhoneNotification(
    ForwardedNotification notification,
    String text,
  ) async {
    final session = _session;
    final clean = text.trim();
    if (session == null || clean.isEmpty || clean.length > 2000) return;
    await session.send(<String, dynamic>{
      't': 'phone-notification-reply-request',
      'id': notification.id,
      'text': clean,
    });
  }

  void dismissPhoneNotification(ForwardedNotification notification) {
    _forwardedNotifications.removeWhere((item) => item.id == notification.id);
    final session = _session;
    if (session != null) {
      unawaited(session.send(<String, dynamic>{
        't': 'phone-notification-dismiss-request',
        'id': notification.id,
      }));
    }
    _notify();
  }

  void _onMessage(Map<String, dynamic> message) {
    switch (message['t']) {
      case 'clip':
        final text = message['text'];
        if (text is! String || text.isEmpty || text.length > 1000000) return;
        final from = _active?.name ?? 'Your device';
        _clips.insert(0, ClipEntry(text, from));
        if (_clips.length > 30) _clips.removeLast();
        _log('Received text from $from', 'receive');
        if (_autoClipboard) {
          _lastClip = text;
          unawaited(Clipboard.setData(ClipboardData(text: text)));
        }
      case 'phone-notification':
        if (Platform.isWindows) _receivePhoneNotification(message);
      case 'phone-notification-removed':
        if (Platform.isWindows) _receivePhoneNotificationRemoval(message);
      case 'phone-notification-ack':
        if (Platform.isAndroid && message['eventId'] is String) {
          unawaited(
            _ackPhoneNotification(message['eventId'] as String),
          );
        }
      case 'phone-notification-reply-request':
        if (Platform.isAndroid &&
            message['id'] is String &&
            message['text'] is String) {
          unawaited(
            _replyToAndroidNotification(
              message['id'] as String,
              message['text'] as String,
            ),
          );
        }
      case 'phone-notification-dismiss-request':
        if (Platform.isAndroid && message['id'] is String) {
          unawaited(
            _dismissAndroidNotification(message['id'] as String),
          );
        }
    }
  }

  void _receivePhoneNotification(Map<String, dynamic> message) {
    final eventId = message['eventId'];
    final id = message['id'];
    final app = message['app'];
    final title = message['title'];
    final text = message['text'];
    final timestamp = message['time'];
    if (eventId is! String ||
        id is! String ||
        app is! String ||
        title is! String ||
        text is! String ||
        id.length > 128 ||
        app.length > 128 ||
        title.length > 512 ||
        text.length > 4096) {
      return;
    }
    final session = _session;
    if (session != null) {
      unawaited(session.send(<String, dynamic>{
        't': 'phone-notification-ack',
        'eventId': eventId,
      }));
    }
    final postedAt = timestamp is int
        ? DateTime.fromMillisecondsSinceEpoch(timestamp)
        : DateTime.now();
    final forwarded = ForwardedNotification(
      id: id,
      eventId: eventId,
      app: app,
      title: title,
      text: text,
      canReply: message['canReply'] == true,
      postedAt: postedAt,
    );
    _forwardedNotifications.removeWhere((item) => item.id == id);
    _forwardedNotifications.insert(0, forwarded);
    if (_forwardedNotifications.length > 100) {
      _forwardedNotifications.removeLast();
    }
    _notify();
  }

  void _receivePhoneNotificationRemoval(Map<String, dynamic> message) {
    final eventId = message['eventId'];
    final id = message['id'];
    if (eventId is! String || id is! String || id.length > 128) return;
    _forwardedNotifications.removeWhere((item) => item.id == id);
    final session = _session;
    if (session != null) {
      unawaited(session.send(<String, dynamic>{
        't': 'phone-notification-ack',
        'eventId': eventId,
      }));
    }
    _notify();
  }

  void _startNotificationForwarding() {
    _notificationTimer?.cancel();
    if (!Platform.isAndroid ||
        !_forwardNotifications ||
        _session == null ||
        _active?.platform != 'windows') {
      return;
    }
    _notificationTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollPhoneNotifications()),
    );
    unawaited(_pollPhoneNotifications());
  }

  Future<void> _pollPhoneNotifications() async {
    final session = _session;
    if (!Platform.isAndroid ||
        !_forwardNotifications ||
        session == null ||
        _active?.platform != 'windows' ||
        _notificationPolling) {
      return;
    }
    _notificationPolling = true;
    try {
      final events = await AndroidNotificationForwarder.pending();
      for (final event in events) {
        if (!identical(session, _session)) return;
        final eventId = event['eventId'];
        final id = event['id'];
        final type = event['type'];
        if (eventId is! String || id is! String || type is! String) continue;
        if (type == 'removed') {
          await session.send(<String, dynamic>{
            't': 'phone-notification-removed',
            'eventId': eventId,
            'id': id,
          });
        } else if (type == 'posted' &&
            event['app'] is String &&
            event['title'] is String &&
            event['text'] is String &&
            event['time'] is int) {
          await session.send(<String, dynamic>{
            't': 'phone-notification',
            'eventId': eventId,
            'id': id,
            'app': event['app'],
            'title': event['title'],
            'text': event['text'],
            'canReply': event['canReply'] == true,
            'time': event['time'],
          });
        }
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink notification forwarding',
          context: ErrorDescription('while forwarding phone notifications'),
        ),
      );
    } finally {
      _notificationPolling = false;
    }
  }

  Future<void> _ackPhoneNotification(String eventId) async {
    try {
      await AndroidNotificationForwarder.acknowledge(eventId);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink notification forwarding',
          context:
              ErrorDescription('while acknowledging a forwarded notification'),
        ),
      );
    }
  }

  Future<void> _replyToAndroidNotification(String id, String text) async {
    try {
      await AndroidNotificationForwarder.reply(id, text);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink notification forwarding',
          context: ErrorDescription('while replying to a phone notification'),
        ),
      );
    }
  }

  Future<void> _dismissAndroidNotification(String id) async {
    try {
      await AndroidNotificationForwarder.dismiss(id);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink notification forwarding',
          context: ErrorDescription('while dismissing a phone notification'),
        ),
      );
    }
  }

  void _startClipTimer() {
    _clipTimer?.cancel();
    if (!_autoClipboard || _session == null) return;
    // Remember what is on the clipboard now so it is not sent by surprise.
    unawaited(
      Clipboard.getData(Clipboard.kTextPlain).then((data) {
        _lastClip = data?.text;
      }).catchError((Object _) {}),
    );
    _clipTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollClipboard());
  }

  Future<void> _pollClipboard() async {
    final session = _session;
    if (session == null) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty || text == _lastClip) return;
      _lastClip = text;
      await _sendText(session, text);
    } catch (_) {
      // Reading the clipboard can fail while the app is in the background.
    }
  }

  // ---- Watching the Wi-Fi -------------------------------------------------

  void _onFound(NearbyDevice device) {
    // We hear our own announcements too. Ignore them.
    if (device.id == _identity?.id) return;
    final isNew = !_nearby.containsKey(device.id);
    _nearby[device.id] = device;
    _firstSeen.putIfAbsent(device.id, () => DateTime.now());
    if (isNew) _notify();
    _autoConnect();
  }

  void _tick() {
    var changed = false;
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(seconds: 35));
    final gone = _nearby.entries
        .where((entry) => entry.value.lastSeen.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList();
    for (final id in gone) {
      _nearby.remove(id);
      _firstSeen.remove(id);
      changed = true;
    }
    final window = _pairing;
    if (window != null && !window.open) {
      _pairing = null;
      changed = true;
    }
    if (changed) _notify();

    final every = Duration(seconds: _fastScan ? 6 : 15);
    final last = _lastScan;
    final due = last == null || now.difference(last) > every;
    if (!_scanning && due && (_session == null || _fastScan)) {
      unawaited(scanNow());
    }
    _autoConnect();
  }

  /// Quick connect: as soon as a paired device is on the Wi-Fi, link to it.
  void _autoConnect() {
    final me = _identity;
    if (me == null || !_quickConnect || _hold) return;
    if (_session != null || _connecting || _request != null) return;

    final now = DateTime.now();
    final lastId = _peers.lastId;
    NearbyDevice? pick;
    for (final device in _nearby.values) {
      if (_peers.byId(device.id) == null) continue;
      final tried = _lastAttempt[device.id];
      if (tried != null && now.difference(tried) < const Duration(seconds: 8)) {
        continue;
      }
      // The smaller id dials first. The other side waits 6 seconds in case
      // the first one cannot reach it.
      final myTurn = me.id.compareTo(device.id) < 0;
      final seenFor = now.difference(_firstSeen[device.id] ?? now);
      if (!myTurn && seenFor < const Duration(seconds: 6)) continue;
      if (pick == null || device.id == lastId) pick = device;
    }
    if (pick == null) return;
    _lastAttempt[pick.id] = now;
    unawaited(_dial(pick.address, pick.port, 'link', null));
  }
}
