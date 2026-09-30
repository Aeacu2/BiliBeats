import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/lyric_line.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';
import '../utils/format.dart';
import '../utils/snack.dart';
import '../widgets/ambient_background.dart';
import '../widgets/cached_cover_image.dart';
import '../widgets/expand_from_card.dart';
import '../widgets/lyric_editor_dialog.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_queue_sheet.dart';
import '../widgets/player_seek_bar.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/synced_lyrics_view.dart';
import '../widgets/track_options_menu.dart';

/// The full-screen player.
///
/// It only ever shows the song that is playing. (The previous page doubled
/// as a "track details" view for other songs, so it could show one song's
/// artwork and title while another was audible.) Details for any other song
/// live in its sheet ([TrackOptionsMenu]).
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

  late final ValueNotifier<Duration> _position =
      ValueNotifier(_handler.position);
  StreamSubscription<Duration>? _positionSub;

  bool _showLyrics = false;

  // Editor session. The editor captures its target track: saving applies
  // to that track even if playback moves on while it is open.
  bool _showEditor = false;
  bool _editorLyricsTab = false;
  Track? _editorTrack;
  List<LyricLine> _editorInitialLines = const [];
  int _editorSession = 0;
  GlobalKey<LyricEditorDialogState>? _editorKey;
  VoidCallback? _editorRelease;
  final ValueNotifier<Duration> _editorPosition = ValueNotifier(Duration.zero);

  @override
  void initState() {
    super.initState();
    _positionSub = _handler.positionStream.listen((position) {
      _position.value = position;
      final target = _editorTrack;
      if (target != null && _handler.currentTrack?.id == target.id) {
        _editorPosition.value = position;
      }
    });
    _handler.nowPlaying.addListener(_onTrackChanged);
  }

  @override
  void dispose() {
    _handler.nowPlaying.removeListener(_onTrackChanged);
    _positionSub?.cancel();
    _position.dispose();
    ++_editorSession;
    _editorRelease?.call();
    _editorPosition.dispose();
    super.dispose();
  }

  void _onTrackChanged() {
    if (!mounted) return;
    if (_handler.currentTrack == null && !_showEditor) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Editor
  // ---------------------------------------------------------------------------

  void _openEditor({bool lyricsTab = false}) {
    final target = _handler.currentTrack;
    if (target == null) return;

    final manual = DatabaseService.manualLyricsFor(target.id);
    final initialLines =
        manual?.lines ?? AppServices.instance.lyrics.lines.value;

    _editorRelease?.call();
    _editorRelease = _handler.holdAutoAdvance();
    ++_editorSession;
    _editorKey = GlobalKey<LyricEditorDialogState>();
    _editorPosition.value = _position.value;

    setState(() {
      _editorTrack = target;
      _editorInitialLines = List<LyricLine>.of(initialLines);
      _showEditor = true;
      _editorLyricsTab = lyricsTab;
    });
  }

  void _closeEditor() {
    ++_editorSession;
    _editorRelease?.call();
    _editorRelease = null;
    _editorKey = null;
    if (!mounted) return;
    setState(() {
      _showEditor = false;
      _editorTrack = null;
      _editorInitialLines = const [];
    });
    if (_handler.currentTrack == null) Navigator.of(context).maybePop();
  }

  /// Back / swipe-down while editing steps back inside the editor first.
  void _stepEditorBack() {
    final key = _editorKey;
    if (key == null) {
      if (_showEditor) _closeEditor();
      return;
    }
    () async {
      final consumed = await key.currentState?.onBackPressed() ?? false;
      if (!consumed && mounted && _showEditor) _closeEditor();
    }();
  }

  void _finishEditorSession(int session, {bool showLyrics = false}) {
    if (!mounted || !_showEditor || session != _editorSession) return;
    if (showLyrics) _showLyrics = true;
    _closeEditor();
  }

  Future<void> _applyEditorLyrics(
    Track target,
    int session,
    LyricsResult result, {
    bool settle = true,
  }) async {
    if (!mounted || !_showEditor || session != _editorSession) return;

    final selection = LyricsResult(
      source: result.source,
      songTitle: result.songTitle,
      artistName: result.artistName,
      lines: List<LyricLine>.of(result.lines),
    );

    // Invalidates automatic lookups synchronously, before any await.
    final save = DatabaseService.cacheLyrics(target.id, selection);
    final revision = DatabaseService.lyricsRevisionFor(target.id);
    AppServices.instance.lyrics.publishIfCurrent(target.id, selection);

    try {
      await save;
      if (DatabaseService.lyricsRevisionFor(target.id) != revision) return;
      if (settle) {
        _finishEditorSession(
          session,
          showLyrics: _handler.currentTrack?.id == target.id,
        );
      }
    } catch (error, stack) {
      debugPrint('Manual lyrics save failed: $error\n$stack');
      if (!settle) rethrow;
      if (!mounted) return;
      showAppSnackBar(
        ScaffoldMessenger.of(context),
        message: '歌词已在本次使用中应用，但保存失败，请重试',
        backgroundColor: AppColors.backgroundElevated,
        duration: const Duration(seconds: 4),
      );
    }
  }

  Future<void> _saveEditorMetadata(
    Track target,
    int session,
    String newTitle,
    String newArtist,
    String newCoverUrl, {
    bool settle = true,
  }) async {
    if (!mounted || !_showEditor || session != _editorSession) return;

    final updated = target.copyWith(
      title: newTitle,
      uploader: newArtist,
      coverUrl: newCoverUrl,
    );

    try {
      await DatabaseService.updateTrackMetadata(updated);
      _handler.updateTrackMetadata(updated);
      if (settle) _finishEditorSession(session);
    } catch (error, stack) {
      debugPrint('Metadata save failed: $error\n$stack');
      if (!settle) rethrow;
      if (!mounted) return;
      showAppSnackBar(
        ScaffoldMessenger.of(context),
        message: '修改未能保存，请重试',
        backgroundColor: AppColors.backgroundElevated,
        duration: const Duration(seconds: 4),
      );
    }
  }

  Widget _buildEditor() {
    final target = _editorTrack;
    if (target == null) return const SizedBox.shrink();
    final session = _editorSession;

    return LyricEditorDialog(
      key: _editorKey ?? ValueKey('lyric-editor-$session'),
      songTitle: target.title,
      rawTitle: target.rawTitle,
      artistName: target.uploader,
      coverUrl: target.coverUrl,
      positionNotifier: _editorPosition,
      initialTabIndex: _editorLyricsTab ? 1 : 0,
      currentLines: _editorInitialLines,
      currentTrackId: target.id,
      onClose: () {
        if (session == _editorSession) _closeEditor();
      },
      onApplyLyrics: (result, {bool settle = true}) =>
          _applyEditorLyrics(target, session, result, settle: settle),
      onUpdateMetadata: (title, artist, cover, {bool settle = true}) =>
          _saveEditorMetadata(target, session, title, artist, cover,
              settle: settle),
    );
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
        canPop: !_showEditor,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _showEditor) {
            Haptics.selection();
            _stepEditorBack();
          }
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: AmbientBackground(coverUrl: track?.coverUrl),
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) > 480) {
                  Haptics.selection();
                  if (_showEditor) {
                    _stepEditorBack();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                }
              },
              child: SafeArea(
                minimum: const EdgeInsets.only(top: 8),
                child: AnimatedSwitcher(
                  duration: AppMotion.base,
                  switchInCurve: AppMotion.standard,
                  switchOutCurve: AppMotion.standardReverse,
                  transitionBuilder: (child, animation) {
                    final isEditor = child.key == const ValueKey('editor');
                    return SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(0, isEditor ? 0.15 : -0.08),
                        end: Offset.zero,
                      ).animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: _showEditor
                      ? KeyedSubtree(
                          key: const ValueKey('editor'),
                          child: _buildEditor(),
                        )
                      : track == null
                          ? const SizedBox.shrink()
                          : KeyedSubtree(
                              key: const ValueKey('player'),
                              child: _player(track),
                            ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _player(Track track) {
    return Column(
      children: [
        _topBar(track),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
            child: AnimatedSwitcher(
              duration: AppMotion.base,
              switchInCurve: AppMotion.standard,
              switchOutCurve: AppMotion.standardReverse,
              child: _showLyrics
                  ? ValueListenableBuilder<List<LyricLine>>(
                      key: const ValueKey('lyrics'),
                      valueListenable: AppServices.instance.lyrics.lines,
                      builder: (context, lines, _) => SyncedLyricsView(
                        lines: lines,
                        positionNotifier: _position,
                        onSeek: (seconds) => _handler.seek(
                          Duration(milliseconds: (seconds * 1000).round()),
                        ),
                        onOpenEditor: () => _openEditor(lyricsTab: true),
                      ),
                    )
                  : _artwork(track),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _titleRow(track),
              const SizedBox(height: 14),
              PlayerSeekBar(
                positionNotifier: _position,
                durationNotifier: _handler.durationNotifier,
                fallbackSeconds:
                    track.duration > 0 ? track.duration.toDouble() : 1.0,
                isActive: true,
                onSeek: _handler.seek,
              ),
              const SizedBox(height: 6),
              _transport(),
              const SizedBox(height: 10),
              _utilities(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(Track track) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            tooltip: '收起',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: AppColors.textSecondary, size: 32),
          ),
          Expanded(
            child: ValueListenableBuilder<PlaybackQueueSnapshot>(
              valueListenable: _handler.queueNotifier,
              builder: (context, queue, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '正在播放',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textSecondary,
                      letterSpacing: 0.6,
                    ),
                  ),
                  if (queue.tracks.length > 1)
                    Text(
                      '${queue.currentIndex + 1} / ${queue.tracks.length}',
                      style: AppTypography.caption.copyWith(fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '更多',
            onPressed: () => TrackOptionsMenu.show(context, track),
            icon: const Icon(Icons.more_horiz_rounded,
                color: AppColors.textSecondary, size: 26),
          ),
        ],
      ),
    );
  }

  Widget _artwork(Track track) {
    return LayoutBuilder(
      key: const ValueKey('art'),
      builder: (context, constraints) {
        final size = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;
        final media = MediaQuery.of(context);
        final reduceMotion =
            media.disableAnimations || media.accessibleNavigation;
        return Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: _handler.playingNotifier,
            builder: (context, playing, child) => AnimatedScale(
              scale: playing ? 1.0 : 0.9,
              duration: reduceMotion ? Duration.zero : AppMotion.slow,
              curve: AppMotion.springBouncy,
              child: child,
            ),
            child: Container(
              width: size,
              height: size,
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.black55,
                    blurRadius: 40,
                    spreadRadius: -8,
                    offset: Offset(0, 22),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: CachedCoverImage(
                  key: ValueKey(track.id),
                  url: track.coverUrl,
                  width: size,
                  height: size,
                ),
              ),
            ),
          ),
        );
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
                style: AppTypography.title.copyWith(fontSize: 21),
              ),
              const SizedBox(height: 3),
              MarqueeText(
                text: track.uploader,
                phase: 0.35,
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
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
              onPressed: () async {
                Haptics.light();
                await DatabaseService.toggleFavorite(track);
              },
              icon: Icon(
                favorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: favorite ? AppColors.accent : AppColors.textSecondary,
                size: 26,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _transport() {
    return ValueListenableBuilder<PlaybackQueueSnapshot>(
      valueListenable: _handler.queueNotifier,
      builder: (context, queue, _) {
        final (IconData modeIcon, String modeLabel) = queue.isShuffle
            ? (Icons.shuffle_rounded, '随机播放')
            : queue.loopMode == LoopMode.one
                ? (Icons.repeat_one_rounded, '单曲循环')
                : (Icons.repeat_rounded, '列表循环');
        final modeActive = queue.isShuffle || queue.loopMode == LoopMode.one;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              tooltip: modeLabel,
              onPressed: () {
                Haptics.medium();
                _handler.cyclePlayMode();
              },
              icon: Icon(
                modeIcon,
                size: 24,
                color: modeActive ? AppColors.accent : AppColors.textMuted,
              ),
            ),
            IconButton(
              tooltip: '上一首',
              iconSize: 44,
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
              iconSize: 44,
              onPressed: () {
                Haptics.selection();
                _handler.skipToNext();
              },
              icon: const Icon(Icons.skip_next_rounded,
                  color: AppColors.textPrimary),
            ),
            IconButton(
              tooltip: '播放队列',
              onPressed: () =>
                  PlaybackQueueSheet.show(context, handler: _handler),
              icon: const Icon(Icons.queue_music_rounded,
                  size: 24, color: AppColors.textMuted),
            ),
          ],
        );
      },
    );
  }

  Widget _utilities() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _UtilityButton(
          icon: _showLyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined,
          label: '歌词',
          active: _showLyrics,
          onPressed: () {
            Haptics.selection();
            setState(() => _showLyrics = !_showLyrics);
          },
        ),
        ValueListenableBuilder<SleepTimerState>(
          valueListenable: _handler.sleepTimerNotifier,
          builder: (context, sleep, _) => _UtilityButton(
            icon: sleep.isActive
                ? Icons.bedtime_rounded
                : Icons.bedtime_outlined,
            label: !sleep.isActive
                ? '定时'
                : sleep.mode == SleepTimerMode.endOfTrack
                    ? '播完本首'
                    : formatDuration(sleep.remaining),
            active: sleep.isActive,
            onPressed: () => SleepTimerSheet.show(context, handler: _handler),
          ),
        ),
        _UtilityButton(
          icon: Icons.edit_note_rounded,
          label: '编辑',
          onPressed: () => _openEditor(lyricsTab: _showLyrics),
        ),
      ],
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

class _UtilityButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;

  const _UtilityButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textMuted;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(label, style: AppTypography.caption.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
