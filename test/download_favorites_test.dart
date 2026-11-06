import 'dart:convert';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/bili_account.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/download_favorites.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

void main() {
  const account = BiliAccount(
      cookies: 'SESSDATA=session; bili_jct=csrf', mid: 42, name: 'Test');

  setUpAll(() async {
    await stubDocs('download_favorites');
    useHermeticHttp();
    await BiliAccountStore.save(account);
  });
  tearDown(() {
    BilibiliSdk.requestWith = null;
    BilibiliSdk.postWith = null;
  });

  test('creates a private folder and adds each video once', () async {
    const first = Track(
        id: 'BV1abcdefgh1_p1',
        bvid: 'BV1abcdefgh1',
        cid: 1,
        title: 'one',
        rawTitle: 'one',
        uploader: 'up',
        coverUrl: '',
        duration: 1);
    const second = Track(
        id: 'BV1abcdefgh1_p2',
        bvid: 'BV1abcdefgh1',
        cid: 2,
        title: 'two',
        rawTitle: 'two',
        uploader: 'up',
        coverUrl: '',
        duration: 1);
    await DatabaseService.saveDownloadedTrack(first);
    await DatabaseService.saveDownloadedTrack(second);
    var created = false;
    final posts = <Map<String, String>>[];
    BilibiliSdk.requestWith = (url, {cookies}) async {
      if (url.contains('list-all')) {
        return jsonEncode({
          'code': 0,
          'data': {
            'list': created
                ? [
                    {
                      'id': 123,
                      'title': DownloadFavorites.folderName,
                      'media_count': 0
                    }
                  ]
                : []
          }
        });
      }
      if (url.contains('/view?')) {
        return jsonEncode({
          'code': 0,
          'data': {'aid': 777}
        });
      }
      return null;
    };
    BilibiliSdk.postWith = (url, fields, sentAccount) async {
      expect(identical(sentAccount, account), isTrue);
      posts.add(fields);
      if (url.endsWith('/folder/add')) {
        created = true;
        return jsonEncode({
          'code': 0,
          'data': {'id': 123}
        });
      }
      return jsonEncode({'code': 0});
    };
    expect(await DownloadFavorites.enable(account), 123);
    await DownloadFavorites.sync(account);
    expect(posts, hasLength(2));
    expect(posts.first['privacy'], '1');
    expect(posts.last['rid'], '777');
    expect(posts.last['add_media_ids'], '123');
    expect(posts.last['csrf'], 'csrf');
  });
}
