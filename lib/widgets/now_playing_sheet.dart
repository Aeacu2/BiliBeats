import 'dart:async';

import 'package:flutter/material.dart';

import '../models/lyric_line.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/database_service.dart';
import '../services/audio_download_service.dart';
import '../services/download_manager.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';
import '../utils/snack.dart';
import '../utils/format.dart';
import 'ambient_background.dart';
import 'cached_cover_image.dart';
import 'marquee_text.dart';
import 'playback_queue_sheet.dart';
import 'sleep_timer_sheet.dart';
import 'progress_ring.dart';
import 'player_seek_bar.dart';
import 'synced_lyrics_view.dart';
import 'lyric_editor_dialog.dart';

/// Full-screen "now playing" surface.
class NowPlayingSheet extends StatefulWidget {
  final BiliBeatAudioHandler handler;
  final Track focusedTrack;
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration> durationNotifier;
  final ValueNotifier<List<LyricLine>> lyricsNotifier;

  /// Set when the sheet is opened as part of "play this now". The handler has
  /// not switched track yet at that instant, so it cannot be inferred — and
  /// getting it wrong leaves the sheet stuck on one track for the whole
  /// session, never following the queue.
  final bool followHandler;

  const NowPlayingSheet({
    super.key,
    required this.handler,
    required this.focusedTrack,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.lyricsNotifier,
    this.followHandler = false,
  });

  @override
  State<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<NowPlayingSheet>
    with WidgetsBindingObserver {
  final List<StreamSubscription> _subs = [];

  late Track _displayTrack;
  bool _followHandler = false;
  bool _isPlaying = false;
  bool _isShuffle = false;
  LoopMode _loopMode = LoopMode.all;
  bool _showLyrics = false;
  bool _isFavorite = false;
  bool _isDownloaded = false;
  DownloadTask? _downloadTask;
  bool _showEditor = false;
  bool _editorLyricsTab = false;
  VoidCallback? _editorRelease;

  /// Captured editor target: callbacks save to this track even if playback
  /// moves on (manual Next/Previous, OS controls). Never consult mutable
  /// [_displayTrack] to decide the save target.
  Track? _editorTrack;
  List<LyricLine> _editorInitialLines = const [];

  int _editorSession = 0;
  GlobalKey<LyricEditorDialogState>? _editorKey;

  /// A clock belonging to the captured editor target.
  ///
  /// It follows playback only while that exact target is active. It must
  /// never become another song's position stream.
  final ValueNotifier<Duration> _editorPosition = ValueNotifier(Duration.zero);

  final Set<String> _favoriteOperations = {};

  int _favoriteStateToken = 0;
  int _downloadStateToken = 0;

  bool get _isActive => widget.handler.currentTrack?.id == _displayTrack.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final h = widget.handler;
    _displayTrack = widget.focusedTrack;
    _followHandler =
        widget.followHandler || (h.currentTrack?.id == _displayTrack.id);
    _isPlaying = h.isPlaying;
    _isShuffle = h.isShuffle;
    _loopMode = h.loopMode;
    _downloadTask = _liveTaskFor(_displayTrack.id);
    _refreshTrackState();
    widget.positionNotifier.addListener(_syncEditorPosition);

    _subs.add(h.currentTrackStream.listen((t) {
      if (t == null || !mounted) return;
      if (_followHandler && t.id != _displayTrack.id) {
        setState(() {
          _displayTrack = t;
          // The download task follows the displayed track, or the primary
          // control stays stuck on the previous song's ring.
          _downloadTask = _liveTaskFor(t.id);
        });
        _refreshTrackState();
      } else if (t.id == _displayTrack.id) {
        setState(() => _displayTrack = t); // metadata edit
      }
    }));
    _subs.add(h.playerStateStream.listen((p) {
      if (!mounted) return;
      setState(() => _isPlaying = p);
      // Playback implies the file reached disk, and the handler downloads
      // outside DownloadManager — so re-check rather than leaving the control
      // stuck on "download" while the track plays.
      if (p && _isActive && !_isDownloaded) _refreshDownloaded();
    }));
    _subs.add(h.shuffleStream.listen((s) {
      if (mounted) setState(() => _isShuffle = s);
    }));
    _subs.add(h.loopModeStream.listen((m) {
      if (mounted) setState(() => _loopMode = m);
    }));
    _subs.add(DownloadManager.instance.updates.listen((changedId) {
      // Only this sheet's track matters: progress ticks for any other
      // download arrive every 64 KiB and would rebuild the whole page for
      // nothing. Unchanged tasks (same object) are equally skippable.
      if (!mounted || changedId != _displayTrack.id) return;
      final task = _liveTaskFor(_displayTrack.id);
      final finished = _downloadTask != null && task == null;
      if (identical(task, _downloadTask)) return;
      setState(() => _downloadTask = task);
      // Only stat the filesystem when a download actually finished, not on
      // every progress tick (they arrive every 64 KiB).
      if (finished) _refreshDownloaded();
    }));
    // Library edits from elsewhere (options menu, playlist sheet) must
    // refresh the favorite/download state when this sheet returns to view.
    // Token guards inside make the extra refresh cheap and race-safe.
    _subs.add(DatabaseService.libraryUpdateStream.listen((_) {
      if (!mounted) return;
      _refreshTrackState();
    }));
  }

  void _syncEditorPosition() {
    final target = _editorTrack;
    if (target == null) return;

    if (widget.handler.currentTrack?.id != target.id) return;

    _editorPosition.value = widget.positionNotifier.value;
  }

  DownloadTask? _liveTaskFor(String id) => DownloadManager.instance.taskFor(id);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_editorSession;
    widget.positionNotifier.removeListener(_syncEditorPosition);
    _editorPosition.dispose();
    _editorRelease?.call();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Mirror MainLayout's resume heal: the sheet may have missed the
      // currentTrackStream event while backgrounded.
      widget.handler.syncOnResume();
      final handlerTrack = widget.handler.currentTrack;
      if (handlerTrack != null && mounted) {
        if (_followHandler && handlerTrack.id != _displayTrack.id) {
          setState(() {
            _displayTrack = handlerTrack;
            _downloadTask = _liveTaskFor(handlerTrack.id);
          });
          _refreshTrackState();
        } else if (handlerTrack.id == _displayTrack.id) {
          // Metadata may have been updated while away; refresh display.
          setState(() => _displayTrack = handlerTrack);
        }
        // Keep play/pause in sync even if playerStateStream was throttled.
        final playing = widget.handler.isPlaying;
        if (playing != _isPlaying) {
          setState(() => _isPlaying = playing);
        }
      }
    }
  }

  /// One combined refresh so switching tracks costs a single rebuild.
  /// Tokens pin results to the track that requested them.
  Future<void> _refreshTrackState() async {
    final track = _displayTrack;

    final favoriteToken = ++_favoriteStateToken;
    final downloadToken = ++_downloadStateToken;

    try {
      final results = await Future.wait<bool>([
        AudioDownloadService.isDownloaded(track),
        DatabaseService.isFavorite(track.id),
      ]);

      if (!mounted || _displayTrack.id != track.id) return;

      setState(() {
        if (downloadToken == _downloadStateToken) {
          _isDownloaded =
              results[0] && !DownloadManager.instance.isDownloading(track.id);
        }

        if (favoriteToken == _favoriteStateToken &&
            !_favoriteOperations.contains(track.id)) {
          _isFavorite = results[1];
        }
      });
    } catch (error, stack) {
      debugPrint('Track state refresh failed: $error\n$stack');
    }
  }

  Future<void> _refreshDownloaded() async {
    final track = _displayTrack;
    final token = ++_downloadStateToken;

    try {
      final downloaded = await AudioDownloadService.isDownloaded(track);

      if (!mounted ||
          token != _downloadStateToken ||
          _displayTrack.id != track.id) {
        return;
      }

      setState(() => _isDownloaded = downloaded);
    } catch (error, stack) {
      debugPrint('Download state refresh failed: $error\n$stack');
    }
  }

  Future<void> _handleFavorite() async {
    final target = _displayTrack;

    if (!_favoriteOperations.add(target.id)) return;

    ++_favoriteStateToken;
    Haptics.light();

    try {
      final nowFavorite = await DatabaseService.toggleFavorite(target);

      if (mounted && _displayTrack.id == target.id) {
        // Invalidate refreshes that began before this mutation completed.
        ++_favoriteStateToken;
        setState(() => _isFavorite = nowFavorite);
      }
    } catch (error, stack) {
      debugPrint('Favorite operation failed: $error\n$stack');

      if (mounted) {
        showAppSnackBar(
          ScaffoldMessenger.of(context),
          message: '操作未完成，请重试',
          backgroundColor: AppColors.backgroundElevated,
        );
      }
    } finally {
      _favoriteOperations.remove(target.id);

      if (mounted && _displayTrack.id == target.id) {
        _refreshTrackState();
      }
    }
  }

  void _openEditor({bool lyricsTab = false}) {
    final target = _displayTrack;

    final active = widget.handler.currentTrack?.id == target.id;

    final manual = DatabaseService.manualLyricsFor(target.id);

    final initialLines = manual != null
        ? manual.lines
        : active
            ? widget.lyricsNotifier.value
            : const <LyricLine>[];

    _editorRelease?.call();
    _editorRelease = widget.handler.holdAutoAdvance();

    ++_editorSession;
    _editorKey = GlobalKey<LyricEditorDialogState>();

    _editorPosition.value =
        active ? widget.positionNotifier.value : Duration.zero;

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
  }

  /// System Back / swipe-down while the editor is open: step back inside
  /// the dialog (preview/LRC → results, guarding unsaved text) before
  /// closing the whole editor.
  void _stepEditorBack() {
    final key = _editorKey;
    if (key == null) {
      if (mounted && _showEditor) _closeEditor();
      return;
    }
    () async {
      final consumed = await key.currentState?.onBackPressed() ?? false;
      if (!consumed && mounted && _showEditor) _closeEditor();
    }();
  }

  void _finishEditorSession(
    int session, {
    bool showLyrics = false,
  }) {
    if (!mounted || !_showEditor || session != _editorSession) {
      return;
    }

    if (showLyrics) {
      _showLyrics = true;
    }

    _closeEditor();
  }

  Future<void> _applyEditorLyrics(
    Track target,
    int session,
    LyricsResult result, {
    bool settle = true,
  }) async {
    if (!mounted || !_showEditor || session != _editorSession) {
      return;
    }

    // Snapshot the list so later caller-side mutations cannot change the
    // value being saved.
    final selection = LyricsResult(
      source: result.source,
      songTitle: result.songTitle,
      artistName: result.artistName,
      lines: List<LyricLine>.of(result.lines),
    );

    // This invalidates automatic commits synchronously, before any await.
    final save = DatabaseService.cacheLyrics(
      target.id,
      selection,
    );

    final revision = DatabaseService.lyricsRevisionFor(target.id);

    // Publish only into the active track's shared lyrics notifier.
    if (widget.handler.currentTrack?.id == target.id) {
      widget.lyricsNotifier.value =
          selection.source == 'none' ? const [] : selection.lines;
    }

    try {
      await save;

      // Another deliberate choice may have superseded this save.
      if (DatabaseService.lyricsRevisionFor(target.id) != revision) {
        return;
      }

      if (settle) {
        _finishEditorSession(
          session,
          showLyrics: widget.handler.currentTrack?.id == target.id,
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

  /// A failed disk save keeps the deliberate session choice rather than
  /// allowing an older automatic result to return. The editor remains open
  /// if the same editor session is still present.

  Future<void> _saveEditorMetadata(
    Track target,
    int session,
    String newTitle,
    String newArtist,
    String newCoverUrl, {
    bool settle = true,
  }) async {
    if (!mounted || !_showEditor || session != _editorSession) {
      return;
    }

    final handler = widget.handler;

    final updated = target.copyWith(
      title: newTitle,
      uploader: newArtist,
      coverUrl: newCoverUrl,
    );

    try {
      await DatabaseService.updateTrackMetadata(updated);

      // The target remains the captured track even if playback changed
      // while the database operation was pending.
      handler.updateCurrentTrackMetadata(updated);

      if (!mounted) return;

      if (_displayTrack.id == updated.id) {
        setState(() => _displayTrack = updated);
      }

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

  /// Existing limitation: parts of `updateTrackMetadata` still swallow
  /// persistence errors internally. This callback can only report errors
  /// that propagate. That broader persistence contract is outside this
  /// lyric-ownership patch.

  Widget _buildEditor() {
    final target = _editorTrack;

    if (target == null) {
      return const SizedBox.shrink();
    }

    // Capture these values in this widget's callbacks. Never consult
    // mutable _displayTrack to determine their save target.
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
        if (session == _editorSession) {
          _closeEditor();
        }
      },
      onApplyLyrics: (result, {bool settle = true}) {
        return _applyEditorLyrics(
          target,
          session,
          result,
          settle: settle,
        );
      },
      onUpdateMetadata: (title, artist, cover, {bool settle = true}) {
        return _saveEditorMetadata(
          target,
          session,
          title,
          artist,
          cover,
          settle: settle,
        );
      },
    );
  }

  void _startDownload() {
    Haptics.light();
    DownloadManager.instance.startDownload(_displayTrack);
    if (mounted) {
      setState(() => _downloadTask = _liveTaskFor(_displayTrack.id));
    }
  }

  void _playOrPause() {
    Haptics.light();
    if (_isActive) {
      _isPlaying ? widget.handler.pause() : widget.handler.play();
    } else {
      _followHandler = true;
      widget.handler.playTrack(_displayTrack);
    }
  }

  void _prev() {
    Haptics.selection();
    _followHandler = true;
    widget.handler.skipToPrevious();
  }

  void _next() {
    Haptics.selection();
    _followHandler = true;
    widget.handler.skipToNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The same backdrop as the rest of the app — the aura at the top, black
      // below — rather than a flat black page. The route morph paints its own
      // opaque surface underneath, so this stays honest during the transition.
      backgroundColor: AppColors.background,
      body: PopScope(
        canPop: !_showEditor,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_showEditor) {
            Haptics.selection();
            _stepEditorBack();
          }
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: AmbientBackground(coverUrl: _displayTrack.coverUrl),
            ),
            GestureDetector(
              // Swipe down to dismiss — threshold lifted 320→480 and
              // effectively top-chrome only: the inner SyncedLyricsView ListView
              // now wins the arena for scrolls, so a lyric flick no longer
              // dismisses the sheet.
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
                minimum: const EdgeInsets.only(top: 16),
                child: Column(
                  children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: AppMotion.base,
                        switchInCurve: AppMotion.standard,
                        switchOutCurve: AppMotion.standardReverse,
                        transitionBuilder: (child, animation) {
                          // Editor slides up from below; player content slides
                          // down when editor appears and back up when it leaves.
                          final isEditor =
                              child.key == const ValueKey('editor');
                          final offset = isEditor
                              ? Tween<Offset>(
                                  begin: const Offset(0, 0.15),
                                  end: Offset.zero)
                              : Tween<Offset>(
                                  begin: const Offset(0, -0.08),
                                  end: Offset.zero);
                          return SlideTransition(
                            position: offset.animate(animation),
                            child: FadeTransition(
                                opacity: animation, child: child),
                          );
                        },
                        child: _showEditor
                            ? KeyedSubtree(
                                key: const ValueKey('editor'),
                                child: _buildEditor(),
                              )
                            : KeyedSubtree(
                                key: const ValueKey('player'),
                                child: Column(
                                  children: [
                                    _topBar(),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 24, vertical: 8),
                                        child: AnimatedSwitcher(
                                          duration: AppMotion.base,
                                          switchInCurve: AppMotion.standard,
                                          switchOutCurve:
                                              AppMotion.standardReverse,
                                          transitionBuilder:
                                              (child, animation) {
                                            return FadeTransition(
                                              opacity: animation,
                                              child: ScaleTransition(
                                                scale: Tween<double>(
                                                        begin: 0.92, end: 1.0)
                                                    .animate(animation),
                                                child: child,
                                              ),
                                            );
                                          },
                                          child: _showLyrics && _isActive
                                              ? ValueListenableBuilder<
                                                  List<LyricLine>>(
                                                  key: const ValueKey('lyrics'),
                                                  valueListenable:
                                                      widget.lyricsNotifier,
                                                  builder: (context, lines, _) {
                                                    return SyncedLyricsView(
                                                      lines: lines,
                                                      positionNotifier: widget
                                                          .positionNotifier,
                                                      onSeek: (sec) =>
                                                          widget.handler.seek(
                                                        Duration(
                                                            milliseconds:
                                                                (sec * 1000)
                                                                    .toInt()),
                                                      ),
                                                      onOpenEditor: () =>
                                                          _openEditor(
                                                              lyricsTab: true),
                                                    );
                                                  },
                                                )
                                              : _albumArt(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                    _bottomPanel(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              tooltip: '收起',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.textSecondary,
                size: 30,
              ),
            ),
          ),
          Expanded(
            child: Text(
              _isActive ? '当前曲目' : '曲目详情',
              textAlign: TextAlign.center,
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
                letterSpacing: 0.4,
              ),
            ),
          ),
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              tooltip: _showLyrics ? '显示封面' : '显示歌词',
              onPressed: !_isActive
                  ? null
                  : () {
                      Haptics.selection();
                      setState(() => _showLyrics = !_showLyrics);
                    },
              icon: Icon(
                _showLyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined,
                color: _showLyrics && _isActive
                    ? AppColors.accent
                    : AppColors.textMuted,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _albumArt() {
    return LayoutBuilder(
      key: const ValueKey('art'),
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight;
        // Avoid overflow when parent is short (keyboard, landscape): clamp
        // upper bound to min(maxHeight, maxWidth) and floor to min(120, upper)
        final available = maxHeight > 0 ? maxHeight : constraints.maxWidth;
        final upper =
            available < constraints.maxWidth ? available : constraints.maxWidth;
        final lower = upper < 120 ? upper : 120.0;
        final size =
            maxHeight > 0 ? (maxHeight * 0.82).clamp(lower, upper) : 240.0;
        return Center(
          child: AnimatedScale(
            scale: (_isActive && _isPlaying) ? 1.0 : 0.96,
            duration: MediaQuery.of(context).disableAnimations ||
                    MediaQuery.of(context).accessibleNavigation
                ? Duration.zero
                : AppMotion.base,
            curve: AppMotion.standard,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                boxShadow: const [
                  BoxShadow(
                    color: AppColors.black55,
                    blurRadius: 44,
                    spreadRadius: -6,
                    offset: Offset(0, 20),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                child: CachedCoverImage(
                  url: _displayTrack.coverUrl,
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

  Widget _bottomPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_showEditor) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarqueeText(
                        text: _displayTrack.title,
                        style: AppTypography.title,
                      ),
                      const SizedBox(height: 4),
                      MarqueeText(
                        text: _displayTrack.uploader,
                        phase: 0.35,
                        style: AppTypography.bodyMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.queue_music_rounded,
                      color: AppColors.textSecondary, size: 24),
                  tooltip: '播放队列',
                  onPressed: () {
                    PlaybackQueueSheet.show(
                      context,
                      handler: widget.handler,
                    );
                  },
                ),
                _SleepTimerButton(handler: widget.handler),
                IconButton(
                  icon: const Icon(Icons.edit_note_rounded,
                      color: AppColors.textSecondary, size: 24),
                  tooltip: '编辑',
                  onPressed: () => _openEditor(lyricsTab: _showLyrics),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          _seekBar(),
          const SizedBox(height: 4),
          _transportControls(),
        ],
      ),
    );
  }

  Widget _seekBar() {
    return PlayerSeekBar(
      positionNotifier: widget.positionNotifier,
      durationNotifier: widget.durationNotifier,
      fallbackSeconds:
          _displayTrack.duration > 0 ? _displayTrack.duration.toDouble() : 1.0,
      isActive: _isActive,
      onSeek: widget.handler.seek,
    );
  }

  Widget _transportControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _favoriteButton(),
        _skipButton(Icons.skip_previous_rounded, _isActive ? _prev : null),
        _playButton(),
        _skipButton(Icons.skip_next_rounded, _isActive ? _next : null),
        _modeButton(),
      ],
    );
  }

  Widget _skipButton(IconData icon, VoidCallback? onPressed) {
    return IconButton(
      icon: Icon(icon,
          color:
              onPressed == null ? AppColors.textFaint : AppColors.textPrimary,
          size: 40),
      onPressed: onPressed,
    );
  }

  Widget _favoriteButton() {
    return SizedBox(
      width: 48,
      child: IconButton(
        icon: Icon(
          _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: _isFavorite ? AppColors.accent : AppColors.textMuted,
          size: 26,
        ),
        tooltip: _isFavorite ? '取消收藏' : '收藏',
        onPressed: _handleFavorite,
      ),
    );
  }

  /// The primary control mirrors the track's real state, because playback is
  /// download-then-play: a track that is not on disk cannot be played, so it
  /// offers a download (with the same progress ring used in the lists) and
  /// only becomes play/pause once the file is there.
  Widget _playButton() {
    final task = _downloadTask;

    // Download and downloading are the *same button*, not two designs: the
    // circle, its fill, its border and its glyph are identical, and starting a
    // download only adds a progress arc around the outside. Previously the
    // filled circle was replaced by a bare thin ring, so the control appeared
    // to vanish the instant you tapped it.
    if (task != null || !_isDownloaded) {
      return _circleButton(
        tooltip: task != null ? '下载中' : '下载',
        onPressed: task != null ? null : _startDownload,
        filled: false,
        progress: task?.fraction,
        icon: const Icon(Icons.download_rounded,
            color: AppColors.textPrimary, size: 34),
      );
    }

    final playing = _isActive && _isPlaying;
    return _circleButton(
      tooltip: playing ? '暂停' : '播放',
      onPressed: _playOrPause,
      filled: true,
      icon: AnimatedSwitcher(
        duration: AppMotion.instant,
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          key: ValueKey<bool>(playing),
          color: AppColors.textPrimary,
          size: 40,
        ),
      ),
    );
  }

  /// The one primary-control shape. [progress], when set, draws a determinate
  /// arc just outside the circle without altering the circle itself.
  Widget _circleButton({
    required Widget icon,
    required VoidCallback? onPressed,
    required String tooltip,
    required bool filled,
    double? progress,
  }) {
    final button = Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? AppColors.accent : AppColors.white12,
        border: filled ? null : Border.all(color: AppColors.hairlineStrong),
      ),
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: icon,
      ),
    );

    // Always occupy the same 76×76 footprint so adding/removing the
    // progress ring never reflows the transport row.
    return SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (progress != null)
            ProgressRing(
              fraction: progress,
              size: 76,
              strokeWidth: 3,
              trackColor: AppColors.hairline,
            ),
          button,
        ],
      ),
    );
  }

  Widget _modeButton() {
    final IconData icon = _isShuffle
        ? Icons.shuffle_rounded
        : (_loopMode == LoopMode.one
            ? Icons.repeat_one_rounded
            : Icons.repeat_rounded);
    final label =
        _isShuffle ? '随机播放' : (_loopMode == LoopMode.one ? '单曲循环' : '列表循环');
    // Shuffle and repeat-one are both "not the default", so both light up.
    final active = _isShuffle || _loopMode == LoopMode.one;
    return SizedBox(
      width: 48,
      child: IconButton(
        icon: Icon(icon,
            color: active ? AppColors.accent : AppColors.textMuted, size: 24),
        tooltip: label,
        onPressed: () {
          Haptics.medium();
          widget.handler.cyclePlayMode();
        },
      ),
    );
  }
}

/// Sleep-timer entry with live active state. Self-subscribed so the sheet
/// itself never rebuilds on the 1s countdown ticks.
class _SleepTimerButton extends StatelessWidget {
  final BiliBeatAudioHandler handler;

  const _SleepTimerButton({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SleepTimerState>(
      stream: handler.sleepTimerStream,
      initialData: handler.sleepTimerState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? handler.sleepTimerState;
        final active = state.isActive;
        final tooltip = active
            ? (state.mode == SleepTimerMode.endOfTrack
                ? '睡眠定时：播完当前歌曲'
                : '睡眠定时：${formatDuration(state.remaining)}')
            : '睡眠定时';
        return IconButton(
          icon: Icon(
            active ? Icons.bedtime_rounded : Icons.bedtime_outlined,
            color: active ? AppColors.accent : AppColors.textSecondary,
            size: 24,
          ),
          tooltip: tooltip,
          onPressed: () {
            SleepTimerSheet.show(context, handler: handler);
          },
        );
      },
    );
  }
}
