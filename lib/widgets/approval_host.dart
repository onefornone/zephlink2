import 'package:flutter/material.dart';

import '../link/link_controller.dart';

/// Shows the "Allow this device to pair?" question on top of whatever
/// screen is open, whenever the link asks for it.
class ApprovalHost extends StatefulWidget {
  const ApprovalHost({
    super.key,
    required this.navigatorKey,
    required this.link,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final LinkController link;
  final Widget child;

  @override
  State<ApprovalHost> createState() => _ApprovalHostState();
}

class _ApprovalHostState extends State<ApprovalHost> {
  bool _showing = false;
  BuildContext? _dialogContext;
  bool _consentShowing = false;
  BuildContext? _consentContext;
  bool _consentClosing = false;
  bool _pairClosing = false;

  static const AnimationStyle _quick = AnimationStyle(
    duration: Duration(milliseconds: 120),
    reverseDuration: Duration(milliseconds: 60),
  );

  @override
  void initState() {
    super.initState();
    widget.link.addListener(_check);
  }

  @override
  void dispose() {
    widget.link.removeListener(_check);
    super.dispose();
  }

  /// Shows questions such as "Let this phone see your screen?".
  void _checkConsent() {
    final request = widget.link.pendingConsent;
    if (request == null) {
      final dialog = _consentContext;
      if (_consentShowing &&
          !_consentClosing &&
          dialog != null &&
          dialog.mounted) {
        _consentClosing = true;
        Navigator.of(dialog).pop();
      }
      return;
    }
    if (_consentShowing) return;
    _consentShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = widget.navigatorKey.currentContext;
      if (context == null || !context.mounted) {
        _consentShowing = false;
        widget.link.answerConsent(false, false);
        return;
      }
      var option = false;
      _consentClosing = false;
      var answered = false;
      void answer(BuildContext dialogContext, bool allow) {
        if (answered) return;
        answered = true;
        _consentClosing = true;
        // Answer first, then close, so the other device is told straight away.
        widget.link.answerConsent(allow, allow && option);
        if (dialogContext.mounted) Navigator.of(dialogContext).pop(allow);
      }

      final allow = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        animationStyle: _quick,
        builder: (dialogContext) {
          _consentContext = dialogContext;
          return StatefulBuilder(
            builder: (context, setState) {
              final optionLabel = request.optionLabel;
              return AlertDialog(
                icon: Icon(
                  request.platform == 'android'
                      ? Icons.smartphone_rounded
                      : Icons.desktop_windows_rounded,
                ),
                title: Text(request.title),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(request.message),
                    if (optionLabel != null)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: option,
                        title: Text(optionLabel),
                        onChanged: (value) =>
                            setState(() => option = value ?? false),
                      ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => answer(dialogContext, false),
                    child: const Text('Deny'),
                  ),
                  FilledButton(
                    onPressed: () => answer(dialogContext, true),
                    child: Text(request.allowLabel),
                  ),
                ],
              );
            },
          );
        },
      );
      _consentContext = null;
      if (!answered) {
        answered = true;
        widget.link.answerConsent(allow == true, allow == true && option);
      }
      _consentShowing = false;
      _checkConsent();
    });
  }

  void _check() {
    _checkConsent();
    final request = widget.link.pendingRequest;
    if (request == null) {
      // The question timed out or was answered elsewhere: close the dialog.
      final dialog = _dialogContext;
      if (_showing && !_pairClosing && dialog != null && dialog.mounted) {
        _pairClosing = true;
        Navigator.of(dialog).pop();
      }
      return;
    }
    if (_showing) return;
    _showing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = widget.navigatorKey.currentContext;
      if (context == null || !context.mounted) {
        _showing = false;
        widget.link.answerRequest(false);
        return;
      }
      _pairClosing = false;
      var answered = false;
      void answer(BuildContext dialogContext, bool allow) {
        if (answered) return;
        answered = true;
        _pairClosing = true;
        widget.link.answerRequest(allow);
        if (dialogContext.mounted) Navigator.of(dialogContext).pop(allow);
      }

      final allow = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        animationStyle: _quick,
        builder: (dialogContext) {
          _dialogContext = dialogContext;
          return AlertDialog(
            icon: Icon(
              request.platform == 'android'
                  ? Icons.smartphone_rounded
                  : Icons.desktop_windows_rounded,
            ),
            title: Text(
              request.reconnecting
                  ? request.incoming
                      ? 'Approve connection from ${request.peerName}?'
                      : 'Approve connection to ${request.peerName}?'
                  : request.incoming
                      ? 'Allow ${request.peerName} to pair?'
                      : 'Pair with ${request.peerName}?',
            ),
            content: request.verificationCode == null
                ? Text(
                    request.reconnecting
                        ? 'A previously paired device is requesting a connection. '
                            'Approve only if you initiated it.'
                        : request.incoming
                            ? '"${request.peerName}" typed your code and wants to link with this device. '
                                'Only allow it if that was you.'
                            : 'The code matched. Link this device with "${request.peerName}"? '
                                'You also approve on that device.',
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Compare this code with the one on the other device. '
                        'Approve only if the codes match and you recognize the request.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        request.verificationCode!,
                        style: Theme.of(dialogContext)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              letterSpacing: 4,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${request.reconnecting ? 'Connect to' : 'Pair with'} '
                            '${request.peerName}?',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
            actions: [
              TextButton(
                onPressed: () => answer(dialogContext, false),
                child: const Text('Deny'),
              ),
              FilledButton(
                onPressed: () => answer(dialogContext, true),
                child: Text(
                  request.reconnecting
                      ? 'Approve connection'
                      : request.incoming
                          ? 'Allow'
                          : 'Pair',
                ),
              ),
            ],
          );
        },
      );
      _dialogContext = null;
      if (!answered) {
        answered = true;
        widget.link.answerRequest(allow == true);
      }
      _showing = false;
      _check();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
