import 'package:flutter/material.dart';

import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import 'cached_cover_image.dart';
import 'empty_state.dart';
import 'marquee_text.dart';
import 'track_row.dart';

/// Read-only view of what the player is queued to play, in play order.
///
/// Rows render [PlaybackQueueSnapshot] exactly as the handler publishes it
/// (which is itself read from the native player), so the highlighted row is
/// always the song that is actually playing.
class PlaybackQueueSheet extends StatefulWidget {
  final BiliBeatAudioHandler handler;

  const PlaybackQueueSheet({
    super.key,
    required this.handler,
  });

  static Future<void> show(
    BuildContext context, {
    required BiliBeatAudioHandler handler,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.backgroundElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      builder: (context) {
        return PlaybackQueueSheet(handler: handler);
      },
    );
  }

  @override
  State<PlaybackQueueSheet> createState() => _PlaybackQueueSheetState();
}

class _PlaybackQueueSheetState extends State<PlaybackQueueSheet> {
  BiliBeatAudioHandler get handler => widget.handler;

  // Open at the current song, not the top of a possibly very long queue.
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: handler.queueSnapshot.currentIndex > 2
        ? (handler.queueSnapshot.currentIndex - 2) * _rowExtent
        : 0,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Fixed row height: lets a long queue open scrolled to the current song
  /// without measuring every row.
  static const double _rowExtent = 64;

  String _modeLabel(PlaybackQueueSnapshot snapshot) {
    final order = snapshot.isShuffle ? '随机播放' : '顺序播放';

    final repeat = switch (snapshot.loopMode) {
      LoopMode.off => '不循环',
      LoopMode.all => '列表循环',
      LoopMode.one => '单曲循环',
    };

    return '$order · $repeat';
  }

  Future<void> _select(
    BuildContext context,
    String trackId,
  ) async {
    try {
      await handler.selectQueueTrack(trackId);
    } catch (error, stack) {
      debugPrint('Queue selection failed: $error\n$stack');

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('暂时无法切换曲目，请重试'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.78,
      child: SafeArea(
        top: false,
        child: ValueListenableBuilder<PlaybackQueueSnapshot>(
          valueListenable: handler.queueNotifier,
          builder: (context, snapshot, _) {

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '播放队列',
                              style: AppTypography.title,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _modeLabel(snapshot),
                              style: AppTypography.caption,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '共 ${snapshot.tracks.length} 首'
                              ' · 后续 ${snapshot.upcomingCount} 首',
                              style: AppTypography.caption,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: snapshot.tracks.isEmpty
                      ? const Center(
                          child: EmptyState(
                            icon: Icons.queue_music_rounded,
                            title: '队列为空',
                            subtitle: '播放歌曲后，会在这里显示',
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: _rowExtent,
                          padding: const EdgeInsets.fromLTRB(
                            20,
                            0,
                            20,
                            24,
                          ),
                          itemCount: snapshot.tracks.length,
                          itemBuilder: (context, index) {
                            final track = snapshot.tracks[index];
                            final current = index == snapshot.currentIndex;

                            return Padding(
                              key: ValueKey(track.id),
                              padding: const EdgeInsets.only(
                                bottom: TrackRow.gap,
                              ),
                              child: Semantics(
                                selected: current,
                                child: TrackRow(
                                  // "Current" describes logical selection,
                                  // not whether playback is audible.
                                  //
                                  // Tapping it does not restart the song.
                                  onTap: current
                                      ? null
                                      : () => _select(context, track.id),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          AppRadius.sm,
                                        ),
                                        child: CachedCoverImage(
                                          url: track.coverUrl,
                                          width: 48,
                                          height: 48,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            MarqueeText(
                                              text: track.title,
                                              phase: (index % 5) / 5,
                                              style:
                                                  AppTypography.body.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              track.uploader,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppTypography.caption,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      if (current)
                                        const Text(
                                          '当前',
                                          style: TextStyle(
                                            color: AppColors.accent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        )
                                      else
                                        Text(
                                          '${index + 1}',
                                          style: AppTypography.caption,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
