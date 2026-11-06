import 'package:flutter/widgets.dart';

import 'link/link_controller.dart';
import 'theme/theme_controller.dart';

/// Gives any widget access to app-wide controllers.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.themeController,
    required this.linkController,
    required super.child,
  });

  final ThemeController themeController;
  final LinkController linkController;

  /// The theme (light, dark, system) controller.
  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.themeController;
  }

  /// The phone-to-PC link controller.
  static LinkController linkOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.linkController;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return themeController != oldWidget.themeController ||
        linkController != oldWidget.linkController;
  }
}
