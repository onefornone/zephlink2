import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Makes sure only one copy of Zephlink runs on Windows.
///
/// The first copy listens on a private port that only this computer can
/// reach. A second copy (for example from "Send with Zephlink" in Explorer)
/// hands its arguments to the first copy and quits.
class SingleInstance {
  static const int _port = 47476;
  static ServerSocket? _server;

  /// Returns true when this copy should keep running. When another copy is
  /// already running, [args] are passed to it and false is returned.
  /// [onSecondStart] is called in the running copy with the other copy's
  /// arguments.
  static Future<bool> acquire(
    List<String> args,
    void Function(List<String> args) onSecondStart,
  ) async {
    if (!Platform.isWindows) return true;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _port,
      );
      _server = server;
      server.listen(
        (socket) => unawaited(_read(socket, onSecondStart)),
        onError: (Object _) {},
      );
      return true;
    } on SocketException {
      // Something already listens here. Hand over our arguments.
    } catch (_) {
      return true;
    }
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(seconds: 2),
      );
      socket.write(jsonEncode(<String, dynamic>{'zephlink': 1, 'args': args}));
      await socket.flush();
      await socket.close();
      return false;
    } catch (_) {
      // The port is used by something that is not Zephlink. Just run.
      return true;
    }
  }

  static Future<void> _read(
    Socket socket,
    void Function(List<String> args) onSecondStart,
  ) async {
    try {
      final text = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 3));
      if (text.length > 100000) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic> || decoded['zephlink'] != 1) return;
      final raw = decoded['args'];
      if (raw is! List) return;
      onSecondStart(raw.whereType<String>().toList());
    } catch (_) {
      // Not from Zephlink, or cut short. Ignore it.
    } finally {
      socket.destroy();
    }
  }
}
