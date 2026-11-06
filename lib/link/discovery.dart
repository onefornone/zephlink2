import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Every device shouts "I'm here" on the local Wi-Fi every 2 seconds and
/// listens for the others. No internet and no extra packages are needed.
const int discoveryPort = 47474;

class Discovery {
  RawDatagramSocket? _socket;
  Timer? _timer;
  String Function()? _beacon;
  final StreamController<NearbyDevice> _found =
      StreamController<NearbyDevice>.broadcast();

  /// Fires each time another Zephlink device is heard.
  Stream<NearbyDevice> get found => _found.stream;

  /// [beacon] returns the JSON text to announce (id, name, platform, port).
  Future<void> start(String Function() beacon) async {
    _beacon = beacon;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen(_onEvent, onError: (Object _) {});
      _socket = socket;
    } catch (_) {
      // Another program may hold the port. Pairing by IP address still works.
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _send());
    _send();
  }

  Future<void> _send() async {
    final socket = _socket;
    final beacon = _beacon;
    if (socket == null || beacon == null) return;
    final data = utf8.encode(beacon());
    final targets = <String>{'255.255.255.255'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final parts = address.address.split('.');
          if (parts.length == 4 && !address.isLoopback) {
            targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (_) {
      // Use the general broadcast address only.
    }
    for (final target in targets) {
      try {
        socket.send(data, InternetAddress(target), discoveryPort);
      } catch (_) {
        // This network may not allow broadcasts. Try the next one.
      }
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    try {
      final json = jsonDecode(utf8.decode(datagram.data));
      if (json is! Map<String, dynamic> || json['z'] != 1) return;
      final id = json['id'];
      final name = json['name'];
      final port = json['port'];
      if (id is! String || name is! String || port is! int || port <= 0) {
        return;
      }
      if (id.length != 16 || name.length > 60) return;
      _found.add(
        NearbyDevice(
          id: id,
          name: name,
          platform: (json['plat'] as String?) ?? 'other',
          address: datagram.address,
          port: port,
          lastSeen: DateTime.now(),
        ),
      );
    } catch (_) {
      // Not one of ours. Ignore it.
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    if (!_found.isClosed) _found.close();
  }
}
