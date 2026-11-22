import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// Turns what the person typed into a web-socket address for the relay, or
/// null when it cannot be one. "my-relay.workers.dev" becomes
/// "wss://my-relay.workers.dev".
String? cleanRelayUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('https://')) {
    text = 'wss://${text.substring(8)}';
  } else if (text.startsWith('http://')) {
    text = 'ws://${text.substring(7)}';
  } else if (!text.startsWith('wss://') && !text.startsWith('ws://')) {
    text = 'wss://$text';
  }
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) return null;
  return text;
}

/// The meeting-room name on the relay for two paired devices. It is made
/// from both device ids and the secret they share, so nobody else can work
/// it out, and the secret itself never leaves the two devices.
Future<String> relayRoomId(String idA, String idB, String key) async {
  final ids = <String>[idA, idB]..sort();
  final hash = await Sha256().hash(
    utf8.encode('zephlink-room-v1|${ids[0]}|${ids[1]}|$key'),
  );
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Opens a connection to the relay room. The device with the smaller id
/// "dials" (the relay only lets it in when the other one is waiting); the
/// other one "waits" in the room until it arrives.
Future<WebSocket> connectRelay(
  String baseUrl,
  String room, {
  required bool dial,
}) {
  return WebSocket.connect(
    '$baseUrl/room/$room?role=${dial ? 'dial' : 'wait'}',
    compression: CompressionOptions.compressionOff,
  ).timeout(const Duration(seconds: 10));
}
