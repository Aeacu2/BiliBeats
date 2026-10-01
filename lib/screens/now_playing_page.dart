import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/database_service.dart';
import '../state/library_controller.dart';
import '../state/lyrics_controller.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';
import '../utils/format.dart';
import '../utils/snack.dart';
import '../widgets/artwork_backdrop.dart';
import '../widgets/cached_cover_image.dart';
import '../widgets/expand_from_card.dart';
import '../widgets/lyrics_sheet.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_queue_sheet.dart';
import '../widgets/player_seek_bar.dart';
import '../widgets/shimmer.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/track_sheet.dart';

/// The full-screen player.
///
/// It only ever shows the song that is playing, and it keeps one shape:
/// artwork (or lyrics) above; title, progress and three transport buttons
/// below; one quiet row of secondary controls at the bottom. Everything
/// else lives one tap away in a sheet.
///
/// Gestures: tap the artwork for lyrics, swipe it sideways to change song,
/// pull down to close.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  static bool _open = false;

  /// Opens the player, growing out of the docked card when [from] is given.
  static Future<void> open(BuildContext context, {Rect? from}) async {
    if (_open || AppServices.instance.handler.currentTrack == null) return;
    _open = true;
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;
    try {
      await Navigator.of(context).push(PageRouteBuilder<void>(
        transitionDuration: reduceMotion ? Duration.zero : AppMotion.slow,
        reverseTransitionDuration:
            reduceMotion ? Duration.zero : AppMotion.base,
        pageBuilder: (context, animation, secondary) => const NowPlayingPage(),
        transitionsBuilder: (context, animation, secondary, child) {
          if (reduceMotion) return child;
          if (from == null) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: AppMotion.standard,
                reverseCurve: AppMotion.standardReverse,
              )),
              child: child,
            );
          }
          return ExpandFromCard(animation: animation, from: from, child: child);
        },
      ));
    } finally {
      _open = false;
    }
  }

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  BiliBeatAudioHandler get _handler => AppServices.instance.handler;
  LyricsController get _lyrics => AppServices.instance.lyrics;

  late final ValueNotifier<Duration> _position =
      ValueNotifier(_handler.position);
  StreamSubscription<Duration>? _positionSub;

  bool _showLyrics = false;

  /// The song being calibrated. While set, the song repeats instead of
  /// moving on, so the lines being timed stay the lines being heard.
  Track? _calibrating;
  VoidCallback? _releaseHold;

  @override
  void initState() {
    super.initState();
    _positionSub = _handler.positionStream
        .listen((position) => _position.value = position);
    _handler.nowPlaying.addListener(_onTrackChanged);
  }

  @override
  void dispose() {
    _handler.nowPlaying.removeListener(_onTrackChanged);
    _positionSub?.cancel();
    _position.dispose();
    _releaseHold?.call();
    super.dispose();
  }

  void _onTrackChanged() {
    if (!mounted) return;
    final track = _handler.currentTrack;
    if (track == null) {
      // Not from inside the notification: the navigator may be mid-update.
      Future.microtask(() {
        if (!mounted) return;
        if (ModalRoute.of(context)?.isActive ?? false) {
          Navigator.of(context).maybePop();
        }
      });
      return;
    }
    // A manual skip ends calibration: it was about the previous song.
    if (_calibrating != null && _calibrating!.id != track.id) _endCalibration();
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Lyrics
  // ---------------------------------------------------------------------------

  void _toggleLyrics() {
    Haptics.selection();
    if (_calibrating != null) _endCalibration();
    setState(() => _showLyrics = !_showLyrics);
  }

  Future<void> _openLyricsSheet() async {
    final track = _handler.currentTrack;
    if (track == null) return;
    // Held while choosing too: the song being judged should not change.
    final release = _handler.holdAutoAdvance();
    final action = await LyricsSheet.show(context, track);
    if (!mounted || action != LyricsSheetAction.calibrate) {
      release();
      return;
    }
    if (_handler.currentTrack?.id != track.id) {
      release();
      return;
    }
    _releaseHold?.call();
    _releaseHold = release;
    setState(() {
      _showLyrics = true;
      _calibrating = track;
    });
  }

  void _endCalibration() {
    _releaseHold?.call();
    _releaseHold = null;
    if (mounted) setState(() => _calibrating = null);
  }

  void _calibrate(double offset) {
    final track = _calibrating;
    if (track == null) return;
    unawaited(_lyrics.setOffset(track, offset).catchError((Object error) {
      debugPrint('Calibration save failed: $error');
      if (mounted) {
        showAppSnackBar(ScaffoldMessenger.of(context), message: '校准未能保存');
      }
    }));
  }

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final track = _handler.currentTrack;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: PopScope(
        canPop: _calibrating == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _endCalibration();
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: ArtworkBackdrop(coverUrl: track?.coverUrl ?? ''),
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) > 480) {
                  Haptics.selection();
                  Navigator.of(context).maybePop();
                }
              },
              child: SafeArea(
                minimum: const EdgeInsets.only(top: 8, bottom: 8),
                child: track == null ? const SizedBox.shrink() : _player(track),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const double _gutter = 28;

  Widget _player(Track track) {
    return Column(
      children: [
        _topBar(track),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_gutter, 8, _gutter, 16),
            child: AnimatedSwitcher(
              duration: AppMotion.base,
              switchInCurve: AppMotion.standard,
              switchOutCurve: AppMotion.standardReverse,
              child: _showLyrics
                  ? KeyedSubtree(
                      key: const ValueKey('lyrics'),
                      child: _lyricsPane(),
                    )
                  : _Artwork(
                      key: const ValueKey('art'),
                      track: track,
                      handler: _handler,
                      onTap: _toggleLyrics,
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _titleRow(track),
              const SizedBox(height: 10),
              PlayerSeekBar(
                position: _position,
                duration: _handler.durationNotifier,
                fallback: Duration(seconds: track.duration),
                onSeek: _handler.seek,
              ),
              const SizedBox(height: 4),
              _transport(),
              const SizedBox(height: 6),
              _secondary(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(Track track) {
    final calibrating = _calibrating != null;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Align(
                alignment: Alignment.centerLeft,
                child: calibrating
                    ? TextButton(
                        onPressed: () => _calibrate(0),
                        child: const Text('重置'),
                      )
                    : IconButton(
                        tooltip: '收起',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded,
                            color: AppColors.textPrimary, size: 30),
                      ),
              ),
            ),
            Expanded(
              child: Center(
                child: calibrating
                    ? const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '点一下正在唱的那句',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : _SleepBadge(handler: _handler),
              ),
            ),
            SizedBox(
              width: 96,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (calibrating)
                    TextButton(
                      onPressed: _endCalibration,
                      child: const Text(
                        '完成',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else ...[
                    if (_showLyrics)
                      IconButton(
                        tooltip: '歌词选项',
                        onPressed: _openLyricsSheet,
                        icon: const Icon(Icons.tune_rounded,
                            color: AppColors.textPrimary, size: 22),
                      ),
                    IconButton(
                      tooltip: '更多',
                      onPressed: () =>
                          TrackSheet.show(context, track, forPlayer: true),
                      icon: const Icon(Icons.more_horiz_rounded,
                          color: AppColors.textPrimary, size: 26),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lyricsPane() {
    return ValueListenableBuilder<LyricsState>(
      valueListenable: _lyrics.state,
      builder: (context, state, _) {
        switch (state.status) {
          case LyricsStatus.loading:
            return const _LyricsLoading();
          case LyricsStatus.empty:
            return _LyricsEmpty(
                onFind: _openLyricsSheet, onBack: _toggleLyrics);
          case LyricsStatus.ready:
            return LyricsView(
              lyrics: state.lyrics,
              position: _position,
              onSeek: _handler.seek,
              calibrating: _calibrating != null,
              onCalibrate: _calibrate,
            );
        }
      },
    );
  }

  Widget _titleRow(Track track) {
    final library = AppServices.instance.library;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(
                text: track.title,
                style: AppTypography.title.copyWith(fontSize: 22),
              ),
              const SizedBox(height: 2),
              MarqueeText(
                text: LibraryController.artistOf(track),
                phase: 0.35,
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        ListenableBuilder(
          listenable: library,
          builder: (context, _) {
            final favorite = library.isFavorite(track.id);
            return IconButton(
              tooltip: favorite ? '取消收藏' : '收藏',
              padding: EdgeInsets.zero,
              alignment: Alignment.centerRight,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              onPressed: () async {
                Haptics.light();
                // The song this was pressed for, whatever plays by the time
                // the write lands.
                await DatabaseService.toggleFavorite(track);
              },
              icon: AnimatedSwitcher(
                duration: AppMotion.fast,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  key: ValueKey(favorite),
                  color: favorite ? AppColors.accent : AppColors.textPrimary,
                  size: 26,
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _transport() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: '上一首',
          iconSize: 42,
          onPressed: () {
            Haptics.selection();
            _handler.skipToPrevious();
          },
          icon: const Icon(Icons.skip_previous_rounded,
              color: AppColors.textPrimary),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _handler.playingNotifier,
          builder: (context, playing, _) => _PlayButton(
            playing: playing,
            onPressed: () {
              Haptics.light();
              _handler.togglePlayPause();
            },
          ),
        ),
        IconButton(
          tooltip: '下一首',
          iconSize: 42,
          onPressed: () {
            Haptics.selection();
            _handler.skipToNext();
          },
          icon:
              const Icon(Icons.skip_next_rounded, color: AppColors.textPrimary),
        ),
      ],
    );
  }

  /// Lyrics · play mode · queue. Icons only; the active ones light up.
  Widget _secondary() {
    return ValueListenableBuilder<PlaybackQueueSnapshot>(
      valueListenable: _handler.queueNotifier,
      builder: (context, queue, _) {
        final (IconData modeIcon, String modeLabel) = queue.isShuffle
            ? (Icons.shuffle_rounded, '随机播放')
            : queue.loopMode == LoopMode.one
                ? (Icons.repeat_one_rounded, '单曲循环')
                : (Icons.repeat_rounded, '列表循环');
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _QuietButton(
              tooltip: '歌词',
              icon: _showLyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined,
              active: _showLyrics,
              alignment: Alignment.centerLeft,
              onPressed: _toggleLyrics,
            ),
            _QuietButton(
              tooltip: modeLabel,
              icon: modeIcon,
              active: queue.isShuffle || queue.loopMode == LoopMode.one,
              onPressed: () {
                Haptics.medium();
                _handler.cyclePlayMode();
              },
            ),
            _QuietButton(
              tooltip: '播放队列',
              icon: Icons.queue_music_rounded,
              alignment: Alignment.centerRight,
              onPressed: () => PlaybackQueueSheet.show(context),
            ),
          ],
        );
      },
    );
  }
}

/// The cover. Breathes with play/pause; tap for lyrics, swipe to skip.
class _Artwork extends StatelessWidget {
  final Track track;
  final BiliBeatAudioHandler handler;
  final VoidCallback onTap;

  const _Artwork({
    super.key,
    required this.track,
    required this.handler,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest.shortestSide;
        return Center(
          child: Semantics(
            button: true,
            label: '显示歌词',
            child: GestureDetector(
              onTap: onTap,
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity.abs() < 300) return;
                Haptics.selection();
                velocity < 0 ? handler.skipToNext() : handler.skipToPrevious();
              },
              child: ValueListenableBuilder<bool>(
                valueListenable: handler.playingNotifier,
                builder: (context, playing, child) => AnimatedScale(
                  scale: playing ? 1.0 : 0.88,
                  duration: reduceMotion ? Duration.zero : AppMotion.slow,
                  curve: AppMotion.springBouncy,
                  child: child,
                ),
                child: Container(
                  width: size,
                  height: size,
                  decoration: const BoxDecoration(
                    borderRadius:
                        BorderRadius.all(Radius.circular(AppRadius.lg)),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.black55,
                        blurRadius: 48,
                        spreadRadius: -12,
                        offset: Offset(0, 24),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    child: AnimatedSwitcher(
                      duration: AppMotion.base,
                      child: CachedCoverImage(
                        key: ValueKey('${track.id}${track.coverUrl}'),
                        url: track.coverUrl,
                        width: size,
                        height: size,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LyricsLoading extends StatelessWidget {
  const _LyricsLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Shimmer(width: 220, height: 20),
          SizedBox(height: 18),
          Shimmer(width: 160, height: 20),
          SizedBox(height: 18),
          Shimmer(width: 190, height: 20),
        ],
      ),
    );
  }
}

class _LyricsEmpty extends StatelessWidget {
  final VoidCallback onFind;
  final VoidCallback onBack;

  const _LyricsEmpty({required this.onFind, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onBack,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '暂无歌词',
              style: AppTypography.title.copyWith(color: AppColors.white45),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onFind,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.white24),
                shape: const StadiumBorder(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              ),
              child: const Text('查找歌词'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown at the top only while a sleep timer runs.
class _SleepBadge extends StatelessWidget {
  final BiliBeatAudioHandler handler;

  const _SleepBadge({required this.handler});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SleepTimerState>(
      valueListenable: handler.sleepTimerNotifier,
      builder: (context, sleep, _) {
        if (!sleep.isActive) return const SizedBox.shrink();
        return Material(
          color: AppColors.white10,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => SleepTimerSheet.show(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bedtime_rounded,
                      size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    sleep.mode == SleepTimerMode.endOfTrack
                        ? '播完本首'
                        : formatDuration(sleep.remaining),
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback onPressed;

  const _PlayButton({required this.playing, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.textPrimary,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 72,
          height: 72,
          child: Tooltip(
            message: playing ? '暂停' : '播放',
            child: AnimatedSwitcher(
              duration: AppMotion.instant,
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(playing),
                size: 40,
                color: AppColors.background,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuietButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;

  /// Where the glyph sits in its 48pt target, so the outer two line up with
  /// the edges of the title and the progress bar.
  final Alignment alignment;

  const _QuietButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      alignment: alignment,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      icon: Icon(
        icon,
        size: 23,
        color: active ? AppColors.accent : AppColors.textMuted,
      ),
    );
  }
}
