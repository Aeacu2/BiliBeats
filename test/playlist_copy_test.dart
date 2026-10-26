import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// A song added to a playlist as a search result or a favourites import
/// describes it — the video — goes in as the library has it.
void main() {
  const video = Track(
    id: 'BV1copies001_p1',
    bvid: 'BV1copies001',
    cid: 1,
    title: '【周深】大鱼 live',
    rawTitle: '【周深】大鱼 live',
    uploader: 'someUP',
    coverUrl: '',
    duration: 200,
  );

  setUpAll(() async {
    await stubDocs('copies');
    await DatabaseService.saveDownloadedTrack(video);
    await DatabaseService.updateTrackMetadata(
        video.copyWith(title: '大鱼', uploader: '周深', named: true));
  });

  Future<Track> inPlaylist(String id) async =>
      (await DatabaseService.getPlaylists())
          .firstWhere((p) => p.id == id)
          .tracks
          .single;

  test('a batch of songs keeps the names the library gave them', () async {
    final playlist = await DatabaseService.createPlaylist('batch');
    await DatabaseService.addTracksToPlaylist(playlist.id, [video]);
    final stored = await inPlaylist(playlist.id);
    expect(stored.title, '大鱼');
    expect(stored.uploader, '周深');
  });

  test('one song, and one put back, too', () async {
    final playlist = await DatabaseService.createPlaylist('one');
    await DatabaseService.addTrackToPlaylist(playlist.id, video);
    expect((await inPlaylist(playlist.id)).title, '大鱼');

    await DatabaseService.removeTrackFromPlaylist(playlist.id, video.id);
    await DatabaseService.insertTrackInPlaylist(playlist.id, video, 0);
    expect((await inPlaylist(playlist.id)).title, '大鱼');
  });
}
