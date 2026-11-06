import 'dart:convert';
import 'dart:math';

final Random _rng = Random.secure();

/// Cryptographically secure random bytes.
List<int> randomBytes(int count) =>
    List<int>.generate(count, (_) => _rng.nextInt(256));

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String b64(List<int> bytes) => base64Encode(bytes);

/// Decodes a base64 field from a message. Throws [FormatException] if it
/// is missing or not text.
List<int> unb64(Object? value) {
  if (value is! String) throw const FormatException('Missing field');
  return base64Decode(value);
}

/// A random 6-digit pairing code.
String randomPin() => _rng.nextInt(1000000).toString().padLeft(6, '0');

/// Compares two byte lists without stopping at the first difference.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
