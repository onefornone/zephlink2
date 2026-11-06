import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'secure_session.dart';

/// Finds other Zephlink devices by asking every address on the local
/// network "are you Zephlink?". This works even when the router blocks
/// broadcasts, because it only needs normal connections.
class SubnetScanner {
  /// True for home and hotspot network addresses.
  static bool isPrivate(String address) {
    final p = address.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((x) => x == null)) return false;
    final a = p[0]!;
    final b = p[1]!;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  /// Scans the /24 network (254 addresses) of each of [addresses].
  static Future<List<NearbyDevice>> scan({
    required String selfId,
    required List<String> addresses,
    int port = defaultLinkPort,
  }) async {
    final targets = <String>{};
    for (final own in addresses) {
      if (!isPrivate(own)) continue;
      final parts = own.split('.');
      for (var i = 1; i <= 254; i++) {
        final host = '${parts[0]}.${parts[1]}.${parts[2]}.$i';
        if (host != own) targets.add(host);
      }
    }
    if (targets.isEmpty) return const [];

    final found = <NearbyDevice>[];
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 700)
      ..idleTimeout = const Duration(seconds: 1);

    Future<void> probe(String host) async {
      try {
        final request = await client
            .getUrl(Uri.parse('http://$host:$port$linkPath/info'))
            .timeout(const Duration(milliseconds: 1500));
        final response =
            await request.close().timeout(const Duration(milliseconds: 1500));
        if (response.statusCode != 200) {
          await response.drain<void>();
          return;
        }
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(milliseconds: 1500));
        final json = jsonDecode(body);
        if (json is! Map<String, dynamic> || json['z'] != 1) return;
        final id = json['id'];
        final name = json['name'];
        final listenPort = json['port'];
        if (id is! String || id.length != 16 || id == selfId) return;
        if (name is! String || listenPort is! int || listenPort <= 0) return;
        found.add(
          NearbyDevice(
            id: id,
            name: name.length > 60 ? name.substring(0, 60) : name,
            platform: (json['plat'] as String?) ?? 'other',
            address: InternetAddress(host),
            port: listenPort,
            lastSeen: DateTime.now(),
          ),
        );
      } catch (_) {
        // Nothing Zephlink at this address.
      }
    }

    final list = targets.toList();
    const batch = 48;
    for (var i = 0; i < list.length; i += batch) {
      final end = i + batch > list.length ? list.length : i + batch;
      await Future.wait(list.sublist(i, end).map(probe));
    }
    client.close(force: true);
    return found;
  }
}
