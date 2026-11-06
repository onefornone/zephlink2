import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zephlink/app.dart';
import 'package:zephlink/link/link_controller.dart';
import 'package:zephlink/theme/app_theme.dart';
import 'package:zephlink/theme/theme_controller.dart';

void main() {
  setUp(() {
    // Do not download fonts while testing.
    AppTheme.useGoogleFonts = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('app starts on the Connect tab with nothing paired', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ZephlinkApp(
        themeController: ThemeController(prefs),
        // Not started, so the test touches no network.
        linkController: LinkController(prefs),
      ),
    );
    await tester.pump();

    expect(find.text('Zephlink'), findsWidgets);
    expect(find.text('Not linked yet'), findsWidgets);
    expect(find.text('Connect a device'), findsWidgets);
    expect(find.text('Recent files'), findsOneWidget);
    expect(find.text('Recent activity'), findsNothing);
    // Nothing fake is shown.
    expect(find.text('Maya Chen'), findsNothing);
    expect(find.text('Trip-video.mp4'), findsNothing);
  });

  test('theme choice is saved and restored', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = ThemeController(prefs);
    expect(controller.mode, ThemeMode.system);

    await controller.setMode(ThemeMode.dark);
    expect(ThemeController(prefs).mode, ThemeMode.dark);
  });

  test('light and dark themes use different surfaces', () {
    expect(
      AppTheme.light().colorScheme.surface == AppTheme.dark().colorScheme.surface,
      isFalse,
    );
    expect(AppTheme.dark().colorScheme.brightness, Brightness.dark);
  });
}
