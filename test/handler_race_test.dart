import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

/// Instrumented verification for the playback-ownership patch plus the
/// rapid-skip intent refinement and queue-snapshot publication.
///
/// Every race uses deterministic gates (blocked downloads, install delays,
/// pending play futures) — never wall-clock sleeps for synchronization.
/// Track ids are unique per test: download memoization is process-static.
void main() {
  late LocalAudioServer server;

  setUpAll(() async {
    await stubDocs('handler_race');
    useRealHttp();
    server = await LocalAudioServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  Track t(String name) => serverTrack(server, name, title: 'song $name');

  BiliBeatAudioHandler handlerWith(FakeAudioPlayer fake) =>
      BiliBeatAudioHandler(player: fake);

  Future<void> settleTo(
    BiliBeatAudioHandler handler,
    Track track, {
    List<Track>? queue,
  }) async {
    await handler.playTrack(track, newQueue: queue);
    await waitFor(() => handler.queueSnapshot.currentTrack?.id == track.id);
  }

  group('gate ownership', () {
    test('normal start releases the gate while playing', () async {
      const name = 'g1-normal';
      server.serveInstant(name);
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);

      await settleTo(handler, t(name));

      // If the play lifetime owned the gate, this would hang.
      await handler.pause().timeout(const Duration(seconds: 5));
      expect(fake.pauseCalls, 1);
      expect(handler.queueSnapshot.currentTrack?.id, 'ht-$name');
    });

    test('slow A cannot delay or defeat fast B', () async {
      const a = 'g2-slow-a';
      const b = 'g2-fast-b';
      final gateA = Completer<void>();
      server.serveGated(a, gateA);
      server.serveInstant(b);
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);

      final trackA = t(a);
      final trackB = t(b);
      final futureA = handler.playTrack(trackA, newQueue: [trackA, trackB]);
      await waitFor(() => server.requested.contains(a));

      await handler.playTrack(trackB);
      gateA.complete();
      await futureA;

      await waitFor(() => handler.queueSnapshot.currentTrack?.id == trackB.id);
      expect(handler.queueSnapshot.currentTrack?.id, trackB.id);
      // Only B ever launched playback; A's late download was dropped.
      expect(fake.playCalls, 1);
    });

    test('supersession during native installation keeps the newest', () async {
      const a = 'g3-inst-a';
      const b = 'g3-inst-b';
      server.serveInstant(a);
      server.serveInstant(b);
      final fake = FakeAudioPlayer()
        ..setSourceDelay = const Duration(milliseconds: 300);
      final handler = handlerWith(fake);

      final trackA = t(a);
      final trackB = t(b);
      final futureA = handler.playTrack(trackA, newQueue: [trackA, trackB]);
      // B must win while A's native installation is still in flight.
      await waitFor(() => fake.setSourceCalls == 1);
      await handler.playTrack(trackB);
      await futureA;

      await waitFor(() => handler.queueSnapshot.currentTrack?.id == trackB.id);
      expect(handler.queueSnapshot.currentTrack?.id, trackB.id);
      expect(fake.playCalls, 1);
    });

    test('pause during download prepares without autoplaying', () async {
      const a = 'g4-pause-dl';
      final gate = Completer<void>();
      server.serveGated(a, gate);
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);

      final trackA = t(a);
      final future = handler.playTrack(trackA, newQueue: [trackA]);
      await waitFor(() => server.requested.contains(a));
      await handler.pause();
      gate.complete();
      await future;

      await waitFor(() => handler.queueSnapshot.currentTrack?.id == trackA.id);
      expect(fake.playCalls, 0);
      expect(handler.queueSnapshot.currentTrack?.id, trackA.id);
    });

    test('stop during preparation cannot restart playback', () async {
      const a = 'g5-stop-prep';
      final gate = Completer<void>();
      server.serveGated(a, gate);
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);

      final trackA = t(a);
      final future = handler.playTrack(trackA, newQueue: [trackA]);
      await waitFor(() => server.requested.contains(a));
      await handler.stop();
      gate.complete();
      await future;
      // Let any stragglers land: event turns, not wall time.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(fake.playCalls, 0);
      expect(fake.stopCalls, greaterThanOrEqualTo(1));
    });

    test('failed install publishes error but keeps the gate usable', () async {
      const a = 'g6-fail-a';
      const b = 'g6-fail-b';
      server.serveInstant(a);
      server.serveInstant(b);
      final fake = FakeAudioPlayer()..failSourceOnce = true;
      final handler = handlerWith(fake);

      await handler.playTrack(t(a), newQueue: [t(a)]);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.error);

      // The serialization chain is not poisoned: the next start works.
      await settleTo(handler, t(b), queue: [t(b)]);
      expect(handler.queueSnapshot.currentTrack?.id, 'ht-$b');
    });

    test('stale play-lifetime error cannot overwrite the session', () async {
      const a = 'g7-lifetime';
      server.serveInstant(a);
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);

      fake.gatePlayLifetime = Completer<void>();
      final trackA = t(a);
      final future = handler.playTrack(trackA, newQueue: [trackA]);
      await waitFor(() => handler.queueSnapshot.currentTrack?.id == trackA.id);
      // The error below must have a listener: wait until the install
      // actually launched playback (attaching the lifetime handler).
      // Pausing first would skip the launch, leaving an orphaned gate
      // whose error has nowhere to go (a test-only artifact).
      await waitFor(() => fake.playCalls == 1);
      // Supersede, then fail the old lifetime.
      await handler.pause();
      fake.gatePlayLifetime!.completeError(Exception('boom'));
      await future;
      // Let the (dropped) report settle: event turns, not wall time.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(handler.playbackState.value.processingState,
          isNot(AudioProcessingState.error));

      // A current lifetime error is still reported.
      fake.gatePlayLifetime = Completer<void>();
      await handler.play();
      fake.gatePlayLifetime!.completeError(Exception('real'));
      await waitFor(() =>
          handler.playbackState.value.processingState ==
          AudioProcessingState.error);
    });
  });

  group('rapid-skip intents', () {
    test('three rapid Next presses advance three tracks', () async {
      const base = 'g8-rapid';
      final names = ['a', 'b', 'c', 'd'].map((s) => '$base-$s').toList();
      for (final n in names) {
        server.serveInstant(n);
      }
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = names.map(t).toList();

      await settleTo(handler, tracks[0], queue: tracks);

      final f1 = handler.skipToNext();
      final f2 = handler.skipToNext();
      final f3 = handler.skipToNext();
      await Future.wait([f1, f2, f3]);

      await waitFor(
          () => handler.queueSnapshot.currentTrack?.id == tracks[3].id);
      expect(handler.queueSnapshot.currentTrack?.id, tracks[3].id);
    });

    test('two rapid Previous presses move back two', () async {
      const base = 'g9-rprev';
      final names = ['a', 'b', 'c', 'd'].map((s) => '$base-$s').toList();
      for (final n in names) {
        server.serveInstant(n);
      }
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = names.map(t).toList();

      await settleTo(handler, tracks[3], queue: tracks);

      final f1 = handler.skipToPrevious();
      final f2 = handler.skipToPrevious();
      await Future.wait([f1, f2]);

      await waitFor(
          () => handler.queueSnapshot.currentTrack?.id == tracks[1].id);
      expect(handler.queueSnapshot.currentTrack?.id, tracks[1].id);
    });

    test('tap then immediate Next resolves to latest-wins Next', () async {
      const base = 'g10-tapskip';
      final names = ['a', 'b', 'c'].map((s) => '$base-$s').toList();
      for (final n in names) {
        server.serveInstant(n);
      }
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = names.map(t).toList();

      await settleTo(handler, tracks[0], queue: tracks);

      // The tap never lands: the newer skip intent wins, relative to the
      // still-current track.
      final tap = handler.playTrack(tracks[2]);
      final skip = handler.skipToNext();
      await Future.wait([tap, skip]);

      await waitFor(
          () => handler.queueSnapshot.currentTrack?.id == tracks[1].id);
      expect(handler.queueSnapshot.currentTrack?.id, tracks[1].id);
    });

    test('end of non-looping queue seeks home and pauses once', () async {
      const base = 'g11-end';
      final names = ['a', 'b'].map((s) => '$base-$s').toList();
      for (final n in names) {
        server.serveInstant(n);
      }
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = names.map(t).toList();

      await handler.setLoopMode(LoopMode.off);
      await settleTo(handler, tracks[1], queue: tracks);

      await handler.skipToNext();

      expect(fake.pauseCalls, greaterThanOrEqualTo(1));
      expect(fake.positionValue, Duration.zero);
    });
  });

  group('queue publication', () {
    test('replacement arrives as one consistent snapshot', () async {
      const base = 'g12-repl';
      for (final s in ['a', 'b']) {
        server.serveInstant('$base-$s');
      }
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = ['a', 'b'].map((s) => t('$base-$s')).toList();

      await settleTo(handler, tracks[0], queue: tracks);

      final snap = handler.queueSnapshot;
      expect(snap.tracks.map((e) => e.id), [tracks[0].id, tracks[1].id]);
      expect(snap.currentIndex, 0);
      expect(snap.upcomingCount, 1);
    });

    test('system queue mirrors snapshot order', () async {
      const base = 'g13-sysq';
      for (final s in ['a', 'b']) {
        server.serveInstant('$base-$s');
      }
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = ['a', 'b'].map((s) => t('$base-$s')).toList();

      await settleTo(handler, tracks[0], queue: tracks);

      final items = handler.queue.valueOrNull ?? const [];
      expect(items.map((e) => e.id), [tracks[0].id, tracks[1].id]);
    });

    test('metadata edit republishes without reselecting', () async {
      const base = 'g14-meta';
      server.serveInstant('$base-a');
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final trackA = t('$base-a');

      await settleTo(handler, trackA, queue: [trackA]);

      handler.updateCurrentTrackMetadata(
        trackA.copyWith(title: 'renamed'),
      );
      await waitFor(
          () => handler.queueSnapshot.currentTrack?.title == 'renamed');
      expect(handler.queueSnapshot.currentIndex, 0);
    });

    test('mode-only change publishes a combined snapshot', () async {
      const base = 'g15-mode';
      server.serveInstant('$base-a');
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);

      await settleTo(handler, t('$base-a'), queue: [t('$base-a')]);
      await handler.setLoopMode(LoopMode.one);

      await waitFor(() => handler.queueSnapshot.loopMode == LoopMode.one);
    });

    test('id selection survives reorder; removed ids are ignored', () async {
      const base = 'g16-sel';
      for (final s in ['a', 'b', 'c']) {
        server.serveInstant('$base-$s');
      }
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = ['a', 'b', 'c'].map((s) => t('$base-$s')).toList();

      await settleTo(handler, tracks[0], queue: tracks);
      await handler.selectQueueTrack(tracks[2].id);

      await waitFor(
          () => handler.queueSnapshot.currentTrack?.id == tracks[2].id);
      expect(handler.queueSnapshot.currentTrack?.id, tracks[2].id);

      await handler.selectQueueTrack('missing-id');
      expect(handler.queueSnapshot.currentTrack?.id, tracks[2].id);
    });

    test('native advance follows tags; prefetch emits no snapshot', () async {
      const base = 'g17-adv';
      final gateC = Completer<void>();
      server.serveInstant('$base-a');
      server.serveInstant('$base-b');
      server.serveGated('$base-c', gateC);
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final tracks = ['a', 'b', 'c'].map((s) => t('$base-$s')).toList();

      final emissions = <PlaybackQueueSnapshot>[];
      final sub = handler.queueSnapshotStream.listen(emissions.add);

      await settleTo(handler, tracks[0], queue: tracks);
      await handler.skipToNext();
      await waitFor(
          () => handler.queueSnapshot.currentTrack?.id == tracks[1].id);

      final marked = emissions.length;
      // Prefetch of C is still gated: completing nothing must change
      // the logical snapshot.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(emissions.length, marked);

      gateC.complete();
      // Wait for the prefetch download, then the native window holds C.
      await waitFor(() => server.requested.contains('$base-c'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(emissions.length, marked);

      fake.simulateAdvance(1);
      await waitFor(
          () => handler.queueSnapshot.currentTrack?.id == tracks[2].id);
      expect(handler.queueSnapshot.currentTrack?.id, tracks[2].id);
      await sub.cancel();
    });
  });

  group('failure restore', () {
    test('failed start falls back to the intact previous track', () async {
      const base = 'g18-restore';
      server.serveInstant('$base-a');
      final fake = FakeAudioPlayer();
      final handler = handlerWith(fake);
      final trackA = t('$base-a');

      await settleTo(handler, trackA, queue: [trackA]);

      const bad = Track(
        id: '',
        bvid: '',
        cid: 0,
        title: 'bad',
        rawTitle: 'bad',
        uploader: 'uploader',
        coverUrl: '',
        duration: 10,
      );
      await handler.playTrack(bad);

      await waitFor(() => handler.queueSnapshot.currentTrack?.id == trackA.id);
      expect(handler.queueSnapshot.currentTrack?.id, trackA.id);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.error);
    });
  });
}
