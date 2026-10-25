import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/bili_account.dart';
import '../services/bilibili_sdk.dart';
import '../services/track_naming.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import '../widgets/sheet.dart';

/// Logging in to Bilibili: on this phone, by confirming in the Bilibili app
/// (Android; Bilibili's web login page when the app is not installed), or
/// by scanning a code with the Bilibili app on another device.
class BiliLogin {
  BiliLogin._();

  static const MethodChannel _channel = MethodChannel('bilibeats/account');

  /// Handing the login to the Bilibili app, and the web page in its place,
  /// need the Android side.
  static bool get canLogInHere => !kIsWeb && Platform.isAndroid;

  /// How to log in; completes once logged in (or given up).
  static Future<void> start(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final how = await showAppSheet<String>(
      context,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle('登录哔哩哔哩', detail: '用于字幕、收藏夹和推荐'),
          if (canLogInHere)
            SheetAction(
              icon: Icons.phone_android_rounded,
              label: '在本机登录',
              onTap: () => Navigator.pop(sheet, 'here'),
            ),
          SheetAction(
            icon: Icons.qr_code_2_rounded,
            label: '扫码登录',
            onTap: () => Navigator.pop(sheet, 'qr'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (how == null || !navigator.mounted) return;
    var account = await showAppSheet<Object>(
      navigator.context,
      builder: (_) => _QrLogin(here: how == 'here'),
    );
    // No Bilibili app on this phone: its web login page instead.
    if (account == _QrLogin.noApp && navigator.mounted) {
      account = await navigator.push<BiliAccount>(MaterialPageRoute(
        builder: (_) => const _LoginPage(),
      ));
    }
    if (account is! BiliAccount) return;
    await BiliAccountStore.save(account);
    // Songs no name was found for get another look, subtitles in hand.
    await TrackNaming.retryUnnamed();
    showAppSnackBar(messenger,
        message: account.name.isEmpty ? '已登录' : '已登录：${account.name}');
  }

  static Future<void> logOut() async {
    await BiliAccountStore.logOut();
    if (canLogInHere) {
      try {
        await _channel.invokeMethod<void>('clearCookies');
      } catch (e) {
        debugPrint('Clearing login cookies failed: $e');
      }
    }
  }

  /// Opens a login code's address in the Bilibili app, to be confirmed
  /// there; false when no Bilibili app took it.
  static Future<bool> _openInBilibili(String url) async {
    try {
      return await _channel
              .invokeMethod<bool>('openInBilibili', {'url': url}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _cookies(String url) async {
    try {
      return await _channel.invokeMethod<String>('cookies', {'url': url}) ?? '';
    } catch (_) {
      return '';
    }
  }
}

/// Bilibili's mobile login page. Done as soon as the browser holds a
/// session the account check accepts.
class _LoginPage extends StatefulWidget {
  const _LoginPage();

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  static final Uri _page =
      Uri.parse('https://passport.bilibili.com/h5-app/passport/login'
          '?gourl=${Uri.encodeComponent('https://m.bilibili.com/')}');

  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(AppColors.background)
    ..setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) => unawaited(_check()),
      // Links that leave the web (open the Bilibili app, a store page)
      // have nowhere to go here, and nothing is loaded in the clear while
      // the page holds a session.
      onNavigationRequest: (request) => request.url.startsWith('https://')
          ? NavigationDecision.navigate
          : NavigationDecision.prevent,
    ))
    ..loadRequest(_page);

  Timer? _poll;
  bool _checking = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _poll =
        Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_check()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking || _done) return;
    _checking = true;
    try {
      final all = [
        await BiliLogin._cookies('https://www.bilibili.com'),
        await BiliLogin._cookies('https://passport.bilibili.com'),
      ].join('; ');
      final session = BiliAccount.sessionCookies(all);
      if (!BiliAccount.hasSession(session)) return;
      final account = await BilibiliSdk.accountFor(session);
      if (account == null || !mounted || _done) return;
      _done = true;
      Navigator.of(context).pop(account);
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('登录哔哩哔哩'),
      ),
      body: WebViewWidget(controller: _web),
    );
  }
}

/// A login code for the Bilibili app to scan, renewed when it expires.
/// [here]: the code is not shown but opened in the Bilibili app on this
/// phone, which asks to confirm the login; pops [noApp] when there is none.
class _QrLogin extends StatefulWidget {
  const _QrLogin({this.here = false});

  final bool here;

  static const Object noApp = 'noApp';

  @override
  State<_QrLogin> createState() => _QrLoginState();
}

class _QrLoginState extends State<_QrLogin> {
  String? _url;
  String? _key;
  QrLoginState _state = QrLoginState.waiting;
  bool _failed = false;
  Timer? _poll;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_renew());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _renew() async {
    _poll?.cancel();
    setState(() {
      _url = null;
      _failed = false;
      _state = QrLoginState.waiting;
    });
    final started = await BilibiliSdk.qrLoginStart();
    if (!mounted) return;
    if (started == null) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _url = started.url;
      _key = started.key;
    });
    if (widget.here && !await BiliLogin._openInBilibili(started.url)) {
      if (mounted) Navigator.of(context).pop(_QrLogin.noApp);
      return;
    }
    _poll =
        Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_check()));
  }

  Future<void> _check() async {
    final key = _key;
    if (key == null || _polling) return;
    _polling = true;
    try {
      final answer = await BilibiliSdk.qrLoginPoll(key);
      if (answer == null || !mounted) return;
      if (answer.state == QrLoginState.done) {
        _poll?.cancel();
        final account = await BilibiliSdk.accountFor(answer.cookies!);
        if (!mounted) return;
        if (account == null) {
          setState(() => _failed = true);
          return;
        }
        Navigator.of(context).pop(account);
        return;
      }
      if (answer.state == QrLoginState.expired) _poll?.cancel();
      setState(() => _state = answer.state);
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    final expired = _state == QrLoginState.expired;
    final String hint;
    if (_failed) {
      hint = '无法连接哔哩哔哩';
    } else if (expired) {
      hint = '二维码已过期';
    } else if (_state == QrLoginState.scanned) {
      hint = '已扫码，请在手机上确认';
    } else if (widget.here) {
      hint = '请在哔哩哔哩 App 中确认登录';
    } else {
      hint = '用另一台设备上的哔哩哔哩 App 扫码';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle(widget.here ? '在本机登录' : '扫码登录'),
        if (!widget.here)
          Center(
            child: Container(
              width: 220,
              height: 220,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                // A code is read dark on light, whatever the theme.
                color: AppColors.textPrimary,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: url == null || expired || _failed
                  ? const SizedBox.shrink()
                  : CustomPaint(painter: _QrPainter(url)),
            ),
          ),
        const SizedBox(height: 14),
        Text(hint,
            textAlign: TextAlign.center, style: AppTypography.bodyMedium),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: widget.here
              ? PrimaryButton(
                  label: expired || _failed ? '重试' : '打开哔哩哔哩',
                  secondary: true,
                  onPressed: expired || _failed
                      ? _renew
                      : url == null
                          ? null
                          : () => unawaited(BiliLogin._openInBilibili(url)),
                )
              : PrimaryButton(
                  label: '刷新二维码',
                  secondary: true,
                  onPressed: expired || _failed ? _renew : null,
                ),
        ),
      ],
    );
  }
}

class _QrPainter extends CustomPainter {
  final String data;

  _QrPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    final code = QrImage(QrCode(payload: QrPayload.fromString(data)));
    final n = code.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()..color = AppColors.background;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (code.isDark(y, x)) {
          canvas.drawRect(
              Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}
