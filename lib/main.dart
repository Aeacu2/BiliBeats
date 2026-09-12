import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/track.dart';
import 'models/playlist.dart';
import 'models/lyric_line.dart';
import 'services/lyrics_engine.dart';
import 'services/database_service.dart';
import 'services/download_manager.dart';
import 'services/audio_player_handler.dart';
import 'services/audio_download_service.dart';
import 'utils/snack.dart';
import 'theme/app_theme.dart';
import 'theme/motion.dart';
import 'widgets/expand_from_card.dart';
import 'widgets/mini_player.dart';
import 'widgets/now_playing_sheet.dart';
import 'widgets/playlist_detail_sheet.dart';
import 'widgets/segment_tabs.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';

import 'package:audio_service/audio_service.dart';

BiliBeatAudioHandler? _audioHandlerInstance;

/// Adapts a [PageController] — a Listenable whose `page` is null until the
/// first frame — into the [Animation] [SegmentTabs] drives its pill with.
/// The fallback index covers the brief window before the view attaches.
class _PageFraction extends Animation<double> with ChangeNotifier {
  _PageFraction(this._controller, this._fallbackIndex) {
    _controller.addListener(notifyListeners);
  }

  /// Balances the listener added in the constructor — [MainLayout] owns one
  /// instance for its lifetime; constructing one per build (the old way)
  /// leaked a listener on the PageController on every rebuild.
  @override
  void dispose() {
    _controller.removeListener(notifyListeners);
    super.dispose();
  }

  final PageController _controller;
  final int _fallbackIndex;

  @override
  double get value {
    if (!_controller.hasClients) return _fallbackIndex.toDouble();
    return (_controller.page ?? _fallbackIndex.toDouble()).clamp(0.0, 1.0);
  }

  // A drag-following fraction has no discrete status; nothing in SegmentTabs
  // reads it, so it stays permanently "active".
  @override
  AnimationStatus get status => AnimationStatus.forward;

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}

/// The one handler registered with `audio_service`. Reading this before
/// [main] has initialised it is a programming error — lazily constructing a
/// second handler here would silently detach playback from the OS media
/// session, so we fail loudly instead.
BiliBeatAudioHandler get audioHandlerInstance {
  final handler = _audioHandlerInstance;
  assert(handler != null, 'audioHandlerInstance read before AudioService.init');
  return handler!;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 60;
  // Edge to edge, with a transparent navigation bar and — the part that
  // matters — no divider. Android draws a hairline above the gesture area by
  // default, which is the line that kept showing under the docked player no
  // matter how flush the card itself was.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));
  _audioHandlerInstance = await AudioService.init(
    builder: BiliBeatAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.bilibeat.channel.audio',
      androidNotificationChannelName: 'BiliBeat',
      androidNotificationOngoing: true,
    ),
  );
  // Android 13+ requires a runtime POST_NOTIFICATIONS grant for notifications
  // on stricter OEM builds. Fire-and-forget: stock Android exempts the media
  // session notification, so the answer is "no" on most devices and that is
  // fine either way.
  if (!kIsWeb && Platform.isAndroid) {
    const channel = MethodChannel('bilibeat/permissions');
    try {
      await channel.invokeMethod('requestNotifications');
    } catch (_) {}
  }
  runApp(const BiliBeatApp());
}

class BiliBeatApp extends StatelessWidget {
  const BiliBeatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BiliBeat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainLayout(),
    );
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> with WidgetsBindingObserver {
  int _activeTabIndex = 0;
  late final BiliBeatAudioHandler _audioHandler = audioHandlerInstance;

  /// Player state is held in notifiers, not State fields. It changes on every
  /// play/pause and every track advance, and as plain `setState` state it
  /// rebuilt the whole tree — both page subtrees included — for a change that
  /// only the ambient backdrop and the docked bar care about.
  /// Not a `ValueNotifier<Track?>`: [Track] equality is id-only, so a
  /// ValueNotifier would drop the metadata-edit assignment (same id, new
  /// title/cover) and leave the docked player showing stale text.
  final TrackNotifier _currentTrack = TrackNotifier();
  final ValueNotifier<bool> _isPlaying = ValueNotifier(false);
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<List<LyricLine>> _lyricsNotifier = ValueNotifier([]);

  /// Also a notifier, and for the same reason as the player state above: the
  /// handler writes a history entry on *every* track change, and holding this
  /// in `setState` state rebuilt both page subtrees each time a song started —
  /// for a change only the 最近播放 rail cares about.
  final ValueNotifier<List<Track>> _recentlyPlayed = ValueNotifier(const []);
  Playlist? _activePlaylistSheet;

  /// UI load generation for lyrics: every current-track event invalidates
  /// earlier lyric work, including A→B→A.
  int _lyricsLoadGeneration = 0;
  String? _lyricsTrackId;

  late final PageController _pageController = PageController();

  /// One instance for the widget's lifetime (see [_PageFraction.dispose]).
  late final _PageFraction _pageFraction = _PageFraction(_pageController, 0);
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initListeners();
    _loadHistory();
  }

  @override
  void dispose() {
    ++_lyricsLoadGeneration;
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _currentTrack.dispose();
    _recentlyPlayed.dispose();
    _isPlaying.dispose();
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _lyricsNotifier.dispose();
    _pageFraction.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App was backgrounded: the native player may have advanced while the
      // Flutter UI was throttled and currentIndexStream was delayed/dropped.
      // Ask the handler to re-anchor its logical index to the player's actual
      // position, then re-sync our notifier even if the stream was missed.
      _audioHandler.syncOnResume();
      final handlerTrack = _audioHandler.currentTrack;
      if (handlerTrack != null && handlerTrack.id != _currentTrack.value?.id) {
        // The handler healed internally but our notifier is still stale — push
        // the authoritative track so MiniPlayer/AmbientBackground refresh.
        _currentTrack.value = handlerTrack;
      } else if (handlerTrack != null) {
        // Even when ids match, the stream may have been missed entirely while
        // backgrounded; re-emitting via syncOnResume's broadcast already did
        // _currentTrackController.add, but our listener may have been paused.
        // Ensure the notifier is at least refreshed to trigger rebuild.
        if (_currentTrack.value?.id == handlerTrack.id) {
          // TrackNotifier uses identity, so re-assigning a new instance with
          // same id still notifies; use handler's instance directly.
          // Only do this if we suspect a missed event: check handler's track
          // against last notified value's runtime identity mismatch is tricky,
          // so we just re-assign when handlerTrack is not identical to current
          // value — cheap and idempotent.
          if (!identical(_currentTrack.value, handlerTrack)) {
            _currentTrack.value = handlerTrack;
          }
        }
      }
    }
  }

  void _initListeners() {
    _subs.add(
      _audioHandler.currentTrackStream.listen((track) {
        final generation = ++_lyricsLoadGeneration;

        if (!mounted) return;

        _currentTrack.value = track;

        if (track == null) {
          _lyricsTrackId = null;
          _lyricsNotifier.value = const [];
          return;
        }

        if (_lyricsTrackId != track.id) {
          _lyricsTrackId = track.id;

          // Never leave the previous song's lyrics visible while loading.
          _lyricsNotifier.value = const [];
        }

        unawaited(
          _loadLyricsForTrack(
            track,
            generation: generation,
          ),
        );
      }),
    );

    _subs.add(_audioHandler.playerStateStream.listen((playing) {
      _isPlaying.value = playing;
    }));

    _subs.add(_audioHandler.positionStream.listen((pos) {
      _positionNotifier.value = pos;
    }));

    _subs.add(_audioHandler.durationStream.listen((dur) {
      _durationNotifier.value = dur;
    }));

    // The handler writes history itself when it auto-advances, so the rail has
    // to follow the store rather than the UI actions that happen to reach it.
    _subs
        .add(DatabaseService.historyUpdateStream.listen((_) => _loadHistory()));

    // User-initiated download failures otherwise vanish silently (the ring
    // just disappears). Neutral copy: never raw exception strings.
    _subs.add(
      DownloadManager.instance.errors.listen((_) {
        if (!mounted) return;

        showAppSnackBar(
          ScaffoldMessenger.of(context),
          message: '下载未完成，请重试',
          backgroundColor: AppColors.backgroundElevated,
          duration: const Duration(seconds: 4),
        );
      }),
    );
  }

  bool _ownsLyricsLoad(
    Track track,
    int generation,
  ) {
    // Check the handler directly: avoids relying exclusively on an
    // optimistic UI assignment or synchronous resume healing.
    return mounted &&
        generation == _lyricsLoadGeneration &&
        _lyricsTrackId == track.id &&
        _currentTrack.value?.id == track.id &&
        _audioHandler.currentTrack?.id == track.id;
  }

  Future<void> _loadLyricsForTrack(
    Track track, {
    required int generation,
  }) async {
    final revision = DatabaseService.lyricsRevisionFor(track.id);

    bool ownsRequest() {
      return _ownsLyricsLoad(track, generation) &&
          DatabaseService.lyricsRevisionFor(track.id) == revision;
    }

    void publishManualIfCurrent() {
      if (!_ownsLyricsLoad(track, generation)) return;

      final manual = DatabaseService.manualLyricsFor(track.id);
      if (manual == null) return;

      _lyricsNotifier.value = manual.source == 'none' ? const [] : manual.lines;
    }

    // The helper catches its own failures.
    try {
      // The user may already have chosen lyrics in this session.
      final manual = DatabaseService.manualLyricsFor(track.id);

      if (manual != null) {
        if (_ownsLyricsLoad(track, generation)) {
          _lyricsNotifier.value =
              manual.source == 'none' ? const [] : manual.lines;
        }
        return;
      }

      final cached = await DatabaseService.getCachedLyrics(track.id);

      if (!ownsRequest()) {
        publishManualIfCurrent();
        return;
      }

      // A deliberate provider selection should bypass automatic title
      // validation just like pasted/current lyrics.
      final latestManual = DatabaseService.manualLyricsFor(track.id);

      if (latestManual != null) {
        _lyricsNotifier.value =
            latestManual.source == 'none' ? const [] : latestManual.lines;
        return;
      }

      final cleanSongTitle =
          LyricsEngine.cleanTitle(track.rawTitle)['songTitle'] ?? '';

      var cacheValid = false;

      if (cached != null &&
          cached.lines.isNotEmpty &&
          cached.source != 'none') {
        // 'user' (pasted/edited LRC) and 'current' (re-applied with an
        // offset) are deliberate user choices. Title-validating them fails
        // — a paste is cached as 「自定义歌词」.
        if (cached.source == 'user' || cached.source == 'current') {
          cacheValid = true;
        } else {
          final cachedTitle = cached.songTitle ?? '';

          cacheValid = cachedTitle.isNotEmpty &&
              LyricsEngine.isTitleMatching(
                cachedTitle,
                cleanSongTitle,
              );
        }
      }

      if (cacheValid) {
        if (ownsRequest()) {
          _lyricsNotifier.value = cached!.lines;
        }
        return;
      }

      if (!ownsRequest()) {
        publishManualIfCurrent();
        return;
      }

      _lyricsNotifier.value = const [];

      final fresh = await LyricsEngine.autoFetchLyrics(track.rawTitle);

      if (!ownsRequest()) {
        publishManualIfCurrent();
        return;
      }

      final accepted = await DatabaseService.cacheAutomaticLyrics(
        track.id,
        fresh,
        expectedRevision: revision,
      );

      if (!accepted || !ownsRequest()) {
        publishManualIfCurrent();
        return;
      }

      // A "not found" result carries placeholder lines; showing an empty
      // list instead lets the lyrics view offer its search/paste action.
      _lyricsNotifier.value = fresh.source == 'none' ? const [] : fresh.lines;
    } catch (error, stack) {
      debugPrint('Lyrics load failed for ${track.id}: $error\n$stack');

      // Do not clear a newer or manually applied value on failure.
      publishManualIfCurrent();
    }
  }

  Future<void> _loadHistory() async {
    final history = await DatabaseService.getRecentlyPlayed();
    if (mounted) _recentlyPlayed.value = history;
  }

  /// Resolve the loop/shuffle queue: a playlist/favorites passes its own
  /// tracks; anywhere else passes null and we default to the whole downloaded
  /// library.
  Future<List<Track>> _resolveQueue(List<Track>? queue) async {
    if (queue != null && queue.isNotEmpty) return queue;
    return DatabaseService.getDownloadedTracks();
  }

  /// Starts a whole collection — 本地, 收藏, a playlist — rather than one
  /// track. Loop-all either way; shuffle is the caller's choice, and it is set
  /// *before* the queue is handed over so the shuffle order is built around
  /// the track that starts.
  void _playCollection(List<Track> tracks, {bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    await _audioHandler.setShuffle(shuffle);
    await _audioHandler.setLoopMode(LoopMode.all);
    if (!mounted) return;
    final first =
        shuffle ? tracks[Random().nextInt(tracks.length)] : tracks.first;
    _currentTrack.value = first;
    _audioHandler.playTrack(first, newQueue: tracks);
  }

  void _onPlayTrackOnly(Track track, {List<Track>? queue}) async {
    _currentTrack.value = track;
    final q = await _resolveQueue(queue);
    _audioHandler.playTrack(track, newQueue: q.isNotEmpty ? q : null);
  }

  void _onPlayTrackAndExpand(Track track, {List<Track>? queue}) async {
    _currentTrack.value = track;
    _openNowPlaying(track: track, follow: true);
    final q = await _resolveQueue(queue);
    _audioHandler.playTrack(track, newQueue: q.isNotEmpty ? q : null);
  }

  /// Honest row-tap contract, shared by search, library rail and playlist
  /// rows: a downloaded track plays in place; a nonlocal track opens
  /// clearly labeled track details without changing playback. No silent
  /// download-then-play on a row tap.
  void _onBrowseSelectTrack(Track track, {List<Track>? queue}) async {
    final downloaded = await AudioDownloadService.isDownloaded(track);
    if (!mounted) return;
    if (downloaded) {
      _onPlayTrackAndExpand(track, queue: queue);
    } else {
      _openNowPlaying(track: track);
    }
  }

  bool _nowPlayingOpen = false;
  final GlobalKey _miniPlayerKey = GlobalKey();

  /// Where the docked card is on screen right now, or null if it is not laid
  /// out (nothing playing yet, first frame).
  Rect? _miniPlayerRect() {
    final box = _miniPlayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    // The card is flush to the bottom and the sides, so its slot *is* the card
    // — no margins to subtract.
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _openNowPlaying({Track? track, bool follow = false}) {
    final focused = track ?? _currentTrack.value;
    if (focused == null) return;
    // A double tap used to stack two identical full-screen routes.
    if (_nowPlayingOpen) return;
    _nowPlayingOpen = true;

    final from =
        focused.id == _audioHandler.currentTrack?.id ? _miniPlayerRect() : null;

    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;

    Navigator.of(context)
        .push(
          PageRouteBuilder(
            transitionDuration: reduceMotion ? Duration.zero : AppMotion.slow,
            reverseTransitionDuration:
                reduceMotion ? Duration.zero : AppMotion.base,
            pageBuilder: (context, animation, secondaryAnimation) {
              return NowPlayingSheet(
                handler: _audioHandler,
                focusedTrack: focused,
                positionNotifier: _positionNotifier,
                durationNotifier: _durationNotifier,
                lyricsNotifier: _lyricsNotifier,
                followHandler: follow,
              );
            },
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
              if (reduceMotion) return child;
              // The docked card *becomes* the page: its rectangle grows to fill
              // the screen and its corner radius unrolls, and on the way back it
              // folds down onto the card again. Falling back to a slide-up keeps
              // the entry sane when there is no card to grow from (opened straight
              // from a search result before anything is docked).
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
              return ExpandFromCard(
                  animation: animation, from: from, child: child);
            },
          ),
        )
        .whenComplete(() => _nowPlayingOpen = false);
  }

  void _onTabTap(int index) {
    if (index == _activeTabIndex) return;

    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;

    setState(() => _activeTabIndex = index);

    if (reduceMotion) {
      _pageController.jumpToPage(index);
    } else {
      _pageController.animateToPage(
        index,
        duration: AppMotion.fast,
        curve: AppMotion.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;
    final dockedHeight = MiniPlayer.totalHeight(context);
    final activePlaylist = _activePlaylistSheet;

    return PopScope(
      canPop: activePlaylist == null,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _activePlaylistSheet == null) return;
        setState(() => _activePlaylistSheet = null);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            // Main browsing surface.
            Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SegmentTabs(
                        labels: const ['聆听', '搜索'],
                        animation: _pageFraction,
                        onTap: _onTabTap,
                      ),
                    ),
                  ),
                ),

                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (index) {
                      if (_activeTabIndex == index) return;
                      setState(() => _activeTabIndex = index);
                    },
                    children: [
                      RepaintBoundary(
                        child: ValueListenableBuilder<List<Track>>(
                          valueListenable: _recentlyPlayed,
                          builder: (context, recent, _) {
                            return HomeScreen(
                              recentlyPlayed: recent,
                              onSelectTrack: _onBrowseSelectTrack,
                              onPlayOnly: _onPlayTrackOnly,
                              onPlayCollection: _playCollection,
                              onOpenPlaylist: (playlist) {
                                FocusManager.instance.primaryFocus?.unfocus();
                                setState(
                                  () => _activePlaylistSheet = playlist,
                                );
                              },
                            );
                          },
                        ),
                      ),
                      RepaintBoundary(
                        child: SearchScreen(
                          onSelectTrack: _onBrowseSelectTrack,
                          onPlayOnly: _onPlayTrackOnly,
                        ),
                      ),
                    ],
                  ),
                ),

                // The shell owns mini-player clearance.
                SizedBox(height: dockedHeight),
              ],
            ),

            // Playlist surface. The mini-player stays accessible below it.
            if (activePlaylist != null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: dockedHeight,
                child: BlockSemantics(
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey(activePlaylist.id),
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: reduceMotion ? Duration.zero : AppMotion.fast,
                    curve: AppMotion.standard,
                    builder: (context, value, child) {
                      return Opacity(
                        opacity: value,
                        child: Transform.translate(
                          offset: Offset(0, (1 - value) * 20),
                          child: child,
                        ),
                      );
                    },
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              setState(() => _activePlaylistSheet = null);
                            },
                            child: const ColoredBox(
                              color: AppColors.black45,
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: PlaylistDetailSheet(
                            playlist: activePlaylist,
                            onSelectTrack: _onBrowseSelectTrack,
                            onPlayOnly: _onPlayTrackOnly,
                            onPlayCollection: _playCollection,
                            onPlaylistUpdated: _loadHistory,
                            onClose: () {
                              setState(() => _activePlaylistSheet = null);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // One persistent listening surface.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ListenableBuilder(
                key: _miniPlayerKey,
                listenable: Listenable.merge([
                  _currentTrack,
                  _isPlaying,
                ]),
                builder: (context, _) {
                  return MiniPlayer(
                    currentTrack: _currentTrack.value,
                    isPlaying: _isPlaying.value,
                    positionNotifier: _positionNotifier,
                    durationNotifier: _durationNotifier,
                    onPlayPause: () {
                      if (_isPlaying.value) {
                        _audioHandler.pause();
                      } else {
                        _audioHandler.play();
                      }
                    },
                    onNext: _audioHandler.skipToNext,
                    onPrevious: _audioHandler.skipToPrevious,
                    onSeek: _audioHandler.seek,
                    onTap: _openNowPlaying,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
