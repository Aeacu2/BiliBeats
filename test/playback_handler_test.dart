import 'dart:async';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/trim_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

/// The playback engine's contract:
///  * what is shown is always the native player's current item;
///  * a song that still has to download never changes what is shown or
///    heard until it is ready;
///  * the session survives a process restart.
void main() {
  late LocalAudioServer server;

  setUpAll(() async {
    await stubDocs('playback');
    useRealHttp();
    server = await LocalAudioServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  /// Tracks already on disk. Names must be unique per test: download state
  /// is process-wide.
  Future<List<Track>> downloaded(List<String> names) async {
    final tracks = <Track>[];
    for (final name in names) {
      server.serveInstant(name);
      final track = serverTrack(server, name, title: name);
      await AudioDownloadService.ensureDownloaded(track);
      tracks.add(track);
    }
    return tracks;
  }

  BiliBeatsAudioHandler handlerFor(FakeAudioPlayer fake) =>
      BiliBeatsAudioHandler(player: fake, manageAudioSession: false);

  List<String> queueIds(BiliBeatsAudioHandler handler) =>
      [for (final t in handler.queueSnapshot.tracks) t.id];

  test('shows exactly the item the native player is on', () async {
    final t = await downloaded(['pb-show-a', 'pb-show-b', 'pb-show-c']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);

    await handler.playTrack(t[0], queue: t);
    expect(handler.currentTrack, t[0]);
    expect(fake.currentTag, t[0]);
    expect(handler.isPlaying, isTrue);

    // Native gapless advance, e.g. while the app is in the background.
    fake.simulateAutoAdvance();
    await pumpEventQueue();
    expect(handler.currentTrack, t[1]);
    expect(handler.nowPlaying.value, fake.currentTag);
    expect(handler.queueSnapshot.currentIndex, 1);
    expect(handler.mediaItem.value?.id, t[1].id);

    await handler.dispose();
  });

  test('a song still downloading changes nothing until it is ready', () async {
    final t = await downloaded(['pb-prep-a', 'pb-prep-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    final gate = Completer<void>();
    server.serveGated('pb-prep-x', gate);
    final x = serverTrack(server, 'pb-prep-x', title: 'x');

    final pending = handler.playTrack(x);
    await waitFor(() => handler.preparing.value?.id == x.id);

    // Still showing — and playing — the old song.
    expect(handler.currentTrack, t[0]);
    expect(fake.currentTag, t[0]);
    expect(fake.setSourceCalls, 1);

    gate.complete();
    await pending;

    expect(handler.currentTrack, x);
    expect(fake.currentTag, x);
    expect(handler.preparing.value, isNull);

    await handler.dispose();
  });

  test('a failed download leaves playback untouched and says so', () async {
    final t = await downloaded(['pb-fail-a']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    final messages = <String>[];
    final sub = handler.messages.listen(messages.add);
    await handler.playTrack(t[0], queue: t);

    server.serveError('pb-fail-x');
    await handler.playTrack(serverTrack(server, 'pb-fail-x'));
    await pumpEventQueue();

    expect(handler.currentTrack, t[0]);
    expect(fake.currentTag, t[0]);
    expect(handler.preparing.value, isNull);
    expect(messages.single, contains('下载失败'));

    await sub.cancel();
    await handler.dispose();
  });

  test('a newer request wins over a slower older one', () async {
    final t = await downloaded(['pb-race-a', 'pb-race-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    final gate = Completer<void>();
    server.serveGated('pb-race-slow', gate);
    final slow = handler.playTrack(serverTrack(server, 'pb-race-slow'));
    await handler.playTrack(t[1], queue: t);
    expect(handler.currentTrack, t[1]);

    gate.complete();
    await slow;
    await pumpEventQueue();
    expect(handler.currentTrack, t[1]);
    expect(fake.currentTag, t[1]);

    await handler.dispose();
  });

  test('a failed install does not switch the display', () async {
    final t = await downloaded(['pb-inst-a', 'pb-inst-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    fake.failNextSource = true;
    await handler.playTrack(t[1], queue: t);
    expect(handler.currentTrack, t[0]);
    expect(fake.currentTag, t[0]);

    await handler.dispose();
  });

  test('rapid Next presses each move one track', () async {
    final t =
        await downloaded(['pb-next-a', 'pb-next-b', 'pb-next-c', 'pb-next-d']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    await Future.wait([handler.skipToNext(), handler.skipToNext()]);
    await pumpEventQueue();
    expect(handler.currentTrack, t[2]);
    expect(fake.currentTag, t[2]);

    await handler.dispose();
  });

  test('Previous restarts the song after 3 seconds, else goes back', () async {
    final t = await downloaded(['pb-prev-a', 'pb-prev-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[1], queue: t);

    fake.positionValue = const Duration(seconds: 30);
    await handler.skipToPrevious();
    expect(handler.currentTrack, t[1]);
    expect(fake.positionValue, Duration.zero);

    await handler.skipToPrevious();
    await pumpEventQueue();
    expect(handler.currentTrack, t[0]);

    await handler.dispose();
  });

  test('collections queue only downloaded songs', () async {
    final t = await downloaded(['pb-coll-a', 'pb-coll-b']);
    final notDownloaded = serverTrack(server, 'pb-coll-missing');
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);

    await handler.playCollection([t[0], notDownloaded, t[1]]);
    expect(queueIds(handler), [t[0].id, t[1].id]);
    expect(handler.loopMode, LoopMode.all);

    await handler.dispose();
  });

  test('the session survives a restart, paused, at the same position',
      () async {
    final t = await downloaded(['pb-sess-a', 'pb-sess-b', 'pb-sess-c']);
    final first = FakeAudioPlayer();
    final before = handlerFor(first);
    await before.playTrack(t[1], queue: t);
    await before.setLoopMode(LoopMode.one);
    first.positionValue = const Duration(seconds: 42);
    await before.saveSession();
    await before.dispose();

    final second = FakeAudioPlayer();
    final after = handlerFor(second);
    await after.restoreSession();

    expect(after.currentTrack, t[1]);
    expect(queueIds(after), [t[0].id, t[1].id, t[2].id]);
    expect(second.positionValue, const Duration(seconds: 42));
    expect(second.playing, isFalse);
    expect(after.loopMode, LoopMode.one);

    await after.dispose();
  });

  test('deleting a download removes it from the queue', () async {
    final t = await downloaded(['pb-del-a', 'pb-del-b', 'pb-del-c']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    await DatabaseService.removeDownloadedTrack(t[2]);
    await waitFor(() => !queueIds(handler).contains(t[2].id));
    expect(queueIds(handler), [t[0].id, t[1].id]);
    expect(handler.currentTrack, t[0]);

    await handler.dispose();
  });

  test('a listen is counted once enough of the song is heard', () async {
    final t = await downloaded(['pb-count-a']);
    final fake = FakeAudioPlayer()
      ..durationValue = const Duration(seconds: 10);
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);
    Future<int> plays() async =>
        (await DatabaseService.getPlayStats())[t[0].id]?.count ?? 0;

    // A seek far ahead is not listening.
    fake.emitPosition(Duration.zero);
    fake.emitPosition(const Duration(seconds: 8));
    await pumpEventQueue();
    expect(await plays(), 0);

    for (var ms = 0; ms <= 6000; ms += 500) {
      fake.emitPosition(Duration(milliseconds: ms));
    }
    await waitForTrue(() async => await plays() == 1);
    // And only once per play.
    fake.emitPosition(const Duration(seconds: 7));
    fake.emitPosition(const Duration(milliseconds: 7500));
    await pumpEventQueue();
    expect(await plays(), 1);

    await handler.dispose();
  });

  test('a trimmed song starts and ends where it was cut', () async {
    final t = await downloaded(['pb-trim-a', 'pb-trim-b']);
    await TrimStore.set(t[0].id,
        const Trim(start: Duration(seconds: 12), end: Duration(seconds: 150)));
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    fake.emitPosition(Duration.zero);
    await waitFor(() => fake.positionValue == const Duration(seconds: 12));

    // Seeking back into the intro by hand is allowed.
    await handler.seek(const Duration(seconds: 3));
    fake.emitPosition(const Duration(seconds: 3));
    await pumpEventQueue();
    expect(fake.positionValue, const Duration(seconds: 3));

    fake.emitPosition(const Duration(seconds: 150));
    await waitFor(() => handler.currentTrack == t[1]);

    await TrimStore.set(t[0].id, null);
    await handler.dispose();
  });

  test('play modes cycle 列表循环 → 单曲循环 → 随机 → 列表循环', () async {
    final t = await downloaded(['pb-mode-a', 'pb-mode-b', 'pb-mode-c']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[1], queue: t);

    await handler.cyclePlayMode();
    expect(handler.loopMode, LoopMode.one);
    expect(fake.nativeLoopMode, ja.LoopMode.one);

    await handler.cyclePlayMode();
    expect(handler.isShuffle, isTrue);
    expect(handler.loopMode, LoopMode.all);
    // The playing song leads the shuffled order and stays current.
    expect(handler.queueSnapshot.currentIndex, 0);
    expect(handler.currentTrack, t[1]);

    await handler.cyclePlayMode();
    expect(handler.isShuffle, isFalse);
    expect(handler.loopMode, LoopMode.all);
    expect(handler.currentTrack, t[1]);

    await handler.dispose();
  });

  test('lyric editing repeats the current song instead of moving on', () async {
    final t = await downloaded(['pb-hold-a', 'pb-hold-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);
    expect(fake.nativeLoopMode, ja.LoopMode.all);

    final release = handler.holdAutoAdvance();
    await pumpEventQueue();
    expect(fake.nativeLoopMode, ja.LoopMode.one);
    fake.simulateAutoAdvance();
    await pumpEventQueue();
    expect(handler.currentTrack, t[0]);

    release();
    await pumpEventQueue();
    expect(fake.nativeLoopMode, ja.LoopMode.all);
    // The user-facing mode never changed.
    expect(handler.loopMode, LoopMode.all);

    await handler.dispose();
  });

  test('end of a non-looping queue parks paused at the start', () async {
    final t = await downloaded(['pb-end-a', 'pb-end-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[1], queue: t);
    await handler.setLoopMode(LoopMode.off);

    fake.simulateCompleted();
    await waitFor(() => !handler.isPlaying);
    await pumpEventQueue();
    expect(handler.currentTrack, t[0]);

    await handler.dispose();
  });

  test('duration sleep timer pauses and resets', () async {
    final t = await downloaded(['pb-sleep-a']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(milliseconds: 200),
    );
    expect(handler.sleepTimerState.isActive, isTrue);

    await waitFor(() => !handler.isPlaying);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);

    await handler.dispose();
  });

  test('end-of-track sleep timer pauses at the song boundary', () async {
    final t = await downloaded(['pb-eot-a', 'pb-eot-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    handler.setSleepTimer(SleepTimerMode.endOfTrack);
    fake.emitPosition(const Duration(seconds: 199, milliseconds: 850));
    await waitFor(() => !handler.isPlaying);

    expect(handler.currentTrack, t[0]);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);

    await handler.dispose();
  });

  test('each track plays at the volume its loudness calls for', () async {
    final t = await downloaded(['pb-loud-a', 'pb-loud-b']);
    await DatabaseService.setTrackLoudness(t[0].id, -8);
    await DatabaseService.setTrackLoudness(t[1].id, -14);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);

    await handler.playTrack(t[0], queue: t);
    // −8 LUFS → −6 dB to reach the −14 target: half amplitude.
    expect(fake.volumeValue, closeTo(0.501, 0.005));

    fake.simulateAutoAdvance();
    await pumpEventQueue();
    expect(fake.volumeValue, 1.0);

    await handler.setNormalizeVolume(false);
    fake.simulateAutoAdvance();
    await pumpEventQueue();
    expect(handler.currentTrack, t[0]);
    expect(fake.volumeValue, 1.0, reason: 'switched off, nothing is cut');

    await handler.setNormalizeVolume(true);
    await handler.dispose();
  });

  test('an unmeasured download gets its loudness the first time it plays',
      () async {
    final t = await downloaded(['pb-backfill-a']);
    final fake = FakeAudioPlayer();
    var lookups = 0;
    final handler = BiliBeatsAudioHandler(
      player: fake,
      manageAudioSession: false,
      loudnessLookup: (bvid, cid) async {
        lookups++;
        return -8.0;
      },
    );

    await handler.playTrack(t[0], queue: t);
    await waitFor(() => handler.currentTrack?.loudness == -8.0);
    expect(fake.volumeValue, closeTo(0.501, 0.005));
    final stored = (await DatabaseService.getDownloadedTracks())
        .firstWhere((track) => track.id == t[0].id);
    expect(stored.loudness, -8.0);

    // Asked once, not on every play.
    await handler.playTrack(t[0], queue: t);
    await pumpEventQueue();
    expect(lookups, 1);

    await handler.dispose();
  });

  test('play after stop carries on with the same queue', () async {
    final t = await downloaded(['pb-stop-a', 'pb-stop-b']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[1], queue: t);

    await handler.stop();
    expect(fake.playing, isFalse);
    await handler.play();
    await pumpEventQueue();
    expect(fake.playing, isTrue);
    expect(handler.currentTrack, t[1]);

    await handler.dispose();
  });

  test('play pressed while the session is still restoring is not lost',
      () async {
    final t = await downloaded(['pb-cold-a', 'pb-cold-b']);
    final first = handlerFor(FakeAudioPlayer());
    await first.playTrack(t[1], queue: t);
    await first.saveSession();
    await first.dispose();

    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    // The launch starts the restore; a headset button presses play at once.
    unawaited(handler.restoreSession());
    await handler.play();
    await pumpEventQueue();
    expect(handler.currentTrack, t[1]);
    expect(fake.playing, isTrue);

    await handler.dispose();
  });

  test('removing the only queued song leaves nothing playing', () async {
    final t = await downloaded(['pb-only-a']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[0], queue: t);

    await handler.removeTracks({t[0].id});
    await pumpEventQueue();
    expect(handler.currentTrack, isNull);
    expect(queueIds(handler), isEmpty);

    await handler.dispose();
  });

  test('removing a song before the playing one keeps the playing one',
      () async {
    final t = await downloaded(['pb-rm-a', 'pb-rm-b', 'pb-rm-c']);
    final fake = FakeAudioPlayer();
    final handler = handlerFor(fake);
    await handler.playTrack(t[1], queue: t);

    await handler.removeTracks({t[0].id});
    await pumpEventQueue();
    expect(handler.currentTrack, t[1]);
    expect(queueIds(handler), [t[1].id, t[2].id]);

    await handler.dispose();
  });
}
