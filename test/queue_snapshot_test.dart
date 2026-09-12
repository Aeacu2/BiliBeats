import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/audio_player_handler.dart'
    show LoopMode, PlaybackQueueSnapshot;
import 'package:flutter_test/flutter_test.dart';

/// Focused tests for the queue-snapshot phase (Prompt 3).
///
/// Covered here: snapshot value semantics (immutability, bounds, upcoming
/// counts). Handler-level publication (initial state, replacement,
/// shuffle/metadata/advance/prefetch silence, stale/removed selection,
/// system queue, mode publish) needs a fake `AudioPlayer`: the real
/// constructor requires the native platform and throws in tests. Those
/// stay tracked as unverified alongside the playback races.
void main() {
  Track track(String id, [String title = 'title']) => Track(
        id: id,
        bvid: 'BV1',
        cid: 1,
        title: title,
        rawTitle: title,
        uploader: 'uploader',
        coverUrl: '',
        duration: 200,
      );

  group('PlaybackQueueSnapshot', () {
    test('empty queue reports index -1 and zero upcoming', () {
      final snap = PlaybackQueueSnapshot(
        tracks: const [],
        currentIndex: -1,
        isShuffle: false,
        loopMode: LoopMode.all,
      );

      expect(snap.currentTrack, isNull);
      expect(snap.upcomingCount, 0);
    });

    test('track list is immutable', () {
      final snap = PlaybackQueueSnapshot(
        tracks: const [
          Track(
            id: 'a',
            bvid: 'BV1',
            cid: 1,
            title: 'title',
            rawTitle: 'title',
            uploader: 'uploader',
            coverUrl: '',
            duration: 200,
          ),
          Track(
            id: 'b',
            bvid: 'BV1',
            cid: 1,
            title: 'title',
            rawTitle: 'title',
            uploader: 'uploader',
            coverUrl: '',
            duration: 200,
          ),
        ],
        currentIndex: 0,
        isShuffle: false,
        loopMode: LoopMode.all,
      );

      expect(
        () => snap.tracks.add(track('c')),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => snap.tracks.removeAt(0),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('currentTrack resolves within bounds only', () {
      final a = track('a', 'A');
      final b = track('b', 'B');

      expect(
        PlaybackQueueSnapshot(
          tracks: [a, b],
          currentIndex: 1,
          isShuffle: false,
          loopMode: LoopMode.all,
        ).currentTrack?.id,
        'b',
      );
      expect(
        PlaybackQueueSnapshot(
          tracks: [a, b],
          currentIndex: 2,
          isShuffle: false,
          loopMode: LoopMode.all,
        ).currentTrack,
        isNull,
      );
      expect(
        PlaybackQueueSnapshot(
          tracks: [a, b],
          currentIndex: -1,
          isShuffle: false,
          loopMode: LoopMode.all,
        ).currentTrack,
        isNull,
      );
    });

    test('upcomingCount excludes current and never wraps', () {
      final tracks = [track('a'), track('b'), track('c')];

      PlaybackQueueSnapshot at(int index) => PlaybackQueueSnapshot(
            tracks: tracks,
            currentIndex: index,
            isShuffle: false,
            loopMode: LoopMode.all,
          );

      expect(at(0).upcomingCount, 2);
      expect(at(1).upcomingCount, 1);
      expect(at(2).upcomingCount, 0);
      expect(at(-1).upcomingCount, 3);
    });
  });
}
