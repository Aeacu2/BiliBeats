import 'package:flutter/material.dart';

import '../app/playback_actions.dart';
import '../models/track.dart';
import '../theme/app_theme.dart';
import 'cached_cover_image.dart';
import 'sheet.dart';

/// The top of a collection page (a playlist, an artist): artwork, its name,
/// and the two ways to start it.
class CollectionHeader extends StatelessWidget {
  final String title;
  final String coverUrl;

  /// Shown when there is no artwork to use.
  final IconData placeholder;
  final Color placeholderColor;

  /// Artists get a portrait-like circle; playlists a rounded square.
  final bool round;

  /// Songs that can play now. The buttons are hidden when [showActions] is
  /// false and disabled when this is empty.
  final List<Track> playable;
  final int count;
  final bool showActions;

  const CollectionHeader({
    super.key,
    required this.title,
    required this.coverUrl,
    required this.playable,
    required this.count,
    this.placeholder = Icons.queue_music_rounded,
    this.placeholderColor = AppColors.textMuted,
    this.round = false,
    this.showActions = true,
  });

  static const double _art = 176;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(round ? _art / 2 : AppRadius.lg);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: const [
                BoxShadow(
                  color: AppColors.black50,
                  blurRadius: 36,
                  spreadRadius: -10,
                  offset: Offset(0, 18),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: coverUrl.isNotEmpty
                  ? CachedCoverImage(url: coverUrl, width: _art, height: _art)
                  : SizedBox(
                      width: _art,
                      height: _art,
                      child: ColoredBox(
                        color: AppColors.fieldFill,
                        child: Icon(placeholder,
                            size: 56, color: placeholderColor),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.titleLarge,
          ),
          const SizedBox(height: 4),
          Text('$count 首', style: AppTypography.caption.copyWith(fontSize: 13)),
          if (showActions && count > 0) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    icon: Icons.play_arrow_rounded,
                    label: '播放',
                    onPressed: playable.isEmpty
                        ? null
                        : () => playCollection(playable),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    icon: Icons.shuffle_rounded,
                    label: '随机',
                    secondary: true,
                    onPressed: playable.isEmpty
                        ? null
                        : () => playCollection(playable, shuffle: true),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
