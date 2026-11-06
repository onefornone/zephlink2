import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdatePromptHost extends StatefulWidget {
  const UpdatePromptHost({super.key, required this.child});

  final Widget child;

  @override
  State<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends State<UpdatePromptHost> {
  @override
  void initState() {
    super.initState();
    if (kReleaseMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_checkForUpdate());
      });
    }
  }

  Future<void> _checkForUpdate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final lastChecked =
          DateTime.tryParse(prefs.getString('zl_release_checked') ?? '');
      String? tag = prefs.getString('zl_latest_release_tag');
      String? url = prefs.getString('zl_latest_release_url');
      if (lastChecked == null ||
          now.difference(lastChecked) >= const Duration(hours: 24)) {
        final release = await _fetchLatestRelease();
        tag = release?.tag;
        url = release?.url;
        await prefs.setString('zl_release_checked', now.toIso8601String());
        if (tag != null && url != null) {
          await prefs.setString('zl_latest_release_tag', tag);
          await prefs.setString('zl_latest_release_url', url);
        } else {
          await prefs.remove('zl_latest_release_tag');
          await prefs.remove('zl_latest_release_url');
        }
      }

      final current = await PackageInfo.fromPlatform();
      if (tag == null ||
          url == null ||
          !isNewerVersion(tag, current.version) ||
          prefs.getString('zl_release_prompted') == tag ||
          !mounted) {
        return;
      }
      await prefs.setString('zl_release_prompted', tag);
      if (!mounted) return;
      final openRelease = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Zephlink update available'),
          content: Text(
            'Version $tag is available. You are using ${current.version}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('View update'),
            ),
          ],
        ),
      );
      if (openRelease == true) {
        final opened = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
        if (!opened) {
          throw const HttpException(
              'Could not open the Zephlink release page.');
        }
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Zephlink update check',
          context: ErrorDescription('while checking for a GitHub Release'),
        ),
      );
    }
  }

  Future<_Release?> _fetchLatestRelease() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(
        Uri.https(
          'api.github.com',
          '/repos/onefornone/zephyrlink/releases/latest',
        ),
      );
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Zephlink');
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub returned status ${response.statusCode} while checking releases.',
        );
      }
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('GitHub returned invalid release data.');
      }
      final tag = json['tag_name'];
      final url = json['html_url'];
      final parsedUrl = url is String ? Uri.tryParse(url) : null;
      if (tag is! String ||
          parsedUrl == null ||
          parsedUrl.scheme != 'https' ||
          parsedUrl.host != 'github.com') {
        throw const FormatException(
            'GitHub release is missing its tag or URL.');
      }
      return _Release(tag: tag, url: url);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Release {
  const _Release({required this.tag, required this.url});

  final String tag;
  final String url;
}

bool isNewerVersion(String candidate, String current) {
  final candidateParts = _versionParts(candidate);
  final currentParts = _versionParts(current);
  if (candidateParts == null || currentParts == null) return false;
  for (var index = 0; index < 3; index++) {
    if (candidateParts[index] != currentParts[index]) {
      return candidateParts[index] > currentParts[index];
    }
  }
  return false;
}

List<int>? _versionParts(String value) {
  final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(value.trim());
  if (match == null) return null;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}
