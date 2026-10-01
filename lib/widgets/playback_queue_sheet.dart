import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import 'empty_state.dart';
import 'sheet.dart';
import 'song_tile.dart';

/// What the player is queued to play, in play order.
///
/// Rows render [PlaybackQueueSnapshot] exactly as the handler publishes it
/// (itself read from the native player), so the highlighted row is always
/// the song that is actually playing. Tap a row to jump to it.
class PlaybackQueueSheet extends StatefulWidget {
  const PlaybackQueueSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showAppSheet<void>(
      context,
      expand: true,
      builder: (_) => const PlaybackQueueSheet(),
    );
  }

  @override
  State<PlaybackQueueSheet> createState() => _PlaybackQueueSheetState();
}

class _PlaybackQueueSheetState extends State<PlaybackQueueSheet> {
  BiliBeatAudioHandler get _handler => AppServices.instance.handler;

  // Open at the current song, not the top of a possibly very long queue.
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _handler.queueSnapshot.currentIndex > 1
        ? (_handler.queueSnapshot.currentIndex - 1) * SongTile.extent
        : 0,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _select(String trackId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _handler.selectQueueTrack(trackId);
    } catch (error, stack) {
      debugPrint('Queue selection failed: $error\n$stack');
      showAppSnackBar(messenger, message: '暂时无法切换，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlaybackQueueSnapshot>(
      valueListenable: _handler.queueNotifier,
      builder: (context, snapshot, _) {
        return Column(
          children: [
            SheetTitle(
              '播放队列',
              detail: snapshot.tracks.isEmpty
                  ? null
                  : '${snapshot.currentIndex + 1} / ${snapshot.tracks.length}',
            ),
            Expanded(
              child: snapshot.tracks.isEmpty
                  ? const EmptyState(
                      icon: Icons.queue_music_rounded,
                      title: '队列为空',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemExtent: SongTile.extent,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: snapshot.tracks.length,
                      itemBuilder: (context, index) {
                        final track = snapshot.tracks[index];
                        final current = index == snapshot.currentIndex;
                        return Semantics(
                          key: ValueKey(track.id),
                          selected: current,
                          child: SongTile(
                            track: track,
                            // Tapping the current song does not restart it.
                            onTap: current ? null : () => _select(track.id),
                            trailing: current
                                ? const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 14),
                                    child: Icon(Icons.graphic_eq_rounded,
                                        color: AppColors.accent, size: 20),
                                  )
                                : const SizedBox(width: 8),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
