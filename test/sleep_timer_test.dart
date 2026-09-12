import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

/// Sleep timer verification (M5 §4, M2 §6.2): implemented in the handler,
/// never a screen timer. Short durations stand in for 15/30/60 minutes;
/// the mechanism (one-shot + transport-cancelled pause) is identical.
void main() {
  late LocalAudioServer server;

  setUpAll(() async {
    await stubDocs('sleep_timer');
    useRealHttp();
    server = await LocalAudioServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  Future<BiliBeatAudioHandler> playing(
    FakeAudioPlayer fake,
    List<String> names,
  ) async {
    for (final n in names) {
      server.serveInstant(n);
    }
    final handler = BiliBeatAudioHandler(player: fake);
    final tracks =
        names.map((n) => serverTrack(server, n)).toList();
    await handler.playTrack(tracks.first, newQueue: tracks);
    // Settle past the launch: the playing flag arrives via stream.
    await waitFor(() => handler.isPlaying);
    return handler;
  }

  test('duration timer pauses and resets', () async {
    final fake = FakeAudioPlayer();
    final handler = await playing(fake, ['sl-dur-a']);

    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(milliseconds: 300),
    );
    expect(handler.sleepTimerState.isActive, isTrue);

    await waitFor(() => !handler.isPlaying);
    expect(handler.isPlaying, isFalse);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);
  });

  test('end-of-track pauses instead of advancing', () async {
    final fake = FakeAudioPlayer();
    final handler =
        await playing(fake, ['sl-eot-a', 'sl-eot-b']);
    final firstId = handler.currentTrack!.id;

    handler.setSleepTimer(SleepTimerMode.endOfTrack);
    expect(handler.sleepTimerState.isActive, isTrue);

    fake.simulateCompletion();
    await waitFor(() => !handler.isPlaying);

    expect(handler.currentTrack?.id, firstId);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);
  });

  test('cancel clears a pending timer', () async {
    final fake = FakeAudioPlayer();
    final handler = await playing(fake, ['sl-cancel-a']);

    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(milliseconds: 300),
    );
    handler.setSleepTimer(SleepTimerMode.off);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(handler.isPlaying, isTrue);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);
  });

  test('replacing a timer supersedes the old one', () async {
    final fake = FakeAudioPlayer();
    final handler = await playing(fake, ['sl-replace-a']);

    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(minutes: 5),
    );
    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(milliseconds: 200),
    );

    await waitFor(() => !handler.isPlaying);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);
  });

  test('duration timer survives track changes', () async {
    final fake = FakeAudioPlayer();
    final handler =
        await playing(fake, ['sl-survive-a', 'sl-survive-b']);

    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(milliseconds: 400),
    );
    await handler.skipToNext();
    final secondId = handler.currentTrack!.id;

    await waitFor(() => !handler.isPlaying);
    expect(handler.currentTrack?.id, secondId);
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);
  });

  test('state stream reports arming, countdown, and reset', () async {
    final fake = FakeAudioPlayer();
    final handler = await playing(fake, ['sl-stream-a']);

    final states = <SleepTimerState>[];
    final sub = handler.sleepTimerStream.listen(states.add);

    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(milliseconds: 300),
    );
    // Wait for the stream (not just the field) to observe the reset:
    // broadcast delivery lags the synchronous state write under load.
    await waitFor(() =>
        states.isNotEmpty &&
        states.last.mode == SleepTimerMode.off);

    // Armed-active, then reset-off. (Per-second ticks may add more.)
    expect(
        states.any((s) => s.mode == SleepTimerMode.duration),
        isTrue);
    expect(states.last.mode, SleepTimerMode.off);
    await sub.cancel();
  });

  test('stop clears an armed timer', () async {
    final fake = FakeAudioPlayer();
    final handler = await playing(fake, ['sl-stop-a']);

    handler.setSleepTimer(
      SleepTimerMode.duration,
      duration: const Duration(milliseconds: 300),
    );
    await handler.stop();

    expect(handler.sleepTimerState.mode, SleepTimerMode.off);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // No stale firing resurrects anything.
    expect(handler.sleepTimerState.mode, SleepTimerMode.off);
  });
}
