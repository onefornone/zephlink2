import 'dart:io';

/// One-tap actions on this Windows PC that a paired phone may start after the
/// owner allowed control. Only the actions listed here exist. Nothing a
/// phone sends is ever run as a command line.
class WindowsActions {
  /// Actions that switch the PC off or end the session. The owner is asked
  /// again before each of these.
  static bool isPower(String action) =>
      action == 'shutdown' || action == 'restart' || action == 'signout';

  static String label(String action) {
    switch (action) {
      case 'shutdown':
        return 'shut down';
      case 'restart':
        return 'restart';
      case 'signout':
        return 'sign out of';
    }
    return action;
  }

  /// Runs [action]. Returns null when it started, or a short reason.
  static Future<String?> run(String action, {String? argument}) async {
    if (!Platform.isWindows) return 'This is not a Windows PC.';
    try {
      switch (action) {
        case 'lock':
          return _start('rundll32.exe', ['user32.dll,LockWorkStation']);
        case 'sleep':
          return _start('rundll32.exe', ['powrprof.dll,SetSuspendState', '0,1,0']);
        case 'shutdown':
          return _start('shutdown.exe', ['/s', '/t', '30']);
        case 'restart':
          return _start('shutdown.exe', ['/r', '/t', '30']);
        case 'signout':
          return _start('shutdown.exe', ['/l']);
        case 'cancelpower':
          return _start('shutdown.exe', ['/a']);
        case 'explorer':
          return _start('explorer.exe', []);
        case 'downloads':
          return _start('explorer.exe', ['shell:Downloads']);
        case 'calc':
          return _start('calc.exe', []);
        case 'notepad':
          return _start('notepad.exe', []);
        case 'taskmgr':
          return _start('taskmgr.exe', []);
        case 'settings':
          return _start('explorer.exe', ['ms-settings:']);
        case 'url':
          return _openUrl(argument);
      }
    } catch (_) {
      return 'Windows would not do that.';
    }
    return 'Unknown action.';
  }

  static Future<String?> _start(String program, List<String> args) async {
    await Process.start(program, args, mode: ProcessStartMode.detached);
    return null;
  }

  static Future<String?> _openUrl(String? text) async {
    final raw = text?.trim();
    if (raw == null || raw.isEmpty) return 'No web address.';
    if (raw.length > 2000) return 'That address is too long.';
    final uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'Only http and https addresses work.';
    }
    return _start('rundll32.exe', ['url.dll,FileProtocolHandler', uri.toString()]);
  }
}
