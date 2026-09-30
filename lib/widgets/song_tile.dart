import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/track.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import 'cached_cover_image.dart';
import 'track_download_button.dart';
import 'track_options_menu.dart';

/// The one song row.
///
/// Every list — library, playlists, search, recommendations — draws songs
/// with this, so a song looks and behaves the same wherever it appears. The
/// row that is actually playing is marked (read from the player, not
/// guessed from the last tap).
class SongTile extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;

  /// Leading widget override (e.g. a selection check in edit mode).
  final Widget? leading;

  /// Trailing override. By default: a download control for songs that are
  /// not downloaded ([showDownload]), then a "more" button.
  final Widget? trailing;

  /// Show a download/progress control for songs that are not downloaded.
  final bool showDownload;

  /// The queue the song's menu should play within.
  final List<Track>? queue;

  static const double artSize = 52;
  static const double extent = 68;

  const SongTile({
    super.key,
    required this.track,
    this.onTap,
    this.leading,
    this.trailing,
    this.showDownload = false,
    this.queue,
  });

  @override
  Widget build(BuildContext context) {
    final handler = AppServices.instance.handler;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => TrackOptionsMenu.show(context, track, queue: queue),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: SizedBox(
          height: extent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm - 2),
                  child: CachedCoverImage(
                    url: track.coverUrl,
                    width: artSize,
                    height: artSize,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: ListenableBuilder(
                    listenable: handler.nowPlaying,
                    builder: (context, _) {
                      final current = handler.nowPlaying.value?.id == track.id;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (current) ...[
                                const Icon(
                                  Icons.graphic_eq_rounded,
                                  size: 15,
                                  color: AppColors.accent,
                                ),
                                const SizedBox(width: 5),
                              ],
                              Expanded(
                                child: Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.body.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                    color: current
                                        ? AppColors.accent
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            track.duration > 0
                                ? '${track.uploader} · '
                                    '${formatDuration(Duration(seconds: track.duration))}'
                                : track.uploader,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption.copyWith(fontSize: 13),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                trailing ??
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showDownload)
                          TrackDownloadButton(track: track, size: 22),
                        _MoreButton(track: track, queue: queue),
                      ],
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  final Track track;
  final List<Track>? queue;

  const _MoreButton({required this.track, this.queue});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 48,
      child: IconButton(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        onPressed: () => TrackOptionsMenu.show(context, track, queue: queue),
        icon: const Icon(
          Icons.more_horiz_rounded,
          color: AppColors.textMuted,
          size: 22,
        ),
      ),
    );
  }
}
