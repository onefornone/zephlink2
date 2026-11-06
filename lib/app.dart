import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'link/link_controller.dart';
import 'platform/windows_background_host.dart';
import 'platform/update_prompt_host.dart';
import 'shell/adaptive_shell.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/approval_host.dart';

/// Lets the link show questions on top of any screen.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class ZephlinkApp extends StatelessWidget {
  const ZephlinkApp({
    super.key,
    required this.themeController,
    required this.linkController,
  });

  final ThemeController themeController;
  final LinkController linkController;

  @override
  Widget build(BuildContext context) {
    // AppScope sits above MaterialApp so every page, including ones opened
    // with Navigator.push, can reach the theme controller.
    return AppScope(
      themeController: themeController,
      linkController: linkController,
      child: ListenableBuilder(
        listenable: themeController,
        builder: (context, _) {
          return MaterialApp(
            title: 'Zephlink',
            navigatorKey: appNavigatorKey,
            builder: (context, child) => WindowsBackgroundHost(
              child: UpdatePromptHost(
                child: ApprovalHost(
                  navigatorKey: appNavigatorKey,
                  link: linkController,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: themeController.mode,
            home: const AdaptiveShell(),
          );
        },
      ),
    );
  }
}
