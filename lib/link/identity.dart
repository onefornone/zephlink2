import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto_util.dart';

/// Who this device is: a short id and an Ed25519 key pair.
/// The private key never leaves this device.
class Identity {
  Identity._(this.id, this.keyPair, this.publicKey);

  final String id;
  final SimpleKeyPair keyPair;
  final List<int> publicKey;

  /// Makes a brand new identity (also used by tests).
  static Future<Identity> generate() async {
    final seed = randomBytes(32);
    return _fromSeed(hex(randomBytes(8)), seed);
  }

  /// Loads the saved identity, or makes and saves one on first run.
  ///
  /// Note: the key is kept in the app's private storage. A later phase
  /// moves it to the system's secure key store.
  static Future<Identity> loadOrCreate(SharedPreferences prefs) async {
    final savedId = prefs.getString('zl_id');
    final savedSeed = prefs.getString('zl_seed');
    if (savedId != null && savedSeed != null) {
      try {
        return await _fromSeed(savedId, unb64(savedSeed));
      } catch (_) {
        // Fall through and make a new identity.
      }
    }
    final seed = randomBytes(32);
    final id = hex(randomBytes(8));
    await prefs.setString('zl_id', id);
    await prefs.setString('zl_seed', b64(seed));
    return _fromSeed(id, seed);
  }

  static Future<Identity> _fromSeed(String id, List<int> seed) async {
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return Identity._(id, keyPair, publicKey.bytes);
  }
}
