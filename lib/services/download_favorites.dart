import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bili_account.dart';
import 'bili_favorites.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';
import 'prefs.dart';

/// Adds downloaded Bilibili videos to an account's private backup folder.
/// A folder stores videos, not individual parts or device-local files.
class DownloadFavorites {
  DownloadFavorites._();

  static const folderName = 'BiliBeats 下载';
  static Future<void>? _running;
  static Timer? _pending;
  static bool _following = false;

  static String _key(int mid) => 'downloadFavoriteFolder:$mid';

  static Future<bool> enabled(BiliAccount account) async =>
      await Prefs.get(_key(account.mid)) is int;

  static Future<void> disable(BiliAccount account) =>
      Prefs.set(_key(account.mid), null);

  static void followLibrary() {
    if (_following) return;
    _following = true;
    DatabaseService.libraryUpdateStream.listen((_) => _schedule());
    BiliAccountStore.current.addListener(_schedule);
    _schedule();
  }

  static void _schedule([Duration delay = const Duration(seconds: 3)]) {
    _pending?.cancel();
    _pending = Timer(delay, () async {
      await BiliAccountStore.ensureLoaded();
      final account = BiliAccountStore.current.value;
      if (account == null || !await enabled(account)) return;
      try {
        await sync(account);
      } catch (e) {
        debugPrint('Download favorites sync failed: $e');
        _schedule(const Duration(minutes: 2));
      }
    });
  }

  /// Reuses a unique existing folder on a new device. An ambiguous name is
  /// rejected rather than silently writing into somebody's other folder.
  static Future<int> enable(BiliAccount account) async {
    final existing = await Prefs.get(_key(account.mid));
    if (existing is int) return existing;
    final folders = await BilibiliSdk.favoriteFolders(account.mid);
    if (folders == null) throw const BiliApiException('无法读取收藏夹');
    final matches = folders.where((f) => f.title == folderName).toList();
    if (matches.length > 1) {
      throw const BiliApiException('存在多个同名收藏夹，请先重命名多余的收藏夹');
    }
    final id = matches.isEmpty
        ? await BilibiliSdk.createFavoriteFolder(account, folderName)
        : matches.single.id;
    if (!identical(BiliAccountStore.current.value, account)) {
      throw const BiliApiException('账号已更改');
    }
    await Prefs.set(_key(account.mid), id);
    if (_following) _schedule();
    return id;
  }

  static Future<void> sync(BiliAccount account) async {
    while (_running != null) {
      final previous = _running!;
      try {
        await previous;
      } catch (_) {
        // A later request gets its own chance to retry.
      }
      if (!identical(BiliAccountStore.current.value, account)) return;
    }
    final future = _sync(account);
    _running = future;
    try {
      await future;
    } finally {
      if (identical(_running, future)) _running = null;
    }
  }

  static Future<void> _sync(BiliAccount account) async {
    final folderId = await Prefs.get(_key(account.mid));
    if (folderId is! int) return;
    final folders = await BilibiliSdk.favoriteFolders(account.mid);
    if (folders == null) throw const BiliApiException('无法读取收藏夹');
    final matches = folders.where((f) => f.id == folderId);
    if (matches.isEmpty) throw const BiliApiException('备份收藏夹已删除');
    final present = <String>{};
    if (matches.single.count > 0) {
      final scan = FavoriteScan(folderId, account);
      await scan.read();
      present.addAll(scan.tracks.map((t) => t.bvid));
    }
    final downloaded = await DatabaseService.getDownloadedTracks();
    final videos = {
      for (final track in downloaded)
        if (!track.isLocal && track.bvid.isNotEmpty) track.bvid,
    };
    for (final bvid in videos.difference(present)) {
      if (!identical(BiliAccountStore.current.value, account)) {
        throw const BiliApiException('账号已更改');
      }
      if (!await enabled(account)) return;
      await BilibiliSdk.addVideoToFavorite(account, folderId, bvid);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
