import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateCheckResult {
  final bool hasUpdate;
  final bool requiresUpdate;
  final String currentLabel;
  final String latestLabel;
  final String minSupportedLabel;
  final String apkUrl;
  final String notes;

  const AppUpdateCheckResult({
    required this.hasUpdate,
    required this.requiresUpdate,
    required this.currentLabel,
    required this.latestLabel,
    required this.minSupportedLabel,
    required this.apkUrl,
    required this.notes,
  });
}

class AppUpdateService {
  // uses /version-dev.json for testing purposes. Switch to false for release.
  static const bool _useDevEndpoint = bool.fromEnvironment(
    'USE_DEV_UPDATE_JSON',
    defaultValue: false,
  );
  static const String _hostBase = 'https://greenbugx.github.io/Hongeet';

  Uri get _versionUri => Uri.parse(
    _useDevEndpoint ? '$_hostBase/version-dev.json' : '$_hostBase/version.json',
  );

  Future<AppUpdateCheckResult> checkForUpdates() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentLabel = '${packageInfo.version}+${packageInfo.buildNumber}';
    final currentVersion = _ComparableVersion.parse(currentLabel);

    final response = await http
        .get(_versionUri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw StateError('Update server unavailable (${response.statusCode}).');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Invalid update response.');
    }

    final latestLabel = (decoded['latest'] ?? '').toString().trim();
    final minSupportedLabel = (decoded['min_supported'] ?? '')
        .toString()
        .trim();
    final apkUrl = (decoded['apk_url'] ?? '').toString().trim();
    final notes = (decoded['notes'] ?? '').toString().trim();

    if (latestLabel.isEmpty || apkUrl.isEmpty) {
      throw StateError('Missing update data.');
    }

    final latestVersion = _ComparableVersion.parse(latestLabel);
    final minSupportedVersion = _ComparableVersion.parse(
      minSupportedLabel.isEmpty ? latestLabel : minSupportedLabel,
    );

    final hasUpdate = latestVersion.compareTo(currentVersion) > 0;
    final requiresUpdate = minSupportedVersion.compareTo(currentVersion) > 0;

    return AppUpdateCheckResult(
      hasUpdate: hasUpdate,
      requiresUpdate: requiresUpdate,
      currentLabel: currentLabel,
      latestLabel: latestLabel,
      minSupportedLabel: minSupportedLabel.isEmpty
          ? latestLabel
          : minSupportedLabel,
      apkUrl: apkUrl,
      notes: notes,
    );
  }

  Future<bool> openUpdateUrl(String apkUrl) async {
    final uri = Uri.tryParse(apkUrl);
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

Future<void> showUpdateDialog(
  BuildContext context,
  AppUpdateCheckResult result,
) async {
  final service = AppUpdateService();

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      final notesText = result.notes.isEmpty
          ? 'New fixes and improvements.'
          : result.notes;
      return AlertDialog(
        title: Text('Available Update ${result.latestLabel}'),
        content: Text(
          'A new version of Hongeet is available with new fixes.\n\n'
          'Current: ${result.currentLabel}\n'
          'Latest: ${result.latestLabel}\n\n'
          '$notesText',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Ignore'),
          ),
          FilledButton(
            onPressed: () async {
              final opened = await service.openUpdateUrl(result.apkUrl);
              if (!opened && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not open update link')),
                );
                return;
              }
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('Update'),
          ),
        ],
      );
    },
  );
}

class _ComparableVersion implements Comparable<_ComparableVersion> {
  final int major;
  final int minor;
  final int patch;
  final int build;

  const _ComparableVersion(this.major, this.minor, this.patch, this.build);

  factory _ComparableVersion.parse(String raw) {
    var value = raw.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }

    final plusSplit = value.split('+');
    final semantic = plusSplit.first.split('.');

    int readSegment(int index) {
      if (index >= semantic.length) return 0;
      final match = RegExp(r'\d+').firstMatch(semantic[index]);
      return int.tryParse(match?.group(0) ?? '') ?? 0;
    }

    int readBuild() {
      if (plusSplit.length < 2) return 0;
      final match = RegExp(r'\d+').firstMatch(plusSplit[1]);
      return int.tryParse(match?.group(0) ?? '') ?? 0;
    }

    return _ComparableVersion(
      readSegment(0),
      readSegment(1),
      readSegment(2),
      readBuild(),
    );
  }

  @override
  int compareTo(_ComparableVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }
}
