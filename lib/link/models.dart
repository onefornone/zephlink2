import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'crypto_util.dart';

/// "android" or "windows" (used in messages and for icons).
String get platformName {
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  return 'other';
}

/// A readable name for this device until the person renames it.
String defaultDeviceName() {
  if (Platform.isAndroid) return 'Android phone';
  final host = Platform.localHostname;
  return host.isEmpty ? 'My PC' : host;
}

/// A device you have paired with. Its public key is pinned: only the
/// device holding the matching private key is accepted as this device.
class PairedPeer {
  PairedPeer({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
  });

  final String id;
  String name;
  final String platform;
  final List<int> publicKey;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'plat': platform,
        'key': b64(publicKey),
      };

  static PairedPeer? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return PairedPeer(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: (json['plat'] as String?) ?? 'other',
        publicKey: unb64(json['key']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A device seen on the Wi-Fi (paired or not).
class NearbyDevice {
  NearbyDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String platform;
  final InternetAddress address;
  final int port;
  final DateTime lastSeen;
}

/// A short time during which this device accepts new pairings.
class PairingWindow {
  PairingWindow(this.pin)
      : expires = DateTime.now().add(const Duration(minutes: 5));

  final String pin;
  final DateTime expires;
  int failures = 0;
  bool used = false;

  /// Closed after 5 minutes, one success, or 3 wrong codes.
  bool get open => !used && failures < 3 && DateTime.now().isBefore(expires);

  Duration get remaining {
    final left = expires.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

/// A question for the person: "Allow this device to pair?".
class PairRequest {
  PairRequest({
    required this.peerName,
    required this.platform,
    required this.incoming,
    this.reconnecting = false,
    this.verificationCode,
  });

  final String peerName;
  final String platform;
  final String? verificationCode;

  /// True when the other device initiated the pairing request.
  final bool incoming;
  final bool reconnecting;

  final Completer<bool> answer = Completer<bool>();
}

/// The answer to a [ConsentRequest]: yes or no, and whether the optional tick
/// box was ticked.
class ConsentAnswer {
  const ConsentAnswer(this.allow, this.option);

  final bool allow;
  final bool option;
}

/// A question for the person, such as "Let this phone see your screen?".
class ConsentRequest {
  ConsentRequest({
    required this.title,
    required this.message,
    this.allowLabel = 'Allow',
    this.optionLabel,
    this.platform,
  });

  final String title;
  final String message;
  final String allowLabel;

  /// Text of an optional tick box (for example "Also allow control").
  final String? optionLabel;
  final String? platform;

  final Completer<ConsentAnswer> answer = Completer<ConsentAnswer>();
}

/// One line in the recent activity list.
class ActivityEntry {
  ActivityEntry(this.text, this.kind) : time = DateTime.now();

  final String text;

  /// "send", "receive" or "link" (used to pick an icon).
  final String kind;
  final DateTime time;
}

/// Text received from the other device's clipboard.
class ClipEntry {
  ClipEntry(this.text, this.from) : time = DateTime.now();

  final String text;
  final String from;
  final DateTime time;
}

class ForwardedNotification {
  const ForwardedNotification({
    required this.id,
    required this.eventId,
    required this.app,
    required this.title,
    required this.text,
    required this.canReply,
    required this.postedAt,
  });

  final String id;
  final String eventId;
  final String app;
  final String title;
  final String text;
  final bool canReply;
  final DateTime postedAt;
}

/// What the Home screen shows.
enum LinkStatus { unpaired, searching, connecting, connected }

/// The list of paired devices, saved on this device.
class PeerStore {
  /// With [prefs] null the list lives only in memory (used by tests).
  PeerStore(this._prefs) {
    final raw = _prefs?.getString('zl_peers');
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            final peer = PairedPeer.fromJson(item);
            if (peer != null) _peers[peer.id] = peer;
          }
        }
      } catch (_) {
        // A damaged list is treated as empty.
      }
    }
    _lastId = _prefs?.getString('zl_last');
  }

  final SharedPreferences? _prefs;
  final Map<String, PairedPeer> _peers = {};
  String? _lastId;

  List<PairedPeer> get all => _peers.values.toList();
  PairedPeer? byId(String id) => _peers[id];

  /// The device you were last connected to.
  String? get lastId => _lastId;

  Future<void> put(PairedPeer peer) async {
    _peers[peer.id] = peer;
    await _save();
  }

  Future<void> remove(String id) async {
    _peers.remove(id);
    if (_lastId == id) _lastId = null;
    await _save();
  }

  Future<void> setLast(String id) async {
    _lastId = id;
    await _prefs?.setString('zl_last', id);
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      'zl_peers',
      jsonEncode(_peers.values.map((p) => p.toJson()).toList()),
    );
    final last = _lastId;
    if (last == null) {
      await prefs.remove('zl_last');
    } else {
      await prefs.setString('zl_last', last);
    }
  }
}
