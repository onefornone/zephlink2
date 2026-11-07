import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../link/models.dart';
import '../link/secure_session.dart';
import '../platform/android_tools.dart';

/// One file or folder in a listing from the other device.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
    this.path,
  });

  /// Full path, only filled in for the top-level list of drives or storage.
  final String? path;
  final String name;
  final bool isDir;
  final int size;

  /// Milliseconds since 1970, or 0 when unknown.
  final int modified;
}

/// The answer to "what is in this folder?".
class RemoteListing {
  const RemoteListing({
    required this.ok,
    this.why,
    this.path = '',
    this.parent,
    this.isRoot = false,
    this.items = const [],
  });

  final bool ok;
  final String? why;

  /// Full path of the folder, as the other device writes it.
  final String path;

  /// Folder one level up, or null at the top.
  final String? parent;

  /// This is the list of drives or storage areas.
  final bool isRoot;
  final List<RemoteEntry> items;
}

/// "Find my phone" and "Browse files", the two helpers that sit beside screen
/// sharing. Both are read-only or harmless:
/// * Ringing only plays a sound and can be turned off in Settings.
/// * File browsing only lists names and sends files that the other device asks
///   for. It cannot change or delete anything, it needs the owner's answer
///   once per link, and it ends with the link.
class DeviceToolsService extends ChangeNotifier {
  DeviceToolsService({
    required this.ask,
    required this.peerName,
    required this.sendFile,
    SharedPreferences? prefs,
  })  : _prefs = prefs,
        allowRing = prefs?.getBool('zl_allow_ring') ?? true,
        alwaysAllowFiles = prefs?.getBool('zl_always_files') ?? false;

  final SharedPreferences? _prefs;
  final Future<ConsentAnswer> Function(ConsentRequest request) ask;
  final String Function() peerName;

  /// Sends one file from this device to the other (the normal transfer).
  final Future<void> Function(String path) sendFile;

  /// Other devices may make this phone ring.
  bool allowRing;

  /// Other devices may browse this device's files without asking each link.
  bool alwaysAllowFiles;

  SecureSession? _session;
  StreamSubscription<Map<String, dynamic>>? _sub;

  // Find my phone, asking side.
  int? peerBattery;
  bool peerCharging = false;
  bool peerRinging = false;
  String? findNotice;
  bool findBusy = false;

  // Find my phone, ringing side.
  bool ringingHere = false;
  Timer? _ringTimer;

  // File browsing, answering side.
  bool _filesGranted = false;
  Future<bool>? _filesAsking;

  // File browsing, asking side.
  int _nextId = 1;
  final Map<int, Completer<RemoteListing>> _pending = {};

  bool get connected => _session != null;

  Future<void> setAllowRing(bool value) async {
    allowRing = value;
    notifyListeners();
    await _prefs?.setBool('zl_allow_ring', value);
  }

  Future<void> setAlwaysAllowFiles(bool value) async {
    alwaysAllowFiles = value;
    notifyListeners();
    await _prefs?.setBool('zl_always_files', value);
  }

  // ---- Link life --------------------------------------------------------

  void attach(SecureSession session) {
    detach();
    _session = session;
    _sub = session.messages.listen(_onMessage);
    notifyListeners();
  }

  void detach() {
    unawaited(_sub?.cancel());
    _sub = null;
    _session = null;
    _filesGranted = false;
    _filesAsking = null;
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) {
        waiting.complete(
          const RemoteListing(ok: false, why: 'The link closed.'),
        );
      }
    }
    _pending.clear();
    peerBattery = null;
    peerRinging = false;
    findNotice = null;
    findBusy = false;
    if (ringingHere) unawaited(stopRingingHere());
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    _ringTimer?.cancel();
    super.dispose();
  }

  Future<void> _send(Map<String, dynamic> message) async {
    final session = _session;
    if (session == null) return;
    await session.send(message);
  }

  // ---- Find my phone: asking side -----------------------------------------

  /// Asks the phone for its battery level.
  Future<void> refreshInfo() async {
    if (_session == null) return;
    findBusy = true;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'fm-info'});
    Timer(const Duration(seconds: 6), () {
      if (findBusy) {
        findBusy = false;
        notifyListeners();
      }
    });
  }

  Future<void> ringPeer() async {
    if (_session == null) return;
    findNotice = null;
    peerRinging = true;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'fm-ring', 'on': true, 'secs': 90});
  }

  Future<void> stopPeerRing() async {
    peerRinging = false;
    notifyListeners();
    await _send(<String, dynamic>{'t': 'fm-ring', 'on': false});
  }

  // ---- Find my phone: ringing side ----------------------------------------

  Future<void> stopRingingHere() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    await AndroidTools.stopRing();
    if (ringingHere) {
      ringingHere = false;
      notifyListeners();
    }
  }

  Future<void> _onRing(Map<String, dynamic> m) async {
    if (m['on'] != true) {
      await stopRingingHere();
      return;
    }
    if (!AndroidTools.supported) {
      await _send(<String, dynamic>{
        't': 'fm-ring-r',
        'ok': false,
        'why': 'This device cannot ring.',
      });
      return;
    }
    if (!allowRing) {
      await _send(<String, dynamic>{
        't': 'fm-ring-r',
        'ok': false,
        'why': 'This phone is set not to ring when ${peerName()} asks. '
            'Turn it on in Zephlink Settings on the phone.',
      });
      return;
    }
    final secsRaw = m['secs'];
    final secs = secsRaw is int ? math.min(180, math.max(10, secsRaw)) : 60;
    final ok = await AndroidTools.ring(secs);
    if (!ok) {
      await _send(<String, dynamic>{
        't': 'fm-ring-r',
        'ok': false,
        'why': 'The phone could not start the sound.',
      });
      return;
    }
    ringingHere = true;
    _ringTimer?.cancel();
    _ringTimer = Timer(Duration(seconds: secs), () {
      ringingHere = false;
      notifyListeners();
    });
    notifyListeners();
    await _send(<String, dynamic>{'t': 'fm-ring-r', 'ok': true});
    unawaited(_sendInfo());
  }

  Future<void> _sendInfo() async {
    final battery = await AndroidTools.battery();
    await _send(<String, dynamic>{
      't': 'fm-info-r',
      'pct': battery['pct'],
      'charging': battery['charging'],
      'ringing': ringingHere,
    });
  }

  // ---- Browse files: answering side ---------------------------------------

  Future<bool> _filesAllowed() {
    if (_filesGranted) return Future<bool>.value(true);
    final running = _filesAsking;
    if (running != null) return running;
    final next = _askFiles();
    _filesAsking = next;
    return next.whenComplete(() => _filesAsking = null);
  }

  Future<bool> _askFiles() async {
    if (alwaysAllowFiles) {
      _filesGranted = true;
      return true;
    }
    final answer = await ask(
      ConsentRequest(
        title: 'Let ${peerName()} browse your files?',
        message: '${peerName()} will see the names of folders and files on '
            'this device and can ask to receive a file. It cannot change or '
            'delete anything. This ends when the link ends.',
        allowLabel: 'Allow',
        optionLabel: 'Do not ask again',
        platform: Platform.isAndroid ? 'android' : 'windows',
      ),
    );
    if (!answer.allow) return false;
    _filesGranted = true;
    if (answer.option) await setAlwaysAllowFiles(true);
    return true;
  }

  /// Rejects paths that try to climb out with "..".
  bool _cleanPath(String path) {
    if (path.isEmpty || path.length > 1024 || path.contains('\u0000')) {
      return false;
    }
    return !path.split(RegExp(r'[\\/]')).contains('..');
  }

  bool _insideAllowed(String path) {
    if (Platform.isAndroid) {
      return path == '/storage' || path.startsWith('/storage/');
    }
    return true;
  }

  Future<void> _onList(Map<String, dynamic> m) async {
    final id = m['id'];
    if (id is! int) return;
    Future<void> fail(String why) => _send(<String, dynamic>{
          't': 'fb-list-r',
          'id': id,
          'ok': false,
          'why': why,
        });

    if (!await _filesAllowed()) {
      await fail('${_selfName()} did not allow browsing files.');
      return;
    }
    if (Platform.isAndroid && !await AndroidTools.filesAllowed()) {
      await AndroidTools.openFilesAccess();
      await fail('On the phone, turn on "Allow access to all files" for '
          'Zephlink, then try again.');
      return;
    }
    final rawPath = m['path'];
    final path = rawPath is String ? rawPath : '';
    try {
      if (path.isEmpty) {
        final roots = await _roots();
        await _send(<String, dynamic>{
          't': 'fb-list-r',
          'id': id,
          'ok': true,
          'root': true,
          'path': '',
          'items': <Map<String, dynamic>>[
            for (final root in roots)
              <String, dynamic>{
                'n': root['name'],
                'p': root['path'],
                'd': true,
                's': 0,
                'm': 0,
              },
          ],
        });
        return;
      }
      if (!_cleanPath(path) || !_insideAllowed(path)) {
        await fail('That folder is not available.');
        return;
      }
      final dir = Directory(path);
      if (!await dir.exists()) {
        await fail('That folder does not exist.');
        return;
      }
      final items = <Map<String, dynamic>>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (items.length >= 1500) break;
        try {
          final parts = entity.path
              .split(RegExp(r'[\\/]'))
              .where((part) => part.isNotEmpty)
              .toList();
          if (parts.isEmpty) continue;
          final name = parts.last;
          if (entity is Directory) {
            items.add(<String, dynamic>{
              'n': name,
              'd': true,
              's': 0,
              'm': 0,
            });
          } else if (entity is File) {
            final stat = await entity.stat();
            items.add(<String, dynamic>{
              'n': name,
              'd': false,
              's': stat.size,
              'm': stat.modified.millisecondsSinceEpoch,
            });
          }
        } catch (_) {
          // Skip anything that cannot be read.
        }
      }
      await _send(<String, dynamic>{
        't': 'fb-list-r',
        'id': id,
        'ok': true,
        'root': false,
        'path': path,
        'parent': _parentOf(path),
        'items': items,
      });
    } catch (_) {
      await fail('That folder cannot be read.');
    }
  }

  String _selfName() => Platform.isAndroid ? 'The phone' : 'The PC';

  /// The folder one level up, or '' to go back to the list of drives.
  String _parentOf(String path) {
    final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
    if (Platform.isWindows) {
      // "C:" has no folder above it: go back to the drive list.
      if (cut < 0 || RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) return '';
      final up = trimmed.substring(0, cut);
      return up.endsWith(':') ? '$up\\' : up;
    }
    if (cut <= 0) return '';
    final up = trimmed.substring(0, cut);
    return up == '/storage/emulated' || up == '/storage' ? '' : up;
  }

  Future<List<Map<String, String>>> _roots() async {
    if (Platform.isAndroid) return AndroidTools.roots();
    final out = <Map<String, String>>[];
    for (var code = 'C'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
      final letter = String.fromCharCode(code);
      final drive = '$letter:\\';
      try {
        if (await Directory(drive).exists()) {
          out.add(<String, String>{'name': 'Drive $letter:', 'path': drive});
        }
      } catch (_) {
        // Not ready, such as an empty card reader.
      }
    }
    return out;
  }

  Future<void> _onGet(Map<String, dynamic> m) async {
    final raw = m['path'];
    Future<void> fail(String why) =>
        _send(<String, dynamic>{'t': 'fb-no', 'why': why});
    if (raw is! String || !_cleanPath(raw) || !_insideAllowed(raw)) {
      await fail('That file is not available.');
      return;
    }
    if (!_filesGranted) {
      await fail('Browsing files is not allowed on ${_selfName()}.');
      return;
    }
    try {
      final file = File(raw);
      if (!await file.exists()) {
        await fail('That file no longer exists.');
        return;
      }
      await sendFile(raw);
    } catch (_) {
      await fail('That file cannot be sent.');
    }
  }

  // ---- Browse files: asking side --------------------------------------------

  /// Lists a folder on the other device. An empty [path] means the top level
  /// (drives on a PC, storage on a phone).
  Future<RemoteListing> listFolder(String path) async {
    if (_session == null) {
      return const RemoteListing(ok: false, why: 'Connect a device first.');
    }
    final id = _nextId++;
    final completer = Completer<RemoteListing>();
    _pending[id] = completer;
    await _send(<String, dynamic>{'t': 'fb-list', 'id': id, 'path': path});
    return completer.future.timeout(
      const Duration(seconds: 75),
      onTimeout: () {
        _pending.remove(id);
        return const RemoteListing(
          ok: false,
          why: 'No answer. Check the other device.',
        );
      },
    );
  }

  /// Asks the other device to send us a file. It arrives like any other file.
  Future<void> download(String path) async {
    await _send(<String, dynamic>{'t': 'fb-get', 'path': path});
  }

  void _onListed(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is! int) return;
    final waiting = _pending.remove(id);
    if (waiting == null || waiting.isCompleted) return;
    if (m['ok'] != true) {
      final why = m['why'];
      waiting.complete(
        RemoteListing(ok: false, why: why is String ? why : 'Not available.'),
      );
      return;
    }
    final isRoot = m['root'] == true;
    final raw = m['items'];
    final items = <RemoteEntry>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final name = item['n'];
        if (name is! String) continue;
        final p = item['p'];
        final size = item['s'];
        final modified = item['m'];
        items.add(
          RemoteEntry(
            name: name,
            isDir: item['d'] == true,
            size: size is int ? size : 0,
            modified: modified is int ? modified : 0,
            path: p is String ? p : null,
          ),
        );
      }
    }
    items.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final parent = m['parent'];
    waiting.complete(
      RemoteListing(
        ok: true,
        path: m['path'] is String ? m['path'] as String : '',
        parent: parent is String ? parent : null,
        isRoot: isRoot,
        items: items,
      ),
    );
  }

  // ---- Incoming messages ---------------------------------------------------

  void _onMessage(Map<String, dynamic> m) {
    final type = m['t'];
    if (type is! String) return;
    switch (type) {
      case 'fm-ring':
        unawaited(_onRing(m));
      case 'fm-ring-r':
        if (m['ok'] != true) {
          peerRinging = false;
          final why = m['why'];
          findNotice = why is String ? why : 'The phone did not ring.';
        } else {
          findNotice = 'The phone is ringing.';
        }
        notifyListeners();
      case 'fm-info':
        unawaited(_sendInfo());
      case 'fm-info-r':
        final pct = m['pct'];
        peerBattery = pct is int && pct >= 0 ? pct : null;
        peerCharging = m['charging'] == true;
        if (m['ringing'] is bool) peerRinging = m['ringing'] as bool;
        findBusy = false;
        notifyListeners();
      case 'fb-list':
        unawaited(_onList(m));
      case 'fb-list-r':
        _onListed(m);
      case 'fb-get':
        unawaited(_onGet(m));
      case 'fb-no':
        final why = m['why'];
        findNotice = why is String ? why : 'The file could not be sent.';
        notifyListeners();
    }
  }
}
