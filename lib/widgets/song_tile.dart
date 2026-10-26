import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import 'cached_cover_image.dart';
import 'track_download_button.dart';
import 'track_sheet.dart';

/// The one song row.
///
/// Every list — library, playlists, search, queue — draws songs with this,
/// so a song looks and behaves the same wherever it appears. A row carries
/// two lines of text and a single control: a download button until the song
/// is on the device, then ⋯. The row that is actually playing is marked
/// (read from the player, not guessed from the last tap).
class SongTile extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;
  final bool showActions;

  /// Leading widget override (e.g. a selection check in edit mode).
  final Widget? leading;

  /// Replaces the default trailing control.
  final Widget? trailing;

  /// The queue the song's sheet should play within.
  final List<Track>? queue;

  /// Second line override (file size in download management, an error…).
  final String? detail;

  static const double artSize = 48;
  static const double extent = 64;

  const SongTile({
    super.key,
    required this.track,
    this.onTap,
    this.showActions = true,
    this.leading,
    this.trailing,
    this.queue,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final services = AppServices.instance;
    final handler = services.handler;

    // The row is a fixed height: its two lines may grow only so far.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: showActions
              ? () => TrackSheet.show(context, track, queue: queue)
              : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: SizedBox(
            height: extent,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
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
                    child: _Selected(
                      listenables: [handler.nowPlaying, services.library],
                      select: () => (
                        current: handler.nowPlaying.value?.id == track.id,
                        downloaded: services.library.isDownloaded(track.id),
                        artist: LibraryController.artistOf(track),
                      ),
                      builder: (context, state) {
                        final (:current, :downloaded, :artist) = state;
                        final second = detail ??
                            (!downloaded && track.duration > 0
                                ? '$artist · ${formatDuration(Duration(seconds: track.duration))}'
                                : artist);
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.body.copyWith(
                                fontWeight: FontWeight.w500,
                                height: 1.25,
                                color: current
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              second,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  AppTypography.caption.copyWith(fontSize: 13),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  trailing ??
                      _Selected(
                        listenables: [services.library],
                        select: () => services.library.isDownloaded(track.id),
                        builder: (context, downloaded) => downloaded
                            ? _MoreButton(track: track, queue: queue)
                            : TrackDownloadButton(track: track, size: 22),
                      ),
                ],
              ),
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
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        onPressed: () => TrackSheet.show(context, track, queue: queue),
        icon: const Icon(
          Icons.more_horiz_rounded,
          color: AppColors.textFaint,
          size: 22,
        ),
      ),
    );
  }
}

/// Rebuilds [builder] only when what [select] reads from [listenables]
/// changes. A row listens to the whole library and to the player, yet
/// almost every change there (another song starting, a playlist edit)
/// leaves the row as it was.
class _Selected<T> extends StatefulWidget {
  final List<Listenable> listenables;
  final T Function() select;
  final Widget Function(BuildContext context, T value) builder;

  const _Selected({
    required this.listenables,
    required this.select,
    required this.builder,
  });

  @override
  State<_Selected<T>> createState() => _SelectedState<T>();
}

class _SelectedState<T> extends State<_Selected<T>> {
  late T _value = widget.select();

  @override
  void initState() {
    super.initState();
    for (final l in widget.listenables) {
      l.addListener(_changed);
    }
  }

  @override
  void didUpdateWidget(covariant _Selected<T> old) {
    super.didUpdateWidget(old);
    for (final l in old.listenables) {
      l.removeListener(_changed);
    }
    for (final l in widget.listenables) {
      l.addListener(_changed);
    }
    // A recycled row may now show another song.
    _value = widget.select();
  }

  @override
  void dispose() {
    for (final l in widget.listenables) {
      l.removeListener(_changed);
    }
    super.dispose();
  }

  void _changed() {
    final next = widget.select();
    if (next != _value) setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
