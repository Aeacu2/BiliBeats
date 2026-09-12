import 'package:flutter/material.dart';

import '../models/track.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import 'cached_cover_image.dart';
import 'marquee_text.dart';

/// A quiet, persistent listening surface.
///
/// Progress is intentionally display-only. Seeking lives in the full
/// player, where it can have a proper accessible interaction target.
class MiniPlayer extends StatelessWidget {
  final Track? currentTrack;
  final bool isPlaying;

  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration> durationNotifier;

  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback? onPrevious;
  final VoidCallback onTap;
  final ValueChanged<Duration>? onSeek;

  const MiniPlayer({
    super.key,
    required this.currentTrack,
    required this.isPlaying,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.onPlayPause,
    required this.onNext,
    this.onPrevious,
    required this.onTap,
    this.onSeek,
  });

  static const double contentHeight = 76;
  static const double _artSize = 48;

  static const BorderRadius cardRadius = BorderRadius.vertical(
    top: Radius.circular(AppRadius.md),
  );

  static double bottomInset(BuildContext context) {
    final inset = MediaQuery.of(context).padding.bottom;
    return inset > 0 ? inset : 8;
  }

  static double _contentHeightFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);

    final additionalHeight =
        (scaler.scale(15) - 15) * 1.3 + (scaler.scale(12) - 12) * 1.35;

    return contentHeight + (additionalHeight > 0 ? additionalHeight : 0);
  }

  static double totalHeight(BuildContext context) {
    return _contentHeightFor(context) + bottomInset(context);
  }

  @override
  Widget build(BuildContext context) {
    final track = currentTrack;

    return ClipRRect(
      borderRadius: cardRadius,
      child: Material(
        color: AppColors.backgroundElevated,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            borderRadius: cardRadius,
            border: Border(
              top: BorderSide(color: AppColors.hairlineStrong),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: bottomInset(context),
            ),
            child: SizedBox(
              height: _contentHeightFor(context),
              child: track == null ? _emptyState() : _activePlayer(track),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Container(
            width: _artSize,
            height: _artSize,
            decoration: BoxDecoration(
              color: AppColors.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(
              Icons.music_note_rounded,
              color: AppColors.textMuted,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '选择一首，开始聆听',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _activePlayer(Track track) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 3, 12, 5),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: '打开播放器：${track.title}，${track.uploader}',
                  child: ExcludeSemantics(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: onTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppRadius.sm,
                              ),
                              child: CachedCoverImage(
                                url: track.coverUrl,
                                width: _artSize,
                                height: _artSize,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MarqueeText(
                                    text: track.title,
                                    style: AppTypography.body.copyWith(
                                      height: 1.3,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    track.uploader,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.caption.copyWith(
                                      height: 1.35,
                                    ),
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
              const SizedBox(width: 8),
              _transportButton(
                tooltip: isPlaying ? '暂停' : '播放',
                icon:
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                primary: true,
                onPressed: () {
                  Haptics.light();
                  onPlayPause();
                },
              ),
              _transportButton(
                tooltip: '下一首',
                icon: Icons.skip_next_rounded,
                onPressed: () {
                  Haptics.selection();
                  onNext();
                },
              ),
            ],
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 0,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: _MiniProgress(
                positionNotifier: positionNotifier,
                durationNotifier: durationNotifier,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _transportButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    bool primary = false,
  }) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        icon: Icon(
          icon,
          size: primary ? 32 : 27,
          color: primary ? AppColors.textPrimary : AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _MiniProgress extends StatelessWidget {
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration> durationNotifier;

  const _MiniProgress({
    required this.positionNotifier,
    required this.durationNotifier,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        positionNotifier,
        durationNotifier,
      ]),
      builder: (context, _) {
        final total = durationNotifier.value.inMilliseconds;

        final fraction = total <= 0
            ? 0.0
            : (positionNotifier.value.inMilliseconds / total)
                .clamp(0.0, 1.0)
                .toDouble();

        return ClipRRect(
          borderRadius: BorderRadius.circular(1),
          child: SizedBox(
            height: 2,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: AppColors.hairline),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fraction,
                    heightFactor: 1,
                    child: const ColoredBox(
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
