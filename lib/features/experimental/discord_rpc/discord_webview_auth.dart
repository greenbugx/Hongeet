import 'dart:async';
// import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'discord_token_manager.dart';

/// Opens Discord web in a WebView and extracts the user token from localStorage
/// Polls every 1.5s for up to 60s using 3 different extraction methods
class DiscordWebViewAuth extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onCancel;

  const DiscordWebViewAuth({
    super.key,
    required this.onSuccess,
    required this.onCancel,
  });

  @override
  State<DiscordWebViewAuth> createState() => _DiscordWebViewAuthState();
}

class _DiscordWebViewAuthState extends State<DiscordWebViewAuth> {
  late final WebViewController _controller;
  bool _tokenFound = false;
  bool _isLoading = true;
  Timer? _pollTimer;

  static const _pollInterval = Duration(milliseconds: 1500);
  static const _maxAttempts = 40;
  int _pollAttempts = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            _pollTimer?.cancel();
            _pollAttempts = 0;
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (url) {
            debugPrint('[DiscordAuth] onPageFinished: $url');
            if (mounted) setState(() => _isLoading = false);
            _startPolling();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://discord.com/app'));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollAttempts = 0;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _tryExtractToken());
  }

  Future<void> _tryExtractToken() async {
    if (_tokenFound) {
      _pollTimer?.cancel();
      return;
    }

    _pollAttempts++;
    if (_pollAttempts > _maxAttempts) {
      _pollTimer?.cancel();
      debugPrint('[DiscordAuth] Gave up after $_maxAttempts attempts');
      return;
    }

    try {
      // Try 3 extraction methods, log result every attempt for debugging(I hate debugging btw)
      final result = await _controller.runJavaScriptReturningResult(r'''
        (function() {
          try {
            // Method 1: direct localStorage.getItem
            var raw = window.localStorage.getItem('token');
            if (raw && raw.length > 10) return 'M1:' + raw.replace(/^"|"$/g, '');
          } catch(e) {}
          try {
            // Method 2: iframe descriptor trick
            var iframe = document.createElement('iframe');
            document.body.appendChild(iframe);
            var pd = Object.getOwnPropertyDescriptor(iframe.contentWindow, 'localStorage');
            iframe.remove();
            var ls = pd ? pd.get.call(window) : null;
            if (ls) {
              var raw2 = ls.getItem('token');
              if (raw2 && raw2.length > 10) return 'M2:' + raw2.replace(/^"|"$/g, '');
            }
          } catch(e) {}
          try {
            // Method 3: webpack module store (getToken())
            var wpModules = window.webpackChunkdiscord_app;
            if (wpModules) {
              var req;
              wpModules.push([[Math.random()], {}, function(r) { req = r; }]);
              var modules = Object.keys(req.m).map(function(id) {
                try { return req(id); } catch(e) { return null; }
              }).filter(Boolean);
              for (var i = 0; i < modules.length; i++) {
                var m = modules[i];
                if (m && m.default && typeof m.default.getToken === 'function') {
                  var t = m.default.getToken();
                  if (t && t.length > 10) return 'M3:' + t;
                }
              }
            }
          } catch(e) {}
          return 'EMPTY';
        })()
      ''');

      final raw = result.toString().replaceAll('"', '').trim();
      final logSafe = raw.startsWith('M')
          ? '${raw.substring(0, raw.indexOf(":") + 1)}***'
          : raw;
      debugPrint('[DiscordAuth] Attempt $_pollAttempts $logSafe');

      if (raw == 'EMPTY' || raw.isEmpty) return;

      // Strip method prefix M1:, M2:, M3:
      final token = raw.contains(':')
          ? raw.substring(raw.indexOf(':') + 1)
          : raw;

      if (token.isNotEmpty && token != 'null' && token != 'undefined') {
        _tokenFound = true;
        _pollTimer?.cancel();
        debugPrint('[DiscordAuth] Token found via attempt $_pollAttempts');
        await DiscordTokenManager.saveUserToken(token);
        if (mounted) widget.onSuccess();
      }
    } catch (e) {
      debugPrint('[DiscordAuth] Poll error at attempt $_pollAttempts: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: widget.onCancel,
        ),
        title: const Text('Connect Discord'),
        bottom: _isLoading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                'Log in to Discord above. Hongeet will connect automatically.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
