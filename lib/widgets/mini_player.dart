import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import 'cached_cover_image.dart';

/// The docked player.
///
/// Everything it shows comes straight from the handler, which reads it from
/// the native player — so the card always names the song you hear. While a
/// requested song is still downloading, the card keeps showing the current
/// song and adds a quiet 正在准备 line instead of jumping ahead.
class MiniPlayer extends StatelessWidget {
  final BiliBeatAudioHandler handler;
  final VoidCallback onTap;

  const MiniPlayer({
    super.key,
    required this.handler,
    required this.onTap,
  });

  static const double _contentHeight = 64;
  static const double _art = 44;
  static const double _gutter = 8;

  static const BorderRadius cardRadius =
      BorderRadius.all(Radius.circular(AppRadius.md));

  static double _bottomInset(BuildContext context) {
    final inset = MediaQuery.of(context).padding.bottom;
    return inset > 0 ? inset : _gutter;
  }

  /// Height the shell reserves under its pages for the card.
  static double totalHeight(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final extra = (scaler.scale(15) - 15) + (scaler.scale(12) - 12);
    return _contentHeight + (extra > 0 ? extra : 0) + _bottomInset(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _gutter,
        0,
        _gutter,
        _bottomInset(context),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius: cardRadius,
          boxShadow: [
            BoxShadow(
              color: AppColors.black50,
              blurRadius: 20,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: cardRadius,
          child: Material(
            color: AppColors.fieldFill,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                handler.nowPlaying,
                handler.playingNotifier,
                handler.preparing,
              ]),
              builder: (context, _) {
                final track = handler.nowPlaying.value;
                final preparing = handler.preparing.value;
                return SizedBox(
                  height: totalHeight(context) - _bottomInset(context),
                  child: track == null
                      ? _empty(preparing)
                      : _active(track, preparing),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty(Track? preparing) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Container(
            width: _art,
            height: _art,
            decoration: BoxDecoration(
              color: AppColors.white06,
              borderRadius: BorderRadius.circular(AppRadius.sm - 2),
            ),
            child: const Icon(Icons.music_note_rounded,
                color: AppColors.textMuted, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              preparing != null
                  ? '正在准备「${preparing.title}」…'
                  : '选择一首歌，开始聆听',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _active(Track track, Track? preparing) {
    final playing = handler.playingNotifier.value;
    return Stack(
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: '打开播放器：${track.title}，${track.uploader}',
                child: ExcludeSemantics(
                  child: InkWell(
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(AppRadius.sm - 2),
                            child: CachedCoverImage(
                              url: track.coverUrl,
                              width: _art,
                              height: _art,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.body.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                preparing != null
                                    ? Row(
                                        children: [
                                          const SizedBox(
                                            width: 10,
                                            height: 10,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              '正在准备「${preparing.title}」',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppTypography.caption
                                                  .copyWith(
                                                color: AppColors.accent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      )
                                    : Text(
                                        track.uploader,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTypography.caption,
                                      ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _button(
              tooltip: playing ? '暂停' : '播放',
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 32,
              onPressed: () {
                Haptics.light();
                handler.togglePlayPause();
              },
            ),
            _button(
              tooltip: '下一首',
              icon: Icons.skip_next_rounded,
              size: 28,
              onPressed: () {
                Haptics.selection();
                handler.skipToNext();
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 0,
          child: IgnorePointer(child: _Progress(handler: handler)),
        ),
      ],
    );
  }

  Widget _button({
    required String tooltip,
    required IconData icon,
    required double size,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 44,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon, size: size, color: AppColors.textPrimary),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  final BiliBeatAudioHandler handler;

  const _Progress({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: handler.positionStream,
      initialData: handler.position,
      builder: (context, snapshot) {
        return ValueListenableBuilder<Duration>(
          valueListenable: handler.durationNotifier,
          builder: (context, duration, _) {
            final total = duration.inMilliseconds;
            final position = snapshot.data ?? Duration.zero;
            final fraction = total <= 0
                ? 0.0
                : (position.inMilliseconds / total).clamp(0.0, 1.0);
            return SizedBox(
              height: 2,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: AppColors.hairline),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction,
                    child: const ColoredBox(color: AppColors.textSecondary),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
