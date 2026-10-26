import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

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

  /// Whether the song is moving. The player reports its position a few
  /// times a second; a word-timed line is filled between reports by
  /// extrapolating from the last one, but only while this is true. Without
  /// it, the fill runs on briefly past each report.
  final ValueListenable<bool>? playing;
  final ValueChanged<Duration>? onSeek;
  final bool calibrating;

  /// Receives the absolute offset (seconds) the tapped line implies.
  final ValueChanged<double>? onCalibrate;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.position,
    this.playing,
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
    // In whole milliseconds, as [_tap] seeks: in doubles the two sums are
    // not each other's inverse and a tapped line lit the one before it.
    final at = position.inMilliseconds;
    final offset = widget.lyrics.offset;
    var lo = 0;
    var hi = _lines.length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (((_lines[mid].time + offset) * 1000).round() <= at) {
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
    // A drag, or a mouse wheel (which reports no drag, only a direction).
    final byHand = (notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle);
    if (byHand) {
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
                          position: widget.position,
                          playing: widget.playing,
                          offset: widget.lyrics.offset,
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

  /// For a word-timed line while it is the one being sung.
  final ValueListenable<Duration> position;
  final ValueListenable<bool>? playing;
  final double offset;

  const _Line({
    super.key,
    required this.line,
    required this.synced,
    required this.active,
    required this.distance,
    required this.onTap,
    required this.position,
    required this.playing,
    required this.offset,
  });

  /// The line as text; while it is sung and its words are timed, it fills
  /// left to right as the song moves, KTV-style ([KaraokeText]).
  Widget _text() {
    final words = line.words;
    if (!active || !synced || words == null) return Text(line.text);
    return KaraokeText(
      text: line.text,
      words: words,
      position: position,
      playing: playing,
      offset: offset,
    );
  }

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
              child: _text(),
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

/// A word-timed line being sung, filled left to right like a KTV caption:
/// the sung part in the line's own colour, the rest dimmed, and the edge
/// between them gliding through each word over the time it is sung.
///
/// It repaints every frame while it is on screen, without rebuilding.
class KaraokeText extends StatefulWidget {
  final String text;
  final List<LyricWord> words;
  final ValueListenable<Duration> position;
  final ValueListenable<bool>? playing;

  /// The lyrics' timing correction, in seconds.
  final double offset;

  const KaraokeText({
    super.key,
    required this.text,
    required this.words,
    required this.position,
    this.playing,
    this.offset = 0,
  });

  /// How far into each word the song is at [now] (seconds, on the lyrics'
  /// own clock): 0 before it starts, 1 once it ends, linear in between.
  static List<double> progress(List<LyricWord> words, double now) => [
        for (final w in words)
          if (now >= w.end)
            1.0
          else if (now <= w.start)
            0.0
          else
            (now - w.start) / (w.end - w.start),
      ];

  @override
  State<KaraokeText> createState() => KaraokeTextState();
}

@visibleForTesting
class KaraokeTextState extends State<KaraokeText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);

  /// Seconds on the lyrics' clock, as last painted.
  final ValueNotifier<double> now = ValueNotifier(0);

  /// The last reported position and when (ticker time) it arrived.
  int _reportedMs = -1;
  Duration _reportedAt = Duration.zero;
  Duration _elapsed = Duration.zero;

  /// Never run ahead of the last report by more than this: if the reports
  /// stop (a stall the playing flag has not caught up with), so does the fill.
  static const int _maxLeadMs = 600;

  @override
  void initState() {
    super.initState();
    _reportedMs = widget.position.value.inMilliseconds;
    now.value = _reportedMs / 1000 - widget.offset;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    final reported = widget.position.value.inMilliseconds;
    if (reported != _reportedMs) {
      _reportedMs = reported;
      _reportedAt = elapsed;
    }
    final moving = widget.playing?.value ?? true;
    final lead = moving
        ? (elapsed - _reportedAt).inMilliseconds.clamp(0, _maxLeadMs)
        : 0;
    final next = (_reportedMs + lead) / 1000 - widget.offset;
    // A report slightly behind what was already drawn is jitter, not the
    // song going back: hold rather than let the fill flicker backwards.
    // A real jump back (a seek) is larger and is followed.
    final behind = now.value - next;
    if (behind > 0 && behind < 0.35) return;
    now.value = next;
  }

  @visibleForTesting
  Duration get elapsed => _elapsed;

  @override
  void dispose() {
    _ticker.dispose();
    now.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: LayoutBuilder(builder: (context, constraints) {
        TextPainter painter(Color? color) => TextPainter(
              text: TextSpan(
                  text: widget.text, style: style.copyWith(color: color)),
              textDirection: direction,
              textScaler: scaler,
            )..layout(maxWidth: constraints.maxWidth);
        final sung = painter(style.color);
        final ahead = painter(AppColors.white45);
        return CustomPaint(
          size: sung.size,
          painter: _KaraokePainter(
            sung: sung,
            ahead: ahead,
            words: widget.words,
            now: now,
          ),
        );
      }),
    );
  }
}

class _KaraokePainter extends CustomPainter {
  final TextPainter sung;
  final TextPainter ahead;
  final List<LyricWord> words;
  final ValueListenable<double> now;

  _KaraokePainter({
    required this.sung,
    required this.ahead,
    required this.words,
    required this.now,
  }) : super(repaint: now);

  @override
  void paint(Canvas canvas, Size size) {
    ahead.paint(canvas, Offset.zero);
    final fractions = KaraokeText.progress(words, now.value);
    final clip = Path();
    var from = 0;
    for (var i = 0; i < words.length; i++) {
      final to = from + words[i].text.length;
      final f = fractions[i];
      if (f > 0) {
        // A word can wrap onto the next line: fill its pieces in order.
        final boxes = sung.getBoxesForSelection(
          TextSelection(baseOffset: from, extentOffset: to),
          boxHeightStyle: ui.BoxHeightStyle.max,
        );
        final width = boxes.fold<double>(0, (sum, b) => sum + b.right - b.left);
        var left = width * f;
        for (final b in boxes) {
          if (left <= 0) break;
          final w = (b.right - b.left).clamp(0.0, left);
          // A little taller than the line, so no stroke is cut.
          clip.addRect(
              Rect.fromLTRB(b.left, b.top - 4, b.left + w, b.bottom + 4));
          left -= w;
        }
      }
      from = to;
    }
    canvas.save();
    canvas.clipPath(clip);
    sung.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_KaraokePainter old) =>
      old.sung != sung || old.ahead != ahead || old.words != words;
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
            width: 48,
            height: 48,
            child: Icon(Icons.vertical_align_center_rounded,
                color: AppColors.textPrimary, size: 22),
          ),
        ),
      ),
    );
  }
}
