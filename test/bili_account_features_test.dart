import 'dart:async';
import 'dart:convert';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/bili_account.dart';
import 'package:bilibeats/services/bili_favorites.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/library_transfer.dart';
import 'package:bilibeats/services/recommendation_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

const a = BiliAccount(cookies: 'SESSDATA=testA', mid: 10, name: 'A');
const b = BiliAccount(cookies: 'SESSDATA=testB', mid: 20, name: 'B');
Track track(String id) => Track(
    id: '${id}_p1',
    bvid: id,
    cid: 1,
    title: '《大鱼》翻唱',
    rawTitle: '《大鱼》翻唱',
    uploader: 'UP',
    coverUrl: '',
    duration: 240);
String body(Map data) => jsonEncode({'code': 0, 'data': data});
Map media(int i) => {
      'type': 2,
      'bvid': 'BV$i',
      'title': '歌曲$i',
      'duration': 240,
      'ugc': {'first_cid': i + 1},
      'upper': {'name': 'UP'}
    };

void main() {
  setUpAll(() async {
    await stubDocs('bili_features');
    useHermeticHttp();
  });
  setUp(() async {
    await BiliAccountStore.save(a);
    await BiliAccountStore.setHistoryEnabled(a, false);
    await DatabaseService.setPref('biliFavoriteSources', {});
    RecommendationEngine.clearAccountData();
  });
  tearDown(() {
    BilibiliSdk.requestWith = null;
    RecommendationEngine.historyWith = BilibiliSdk.watchHistory;
  });

  test('a failed folder page can resume without a partial successful import',
      () async {
    var fail = true;
    final pages = <int>[];
    BilibiliSdk.requestWith = (url, {cookies}) async {
      final page = int.parse(Uri.parse(url).queryParameters['pn']!);
      pages.add(page);
      if (page == 2 && fail) return null;
      return body({
        'medias': [media(page)],
        'has_more': page == 1
      });
    };
    final scan = FavoriteScan(1, a);
    await expectLater(scan.read(), throwsA(isA<BiliApiException>()));
    expect(scan.complete, isFalse);
    expect(scan.tracks, hasLength(1));
    fail = false;
    await scan.read();
    expect(scan.complete, isTrue);
    expect(scan.tracks, hasLength(2));
    expect(pages, [1, 2, 2]);
  });

  test(
      'folders over 1000 are read completely and failed pages return no snapshot',
      () async {
    var calls = 0;
    BilibiliSdk.requestWith = (url, {cookies}) async {
      final page = int.parse(Uri.parse(url).queryParameters['pn']!);
      calls++;
      return body({
        'medias': [for (var i = 0; i < 20; i++) media((page - 1) * 20 + i)],
        'has_more': page < 52
      });
    };
    expect(await BilibiliSdk.favoriteTracks(1), hasLength(1040));
    expect(calls, 52);
    BilibiliSdk.requestWith =
        (url, {cookies}) async => Uri.parse(url).queryParameters['pn'] == '1'
            ? body({
                'medias': [media(1)],
                'has_more': true
              })
            : null;
    expect(await BilibiliSdk.favoriteTracks(1), isNull);
  });

  test('closing a scan or changing accounts prevents further pages', () async {
    var calls = 0;
    BilibiliSdk.requestWith = (url, {cookies}) async {
      calls++;
      return body({
        'medias': [media(1)],
        'has_more': true
      });
    };
    final scan = FavoriteScan(1, a);
    await scan.read(onProgress: () => scan.cancelled = true);
    expect(calls, 1);
    expect(scan.complete, isFalse);
    await BiliAccountStore.save(b);
    await expectLater(
        FavoriteScan(1, a).read(), throwsA(isA<BiliApiException>()));
  });

  Future<({int queued, String playlistId})> add(int folder,
          {String name = '默认收藏夹',
          bool recommend = false,
          List<Track>? tracks,
          BiliAccount account = a}) =>
      BiliFavorites.importSelection(
          account: account,
          folderId: folder,
          folderName: name,
          tracks: tracks ?? [track('BVsource$folder')],
          recommend: recommend,
          download: false);

  test('source IDs isolate equal names and reimport preserves custom names',
      () async {
    final unrelated = await DatabaseService.createPlaylist('默认收藏夹');
    final first = await add(101);
    final second = await add(102);
    expect(first.playlistId, isNot(second.playlistId));
    expect(first.playlistId, isNot(unrelated.id));
    final renamed = await add(101, name: '远端新名字');
    expect(renamed.playlistId, first.playlistId);
    var lists = await DatabaseService.getPlaylists();
    expect(lists.firstWhere((p) => p.id == first.playlistId).name, '远端新名字');
    await DatabaseService.renamePlaylist(first.playlistId, '我的名字');
    await add(101, name: '又改了');
    lists = await DatabaseService.getPlaylists();
    final local = lists.firstWhere((p) => p.id == first.playlistId);
    expect(local.name, '我的名字');
    expect(local.tracks, hasLength(1));
    await BiliAccountStore.save(b);
    final otherAccount = await add(101, account: b);
    expect(otherAccount.playlistId, isNot(first.playlistId));
  });

  test(
      'opted-in favourites seed recommendations without downloads and can opt out',
      () async {
    final song = track('BVseed');
    final result = await add(103, recommend: true, tracks: [song]);
    expect(result.queued, 0);
    expect(await DatabaseService.getDownloadedTracks(), isEmpty);
    expect(
        (await BiliFavorites.recommendationTracks(a.mid)).single.id, song.id);
    expect(await BiliFavorites.recommendationTracks(b.mid), isEmpty);
    await add(103);
    expect(await BiliFavorites.recommendationTracks(a.mid), isEmpty);
  });

  test('history paginates past nonmusic and ignores accidental starts',
      () async {
    final queries = <Map<String, String>>[];
    Map item(String id, String zone, int progress) => {
          'title': '《歌曲》',
          'tag_name': zone,
          'duration': 240,
          'progress': progress,
          'history': {'bvid': id, 'cid': 1, 'page': 1}
        };
    BilibiliSdk.requestWith = (url, {cookies}) async {
      final query = Uri.parse(url).queryParameters;
      queries.add(query);
      if (query['max'] == null) {
        return body({
          'list': [item('BVgame', '网络游戏', 100)],
          'cursor': {'max': 12, 'view_at': 34, 'business': 'archive'}
        });
      }
      return body({
        'list': [item('BVbrief', '音乐现场', 1), item('BVmusic', '音乐现场', -1)],
        'cursor': {'max': 0}
      });
    };
    final watched = await BilibiliSdk.watchHistory();
    expect(watched!.map((t) => t.bvid), ['BVmusic']);
    expect(queries, hasLength(2));
    expect(queries[1]['max'], '12');
    expect(queries[1]['view_at'], '34');
  });

  test('history is opt-in per account and logout cannot reuse its cache',
      () async {
    var calls = 0;
    RecommendationEngine.historyWith = () async {
      calls++;
      return [track('BVwatched')];
    };
    expect(await RecommendationEngine.accountHistory(), isEmpty);
    expect(calls, 0);
    await BiliAccountStore.setHistoryEnabled(a, true);
    expect(await RecommendationEngine.accountHistory(), hasLength(1));
    await BiliAccountStore.logOut();
    expect(await RecommendationEngine.accountHistory(), isEmpty);
    await BiliAccountStore.save(b);
    expect(await RecommendationEngine.accountHistory(), isEmpty);
    expect(calls, 1);
  });

  test('an in-flight history request cannot return another account data',
      () async {
    await BiliAccountStore.setHistoryEnabled(a, true);
    final gate = Completer<List<Track>?>();
    RecommendationEngine.historyWith = () => gate.future;
    final pending = RecommendationEngine.accountHistory();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await BiliAccountStore.save(b);
    gate.complete([track('BVold')]);
    expect(await pending, isEmpty);
    expect(await RecommendationEngine.accountHistory(), isEmpty);
  });

  test('an expired authenticated request updates account state', () async {
    BilibiliSdk.requestWith = (url, {cookies}) async => '{"code":-101}';
    expect(await BilibiliSdk.accountFor(a.cookies), isNull);
    expect(BiliAccountStore.current.value, isNull);
    expect(BiliAccountStore.expired, isTrue);
    await BiliAccountStore.save(b);
    // A late response for A is not allowed to expire B.
    await BiliAccountStore.expire(a);
    expect(BiliAccountStore.current.value, same(b));
  });

  test('subtitle cache is isolated by login, including cached absence',
      () async {
    var lists = 0;
    BilibiliSdk.requestWith = (url, {cookies}) async {
      if (url.contains('/player/')) {
        lists++;
        return body({
          'subtitle': {
            'subtitles': BiliAccountStore.current.value?.mid == a.mid
                ? []
                : [
                    {
                      'lan': 'ai-zh',
                      'type': 1,
                      'subtitle_url': 'https://i0.hdslb.com/subtitle'
                    }
                  ]
          }
        });
      }
      return jsonEncode({
        'body': [
          {'from': 0, 'to': 2, 'content': '一行歌词'}
        ]
      });
    };
    expect(await BilibiliSdk.fetchSubtitles('BVcache', cid: 1), isNull);
    expect(await BilibiliSdk.fetchSubtitles('BVcache', cid: 1), isNull);
    expect(lists, 1);
    await BiliAccountStore.save(b);
    expect((await BilibiliSdk.fetchSubtitles('BVcache', cid: 1))!.lines,
        hasLength(1));
    expect(lists, 2);
    await BiliAccountStore.logOut();
    expect(await BilibiliSdk.fetchSubtitles('BVcache', cid: 1), isNull);
  });
  test('accepting an import queues only the chosen parts', () async {
    LibraryTransfer.resetForTest();
    await LibraryTransfer.cancelAll();
    final selected = Track.fromMap(
        {...track('BVparts').toMap(), 'id': 'BVparts_p2', 'cid': 2});
    final downloaded = <String>[];
    LibraryTransfer.downloadWith = (t) async {
      downloaded.add(t.id);
      return true;
    };
    final result = await BiliFavorites.importSelection(
        account: a,
        folderId: 999,
        folderName: '只选第二首',
        tracks: [selected],
        recommend: false,
        download: true);
    expect(result.queued, 1);
    await waitFor(() => LibraryTransfer.status.value.pending == 0);
    expect(downloaded, ['BVparts_p2']);
    LibraryTransfer.resetForTest();
  });
}
