import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/state/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// 排序 → 最近播放: what was played comes first, the latest on top; songs
/// never played follow in the order they were downloaded.
void main() {
  Track track(String key) => Track(
        id: 'BV1sorting${key}_p1',
        bvid: 'BV1sorting$key',
        cid: 1,
        title: 'song $key',
        rawTitle: 'song $key',
        uploader: 'someone',
        coverUrl: '',
        duration: 200,
      );

  setUpAll(() async {
    await stubDocs('sort');
    await DatabaseService.getDownloadedTracks();
  });

  test('songs are ordered by when they were last played', () async {
    final library = LibraryController.instance;
    // Downloaded a, b, c, d in turn: the newest download is listed first.
    for (final key in ['a', 'b', 'c', 'd']) {
      await DatabaseService.saveDownloadedTrack(track(key));
    }
    await DatabaseService.addRecentlyPlayed(track('b'));
    await DatabaseService.addRecentlyPlayed(track('a'));
    await library.setSort(LibrarySort.played);
    await library.reload();

    List<String> titles() =>
        [for (final t in library.sortedDownloaded) t.title];
    expect(titles(), ['song a', 'song b', 'song d', 'song c']);

    // Playing one moves it to the top.
    await DatabaseService.addRecentlyPlayed(track('c'));
    await library.reload();
    expect(titles(), ['song c', 'song a', 'song b', 'song d']);

    await library.setSort(LibrarySort.recent);
    expect(titles(), ['song d', 'song c', 'song b', 'song a']);
  });
}
