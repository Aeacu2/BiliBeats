import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// The listener's Bilibili account, when they have logged in.
@immutable
class BiliAccount {
  /// The login cookies as one `Cookie` header value (SESSDATA, bili_jct,
  /// DedeUserID…).
  final String cookies;
  final int mid;
  final String name;
  final String face;

  const BiliAccount({
    required this.cookies,
    required this.mid,
    required this.name,
    this.face = '',
  });

  Map<String, dynamic> toMap() =>
      {'cookies': cookies, 'mid': mid, 'name': name, 'face': face};

  static BiliAccount? fromMap(Object? map) {
    if (map is! Map) return null;
    final cookies = map['cookies'], mid = map['mid'];
    if (cookies is! String || !hasSession(cookies) || mid is! int) return null;
    return BiliAccount(
      cookies: cookies,
      mid: mid,
      name: '${map['name'] ?? ''}',
      face: '${map['face'] ?? ''}',
    );
  }

  /// Whether [cookies] carry a login session.
  static bool hasSession(String cookies) =>
      cookieValue(cookies, 'SESSDATA')?.isNotEmpty ?? false;

  /// One cookie's value from a `Cookie` header, as it is written there.
  static String? cookieValue(String cookies, String name) {
    for (final part in cookies.split(';')) {
      final at = part.indexOf('=');
      if (at <= 0) continue;
      if (part.substring(0, at).trim() == name) {
        return part.substring(at + 1).trim();
      }
    }
    return null;
  }

  /// The login cookies only, from everything a browser holds for the site.
  static String sessionCookies(String all) => [
        for (final name in const [
          'SESSDATA',
          'bili_jct',
          'DedeUserID',
          'DedeUserID__ckMd5',
          'sid',
        ])
          if (cookieValue(all, name) case final value? when value.isNotEmpty)
            '$name=$value',
      ].join('; ');
}

/// Where the account lives: `bilibeat_account.json`, in the app's private
/// documents, never anywhere else. The cookies are sent only to Bilibili,
/// and only for what needs an account — subtitles, favourites, history.
class BiliAccountStore {
  BiliAccountStore._();

  static const String _file = 'bilibeat_account.json';

  static final ValueNotifier<BiliAccount?> current = ValueNotifier(null);
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static bool expired = false;
  static Future<void>? _loading;

  static void notifyChanged() => changes.value++;

  static Future<bool> historyEnabled() async {
    final account = current.value;
    if (account == null) return false;
    return await DatabaseService.getPref(
            'biliHistoryRecommendations:${account.mid}') ==
        true;
  }

  static Future<void> setHistoryEnabled(BiliAccount account, bool value) async {
    if (!identical(current.value, account)) return;
    await DatabaseService.setPref(
        'biliHistoryRecommendations:${account.mid}', value);
    notifyChanged();
  }

  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final text = await DatabaseService.readStoreFile(_file);
      if (text == null) return;
      final payload = DatabaseService.unwrapStorePayload(jsonDecode(text));
      expired = payload is Map && payload['expired'] == true;
      current.value = BiliAccount.fromMap(payload);
      notifyChanged();
    } catch (e) {
      debugPrint('Account not loaded: $e');
      _loading = null;
    }
  }

  /// The session's cookies, or null when nobody is logged in.
  static Future<String?> cookies() async {
    await ensureLoaded();
    return current.value?.cookies;
  }

  static Future<void> save(BiliAccount account) async {
    await ensureLoaded();
    await DatabaseService.writeStoreFile(_file, account.toMap());
    expired = false;
    current.value = account;
    notifyChanged();
  }

  static Future<void> logOut() async {
    await ensureLoaded();
    await DatabaseService.writeStoreFile(_file, const <String, dynamic>{});
    expired = false;
    current.value = null;
    notifyChanged();
  }

  /// An old request must never expire a newer login.
  static Future<void> expire(BiliAccount account) async {
    if (!identical(current.value, account)) return;
    expired = true;
    current.value = null;
    notifyChanged();
    await DatabaseService.writeStoreFile(_file, const {'expired': true});
  }
}
