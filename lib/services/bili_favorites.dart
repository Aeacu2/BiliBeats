import '../models/track.dart';
import 'bili_account.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';
import 'library_transfer.dart';
import 'prefs.dart';

/// A folder scan can resume the failed page, without presenting partial data
/// as a complete import. Closing the preview stops further page requests.
class FavoriteScan {
  FavoriteScan(this.folderId, this.account);

  final int folderId;
  final BiliAccount account;
  final List<Track> _tracks = [];
  final Set<String> _ids = {};
  int _page = 1;
  bool complete = false;
  bool cancelled = false;

  List<Track> get tracks => List.unmodifiable(_tracks);

  Future<void> read({void Function()? onProgress}) async {
    while (!complete && !cancelled) {
      if (!identical(BiliAccountStore.current.value, account)) {
        throw const BiliApiException('账号已更改，请重新打开收藏夹');
      }
      final page = await BilibiliSdk.favoritePage(folderId, _page);
      if (cancelled) return;
      if (!identical(BiliAccountStore.current.value, account)) {
        throw const BiliApiException('账号已更改，请重新打开收藏夹');
      }
      final before = _tracks.length;
      for (final track in page.tracks) {
        if (_ids.add(track.id)) _tracks.add(track);
      }
      if (page.hasMore && page.tracks.isNotEmpty && _tracks.length == before) {
        throw const BiliApiException('收藏夹分页重复，请重试');
      }
      _page++;
      complete = !page.hasMore;
      onProgress?.call();
    }
  }
}

/// Source IDs, rather than names, connect a Bilibili folder to its local
/// playlist. Removing a remote favourite never deletes a local song.
class BiliFavorites {
  BiliFavorites._();

  static const _pref = 'biliFavoriteSources';

  static Future<Map<String, dynamic>> _sources() async {
    final stored = await Prefs.get(_pref);
    return stored is Map ? Map<String, dynamic>.from(stored) : {};
  }

  static String _key(int mid, int folderId) => '$mid/$folderId';

  static Future<bool> isLinked(int mid, int folderId) async =>
      (await _sources()).containsKey(_key(mid, folderId));

  static Future<bool> usesRecommendations(int mid, int folderId) async {
    final source = (await _sources())[_key(mid, folderId)];
    return source is Map && source['recommend'] == true;
  }

  /// A conservative convenience selection. Unknown videos remain visible
  /// and selectable; this is not evidence for naming or for discarding one.
  static bool suggest(Track track) =>
      track.duration > 0 &&
      track.duration <= 15 * 60 &&
      !RegExp(r'教学|教程|访谈|采访|乐评|盘点|音高检测').hasMatch(track.title) &&
      RegExp(r'《[^》]+》|翻唱|演奏|纯享|独唱|合唱|钢琴曲|吉他曲|\bcover\b|\bMV\b',
              caseSensitive: false)
          .hasMatch(track.title);

  static Future<({int queued, String playlistId})> importSelection({
    required BiliAccount account,
    required int folderId,
    required String folderName,
    required List<Track> tracks,
    required bool recommend,
    required bool download,
  }) async {
    if (!identical(account, BiliAccountStore.current.value)) {
      throw const BiliApiException('账号已更改，请重新导入');
    }
    if (tracks.isEmpty) throw const BiliApiException('请先选择视频');
    final sources = await _sources();
    final key = _key(account.mid, folderId);
    final source = sources[key];
    final playlists = await DatabaseService.getPlaylists();
    final linked =
        playlists.where((p) => source is Map && p.id == source['playlistId']);
    final playlist = linked.isEmpty
        ? await DatabaseService.createPlaylist(folderName)
        : linked.first;
    // Follow a remote rename unless the listener renamed the playlist.
    if (source is Map &&
        playlist.name == source['name'] &&
        playlist.name != folderName) {
      await DatabaseService.renamePlaylist(playlist.id, folderName);
    }
    await DatabaseService.addTracksToPlaylist(playlist.id, tracks);
    sources[key] = {
      'playlistId': playlist.id,
      'name': folderName,
      'recommend': recommend,
    };
    await Prefs.set(_pref, sources);
    BiliAccountStore.notifyChanged();
    final queued =
        download ? await LibraryTransfer.enqueueDownloads(tracks) : 0;
    return (queued: queued, playlistId: playlist.id);
  }

  /// Only explicitly opted-in folders of the current account contribute.
  /// Songs need not be downloaded to act as seeds.
  static Future<List<Track>> recommendationTracks(int mid) async {
    final sources = await _sources();
    final playlistIds = {
      for (final e in sources.entries)
        if (e.key.startsWith('$mid/') &&
            e.value is Map &&
            e.value['recommend'] == true)
          e.value['playlistId'],
    };
    final byId = <String, Track>{};
    for (final p in await DatabaseService.getPlaylists()) {
      if (!playlistIds.contains(p.id)) continue;
      for (final t in p.tracks) {
        byId[t.id] = t;
      }
    }
    return byId.values.toList();
  }
}
