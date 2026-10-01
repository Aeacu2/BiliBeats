import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/lyrics.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';

/// Lyrics that follow the song.
///
/// The line being sung is bright and held a little above the middle; the
/// rest recede. Scrolling by hand takes over — following resumes on its own
/// a few seconds later, or at once from the button that appears. Tapping a
/// line seeks to it.
///
/// While [calibrating], tapping the line you *hear* reports the timing
/// correction instead ([onCalibrate]); nothing else changes, so calibrating
/// is done in place, against the real song.
///
/// Lyrics without timestamps are shown as a plain, readable page.
class LyricsView extends StatefulWidget {
  final Lyrics lyrics;
  final ValueListenable<Duration> position;
  final ValueChanged<Duration>? onSeek;
  final bool calibrating;

  /// Receives the absolute offset (seconds) the tapped line implies.
  final ValueChanged<double>? onCalibrate;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.position,
    this.onSeek,
    this.calibrating = false,
    this.onCalibrate,
  });

  /// People tap a moment after they hear a line begin.
  static const double reactionSeconds = 0.20;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _scroll = ScrollController();
  List<GlobalKey> _keys = const [];

  int _active = -1;
  bool _browsing = false;
  Timer? _resumeTimer;

  static const Duration _browseGrace = Duration(seconds: 4);

  /// Where the active line rests, as a fraction of the viewport height.
  static const double _restAt = 0.36;

  List<LyricLine> get _lines => widget.lyrics.lines;
  bool get _synced => widget.lyrics.synced;

  @override
  void initState() {
    super.initState();
    _keys = List.generate(_lines.length, (_) => GlobalKey());
    widget.position.addListener(_onPosition);
    _active = _indexAt(widget.position.value);
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow(jump: true));
  }

  @override
  void didUpdateWidget(covariant LyricsView old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    if (!identical(old.lyrics.lines, widget.lyrics.lines)) {
      _keys = List.generate(_lines.length, (_) => GlobalKey());
      _browsing = false;
      _resumeTimer?.cancel();
      _active = _indexAt(widget.position.value);
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow(jump: true));
    } else if (old.lyrics.offset != widget.lyrics.offset) {
      _active = _indexAt(widget.position.value);
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    widget.position.removeListener(_onPosition);
    _scroll.dispose();
    super.dispose();
  }

  /// Last line whose (corrected) time has passed; -1 before the first.
  int _indexAt(Duration position) {
    if (!_synced) return -1;
    final at = position.inMilliseconds / 1000.0 - widget.lyrics.offset;
    var lo = 0;
    var hi = _lines.length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_lines[mid].time <= at) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  void _onPosition() {
    final index = _indexAt(widget.position.value);
    if (index == _active) return;
    setState(() => _active = index);
    if (!_browsing) _follow();
  }

  void _follow({bool jump = false}) {
    if (!mounted || !_synced || _keys.isEmpty) return;
    final target = _keys[_active.clamp(0, _keys.length - 1)].currentContext;
    if (target == null) return;
    final media = MediaQuery.maybeOf(context);
    final still = jump ||
        media?.disableAnimations == true ||
        media?.accessibleNavigation == true;
    Scrollable.ensureVisible(
      target,
      alignment: _restAt,
      duration: still ? Duration.zero : AppMotion.slow,
      curve: AppMotion.standard,
    );
  }

  void _resume() {
    _resumeTimer?.cancel();
    if (!mounted) return;
    setState(() => _browsing = false);
    _follow();
  }

  bool _onScroll(ScrollNotification notification) {
    if (!_synced) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _resumeTimer?.cancel();
      if (!_browsing) setState(() => _browsing = true);
    } else if (notification is ScrollEndNotification && _browsing) {
      _resumeTimer?.cancel();
      _resumeTimer = Timer(_browseGrace, _resume);
    }
    return false;
  }

  void _tap(int index) {
    final line = _lines[index];
    if (widget.calibrating) {
      final heardAt = widget.position.value.inMilliseconds / 1000.0;
      final offset = heardAt - line.time - LyricsView.reactionSeconds;
      Haptics.light();
      widget.onCalibrate?.call((offset * 100).round() / 100);
      return;
    }
    Haptics.selection();
    final seconds = (line.time + widget.lyrics.offset).clamp(0.0, 86400.0);
    widget.onSeek?.call(Duration(milliseconds: (seconds * 1000).round()));
    _resume();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final tappable =
            _synced && (widget.calibrating || widget.onSeek != null);

        return Stack(
          children: [
            // Lines dissolve into the page at both ends instead of being cut.
            ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0.0, 0.14, 0.82, 1.0],
              ).createShader(rect),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: EdgeInsets.only(
                    top: height * (_synced ? _restAt : 0.12),
                    bottom: height * (_synced ? 0.6 : 0.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _lines.length; i++)
                        _Line(
                          key: _keys[i],
                          line: _lines[i],
                          synced: _synced,
                          // Before the first line everything is "ahead".
                          distance: _synced ? (i - _active).abs() : 1,
                          active: i == _active,
                          onTap: tappable ? () => _tap(i) : null,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_browsing && !widget.calibrating)
              Positioned(
                right: 0,
                bottom: 10,
                child: _ResumeButton(onPressed: () {
                  Haptics.selection();
                  _resume();
                }),
              ),
          ],
        );
      },
    );
  }
}

class _Line extends StatelessWidget {
  final LyricLine line;
  final bool synced;
  final bool active;
  final int distance;
  final VoidCallback? onTap;

  const _Line({
    super.key,
    required this.line,
    required this.synced,
    required this.active,
    required this.distance,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final translation = line.translation;
    // One size in every state: emphasis is brightness alone, so nothing
    // reflows as the song moves and the active line never jumps.
    final Color color;
    if (!synced) {
      color = AppColors.textSecondary;
    } else if (active) {
      color = AppColors.textPrimary;
    } else {
      color = distance <= 1 ? AppColors.white45 : AppColors.white30;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: synced ? 11 : 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedDefaultTextStyle(
              duration: AppMotion.base,
              curve: AppMotion.standard,
              style: TextStyle(
                color: color,
                fontSize: synced ? 24 : 18,
                height: 1.3,
                fontWeight: synced ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: synced ? -0.3 : 0,
              ),
              child: Text(line.text),
            ),
            if (translation != null && translation.isNotEmpty) ...[
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: AppMotion.base,
                curve: AppMotion.standard,
                style: TextStyle(
                  color: active ? AppColors.textSecondary : AppColors.white30,
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
                child: Text(translation),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResumeButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _ResumeButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white12,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: const Tooltip(
          message: '回到当前',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.vertical_align_center_rounded,
                color: AppColors.textPrimary, size: 22),
          ),
        ),
      ),
    );
  }
}
