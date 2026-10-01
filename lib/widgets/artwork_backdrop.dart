import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'cached_cover_image.dart';

/// The player's background: the cover itself, blown up and dissolved into
/// colour, sinking into black toward the controls.
///
/// A thumbnail is all it needs (the blur hides everything else), so it costs
/// one tiny decode per song; the result sits in its own layer and is only
/// repainted while cross-fading to the next cover.
class ArtworkBackdrop extends StatelessWidget {
  final String coverUrl;

  const ArtworkBackdrop({super.key, required this.coverUrl});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.background),
          AnimatedSwitcher(
            duration: AppMotion.ambient,
            child: coverUrl.isEmpty
                ? const SizedBox.expand()
                : SizedBox.expand(
                    key: ValueKey(coverUrl),
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: 48,
                        sigmaY: 48,
                        tileMode: TileMode.mirror,
                      ),
                      child: FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: CachedCoverImage(
                          url: coverUrl,
                          width: 64,
                          height: 64,
                        ),
                      ),
                    ),
                  ),
          ),
          // Keeps text legible over any cover, and lands on the app's black
          // where the controls sit.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x8C08080A),
                  Color(0xB308080A),
                  Color(0xF208080A),
                ],
                stops: [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
