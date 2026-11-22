import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../link/models.dart';
import '../link/secure_session.dart';
import '../platform/android_phone.dart';

/// One conversation in the phone's text messages.
class SmsConversation {
  const SmsConversation({
    required this.thread,
    required this.address,
    required this.name,
    required this.snippet,
    required this.date,
    required this.sentByMe,
    required this.unread,
  });

  final int thread;
  final String address;
  final String name;
  final String snippet;
  final DateTime date;
  final bool sentByMe;
  final bool unread;

  String get title => name.isNotEmpty ? name : address;
}

/// One text message.
class SmsMessage {
  const SmsMessage({
    required this.id,
    required this.body,
    required this.date,
    required this.sent,
  });

  final int id;
  final String body;
  final DateTime date;
  final bool sent;
}

/// A call that is ringing on the phone.
class CallInfo {
  const CallInfo({required this.number, required this.name});

  final String number;
  final String name;

  String get title => name.isNotEmpty ? name : (number.isEmpty ? 'Unknown number' : number);
}

/// Texts and calls from the phone, shown on the PC.
///
/// The phone must agree: it is asked once per link (or never, if its owner
/// turns on "always allow"), and Android asks for its own permissions too.
/// Only the PC's requests are answered; nothing is sent until the phone has
/// said yes.
class PhoneService extends ChangeNotifier {
  PhoneService({
    required this.ask,
    required this.peerName,
    required this.peerPlatform,
    required this.notice,
    SharedPreferences? prefs,
  })  : _prefs = prefs,
        alwaysAllow = prefs?.getBool('zl_phone_always') ?? false,
        autoOpen = prefs?.getBool('zl_phone_auto') ?? true {
    if (AndroidPhone.supported) {
      AndroidPhone.bind();
      AndroidPhone.onEvent = _onNativeEvent;
    }
  }

  final SharedPreferences? _prefs;
  final Future<ConsentAnswer> Function(ConsentRequest request) ask;
  final String Function() peerName;
  final String? Function() peerPlatform;
  final Future<void> Function(String title, String body) notice;

  /// Phone: skip the question and let linked devices see texts and calls.
  bool alwaysAllow;

  /// PC: ask the phone for texts and calls as soon as the link is up.
  bool autoOpen;

  SecureSession? _session;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _openTimer;

  // Phone side.
  bool _granted = false;
  Future<bool>? _asking;

  // PC side.
  bool phoneOpen = false;
  bool smsAllowed = false;
  bool callsAllowed = false;
  String? openNote;
  bool opening = false;
  bool _triedOpen = false;
  List<SmsConversation> conversations = const [];
  bool loadingConversations = false;
  String? conversationsNote;
  int unreadTexts = 0;
  CallInfo? incomingCall;
  String? callNote;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  // Changes whenever a text arrives, so open conversations can refresh.
  int textTick = 0;

  bool get connected => _session != null;

  Future<void> setAlwaysAllow(bool value) async {
    alwaysAllow = value;
    notifyListeners();
    await _prefs?.setBool('zl_phone_always', value);
    if (value && AndroidPhone.supported) {
      await _askAndroidPermissions();
      _granted = true;
      notifyListeners();
    }
  }

  Future<void> setAutoOpen(bool value) async {
    autoOpen = value;
    notifyListeners();
    await _prefs?.setBool('zl_phone_auto', value);
    if (value && connected && !phoneOpen) unawaited(open());
  }

  // ---- Link life ---------------------------------------------------------

  void attach(SecureSession session) {
    detach();
    _session = session;
    _sub = session.messages.listen(_onMessage);
    if (!Platform.isAndroid && autoOpen) {
      _openTimer = Timer(const Duration(seconds: 3), () {
        if (peerPlatform() == 'android') unawaited(open());
      });
    }
    notifyListeners();
  }

  void detach() {
    _openTimer?.cancel();
    _openTimer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _session = null;
    _granted = false;
    _asking = null;
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) {
        waiting.complete(<String, dynamic>{'ok': false, 'why': 'The link closed.'});
      }
    }
    _pending.clear();
    phoneOpen = false;
    smsAllowed = false;
    callsAllowed = false;
    opening = false;
    _triedOpen = false;
    openNote = null;
    conversations = const [];
    incomingCall = null;
    unreadTexts = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    if (AndroidPhone.onEvent == _onNativeEvent) AndroidPhone.onEvent = null;
    super.dispose();
  }

  Future<void> _send(Map<String, dynamic> message) async {
    final session = _session;
    if (session == null) return;
    await session.send(message);
  }

  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> message, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    if (_session == null) {
      return <String, dynamic>{'ok': false, 'why': 'Connect a device first.'};
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    await _send(<String, dynamic>{...message, 'id': id});
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        return <String, dynamic>{
          'ok': false,
          'why': 'No answer. Check the phone.',
        };
      },
    );
  }

  void _answerPending(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is! int) return;
    final waiting = _pending.remove(id);
    if (waiting != null && !waiting.isCompleted) waiting.complete(m);
  }

  // ---- PC side: asking the phone ---------------------------------------------

  /// Asks the phone to share texts and calls. The phone may ask its owner.
  Future<void> open() async {
    if (_session == null || opening) return;
    opening = true;
    openNote = null;
    _triedOpen = true;
    notifyListeners();
    final reply = await _request(
      <String, dynamic>{'t': 'ph-open'},
      timeout: const Duration(seconds: 120),
    );
    opening = false;
    if (reply['ok'] == true) {
      phoneOpen = true;
      smsAllowed = reply['sms'] == true;
      callsAllowed = reply['calls'] == true;
      openNote = null;
      if (smsAllowed) unawaited(loadConversations());
    } else {
      phoneOpen = false;
      final why = reply['why'];
      openNote = why is String ? why : 'The phone did not allow it.';
    }
    notifyListeners();
  }

  bool get triedOpen => _triedOpen;

  Future<void> loadConversations() async {
    if (_session == null) return;
    loadingConversations = true;
    conversationsNote = null;
    notifyListeners();
    final reply = await _request(<String, dynamic>{'t': 'ph-convs'});
    loadingConversations = false;
    if (reply['ok'] == true && reply['items'] is List) {
      conversations = [
        for (final item in reply['items'] as List<dynamic>)
          if (item is Map<String, dynamic>) _conversation(item),
      ];
    } else {
      final why = reply['why'];
      conversationsNote = why is String ? why : 'Could not load messages.';
    }
    notifyListeners();
  }

  SmsConversation _conversation(Map<String, dynamic> m) {
    final thread = m['t'];
    final date = m['d'];
    return SmsConversation(
      thread: thread is int ? thread : 0,
      address: m['a'] is String ? m['a'] as String : '',
      name: m['n'] is String ? m['n'] as String : '',
      snippet: m['s'] is String ? m['s'] as String : '',
      date: DateTime.fromMillisecondsSinceEpoch(date is int ? date : 0),
      sentByMe: m['o'] == true,
      unread: m['u'] == true,
    );
  }

  /// Gives back the messages of one conversation, oldest first, or null.
  Future<List<SmsMessage>?> loadThread(int thread) async {
    final reply = await _request(<String, dynamic>{'t': 'ph-thread', 't2': thread});
    if (reply['ok'] != true || reply['items'] is! List) return null;
    final out = <SmsMessage>[];
    for (final item in reply['items'] as List<dynamic>) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['i'];
      final date = item['d'];
      out.add(
        SmsMessage(
          id: id is int ? id : 0,
          body: item['b'] is String ? item['b'] as String : '',
          date: DateTime.fromMillisecondsSinceEpoch(date is int ? date : 0),
          sent: item['o'] == true,
        ),
      );
    }
    return out;
  }

  /// Sends a text from the phone. Null when sent, else a short reason.
  Future<String?> sendText(String to, String text) async {
    final reply = await _request(
      <String, dynamic>{'t': 'ph-send', 'to': to, 'text': text},
    );
    if (reply['ok'] == true) return null;
    final why = reply['why'];
    return why is String ? why : 'Could not send.';
  }

  Future<void> clearUnread() async {
    if (unreadTexts == 0) return;
    unreadTexts = 0;
    notifyListeners();
  }

  /// Answers or declines the ringing call. Null when done, else why not.
  Future<String?> callAction(bool answer) async {
    final reply = await _request(
      <String, dynamic>{'t': 'ph-call-do', 'act': answer ? 'answer' : 'reject'},
      timeout: const Duration(seconds: 15),
    );
    if (reply['ok'] == true) {
      incomingCall = null;
      notifyListeners();
      return null;
    }
    final why = reply['why'];
    return why is String ? why : 'Could not do that.';
  }

  void dismissCall() {
    if (incomingCall == null) return;
    incomingCall = null;
    notifyListeners();
  }

  // ---- Phone side: answering ---------------------------------------------------

  Future<void> _askAndroidPermissions() async {
    final perms = await AndroidPhone.perms();
    if (perms['sms'] != true) await AndroidPhone.request('sms');
    if (perms['calls'] != true) await AndroidPhone.request('calls');
    if (perms['contacts'] != true) await AndroidPhone.request('contacts');
  }

  Future<bool> _allowed() {
    if (_granted) return Future<bool>.value(true);
    final running = _asking;
    if (running != null) return running;
    final next = _askOwner();
    _asking = next;
    return next.whenComplete(() => _asking = null);
  }

  Future<bool> _askOwner() async {
    if (alwaysAllow) {
      _granted = true;
      return true;
    }
    final answer = await ask(
      ConsentRequest(
        title: 'Let ${peerName()} see your texts and calls?',
        message: '${peerName()} will be able to read your text messages, send '
            'texts from your number, and see, answer or decline incoming '
            'calls. This ends when the link ends.',
        allowLabel: 'Allow',
        optionLabel: 'Do not ask again',
        platform: 'android',
      ),
    );
    if (!answer.allow) return false;
    _granted = true;
    if (answer.option) await setAlwaysAllow(true);
    return true;
  }

  Future<void> _onOpen(Map<String, dynamic> m) async {
    final id = m['id'];
    Future<void> fail(String why) => _send(
          <String, dynamic>{'t': 'ph-open-r', 'id': id, 'ok': false, 'why': why},
        );
    if (!AndroidPhone.supported) {
      await fail('Only a phone can share texts and calls.');
      return;
    }
    if (!await _allowed()) {
      await fail('${peerName()} was not allowed to see texts and calls.');
      return;
    }
    await _askAndroidPermissions();
    final perms = await AndroidPhone.perms();
    await _send(<String, dynamic>{
      't': 'ph-open-r',
      'id': id,
      'ok': true,
      'sms': perms['sms'] == true,
      'calls': perms['calls'] == true,
    });
  }

  Future<void> _onConversations(Map<String, dynamic> m) async {
    final id = m['id'];
    Future<void> reply(Map<String, dynamic> extra) => _send(
          <String, dynamic>{'t': 'ph-convs-r', 'id': id, ...extra},
        );
    if (!_granted || !AndroidPhone.supported) {
      await reply(<String, dynamic>{'ok': false, 'why': 'Not allowed on the phone.'});
      return;
    }
    final perms = await AndroidPhone.perms();
    if (perms['sms'] != true) {
      await reply(<String, dynamic>{
        'ok': false,
        'why': 'Text messages are not allowed for Zephlink on the phone.',
      });
      return;
    }
    try {
      final items = await AndroidPhone.conversations(60);
      await reply(<String, dynamic>{'ok': true, 'items': items});
    } catch (_) {
      await reply(<String, dynamic>{'ok': false, 'why': 'Could not read the messages.'});
    }
  }

  Future<void> _onThread(Map<String, dynamic> m) async {
    final id = m['id'];
    Future<void> reply(Map<String, dynamic> extra) => _send(
          <String, dynamic>{'t': 'ph-thread-r', 'id': id, ...extra},
        );
    final thread = m['t2'];
    if (!_granted || !AndroidPhone.supported || thread is! int) {
      await reply(<String, dynamic>{'ok': false, 'why': 'Not allowed on the phone.'});
      return;
    }
    try {
      final items = await AndroidPhone.thread(thread, 150);
      await reply(<String, dynamic>{'ok': true, 'items': items});
    } catch (_) {
      await reply(<String, dynamic>{'ok': false, 'why': 'Could not read the messages.'});
    }
  }

  Future<void> _onSend(Map<String, dynamic> m) async {
    final id = m['id'];
    Future<void> reply(bool ok, [String? why]) => _send(
          <String, dynamic>{'t': 'ph-send-r', 'id': id, 'ok': ok, 'why': why},
        );
    final to = m['to'];
    final text = m['text'];
    if (!_granted || !AndroidPhone.supported) {
      await reply(false, 'Not allowed on the phone.');
      return;
    }
    if (to is! String || text is! String || text.isEmpty || text.length > 1000) {
      await reply(false, 'That message cannot be sent.');
      return;
    }
    final why = await AndroidPhone.send(to, text);
    await reply(why == null, why);
  }

  Future<void> _onCallDo(Map<String, dynamic> m) async {
    final id = m['id'];
    Future<void> reply(bool ok, [String? why]) => _send(
          <String, dynamic>{'t': 'ph-call-r', 'id': id, 'ok': ok, 'why': why},
        );
    if (!_granted || !AndroidPhone.supported) {
      await reply(false, 'Not allowed on the phone.');
      return;
    }
    final why =
        m['act'] == 'answer' ? await AndroidPhone.answer() : await AndroidPhone.reject();
    await reply(why == null, why);
  }

  /// A text arrived or a call changed on this phone: tell the PC.
  void _onNativeEvent(Map<String, dynamic> event) {
    if (!_granted || _session == null) return;
    if (event['kind'] == 'sms') {
      unawaited(_send(<String, dynamic>{
        't': 'ph-sms',
        'a': event['a'],
        'n': event['n'],
        'b': event['b'],
        'd': event['d'],
      }));
    } else if (event['kind'] == 'call') {
      unawaited(_send(<String, dynamic>{
        't': 'ph-call',
        'st': event['st'],
        'a': event['a'],
        'n': event['n'],
      }));
    }
  }

  // ---- Incoming messages -----------------------------------------------------

  void _onMessage(Map<String, dynamic> m) {
    final type = m['t'];
    if (type is! String) return;
    switch (type) {
      case 'ph-open':
        unawaited(_onOpen(m));
      case 'ph-convs':
        unawaited(_onConversations(m));
      case 'ph-thread':
        unawaited(_onThread(m));
      case 'ph-send':
        unawaited(_onSend(m));
      case 'ph-call-do':
        unawaited(_onCallDo(m));
      case 'ph-open-r' || 'ph-convs-r' || 'ph-thread-r' || 'ph-send-r' || 'ph-call-r':
        _answerPending(m);
      case 'ph-sms':
        _onText(m);
      case 'ph-call':
        _onCall(m);
    }
  }

  void _onText(Map<String, dynamic> m) {
    if (!phoneOpen) return;
    unreadTexts++;
    textTick++;
    final name = m['n'] is String && (m['n'] as String).isNotEmpty
        ? m['n'] as String
        : (m['a'] is String ? m['a'] as String : 'New text');
    final body = m['b'] is String ? m['b'] as String : '';
    unawaited(notice(name, body.length > 160 ? body.substring(0, 160) : body));
    notifyListeners();
    unawaited(loadConversations());
  }

  void _onCall(Map<String, dynamic> m) {
    if (!phoneOpen) return;
    final state = m['st'];
    if (state == 'ringing') {
      final number = m['a'] is String ? m['a'] as String : '';
      final name = m['n'] is String ? m['n'] as String : '';
      final previous = incomingCall;
      incomingCall = CallInfo(
        number: number.isEmpty ? (previous?.number ?? '') : number,
        name: name.isEmpty ? (previous?.name ?? '') : name,
      );
      if (previous == null) {
        unawaited(notice('Incoming call', incomingCall!.title));
      }
      notifyListeners();
    } else {
      if (incomingCall != null) {
        incomingCall = null;
        notifyListeners();
      }
    }
  }
}
