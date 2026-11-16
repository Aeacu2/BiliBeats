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
  final VoidCallback? onStartCalibration;

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
    this.onStartCalibration,
  });

  /// People tap a moment after they hear a line begin.
  static const double reactionSeconds = 0.20;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _scroll = ScrollController();

  List<double> _lineOffsets = const [];
  ({
    List<LyricLine> lines,
    double width,
    TextScaler scaler,
    TextStyle inheritedStyle,
    Locale? locale,
    TextDirection direction
  })? _layout;

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
    widget.position.addListener(_onPosition);
    _active = _indexAt(widget.position.value);
  }

  @override
  void didUpdateWidget(covariant LyricsView old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    if (!identical(old.lyrics.lines, widget.lyrics.lines)) {
      _browsing = false;
      _resumeTimer?.cancel();
      _active = _indexAt(widget.position.value);
    } else if (old.lyrics.offset != widget.lyrics.offset ||
        old.position != widget.position) {
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
    if (!mounted || !_synced || !_scroll.hasClients || _lines.isEmpty) return;
    final scroll = _scroll.position;
    if (!scroll.hasContentDimensions ||
        _lineOffsets.length != _lines.length + 1) {
      return;
    }
    final index = _active.clamp(0, _lines.length - 1);
    final extent = _lineOffsets[index + 1] - _lineOffsets[index];
    final offset = (_lineOffsets[index] + extent * _restAt)
        .clamp(scroll.minScrollExtent, scroll.maxScrollExtent);
    final still = jump ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (still) {
      _scroll.jumpTo(offset);
    } else {
      unawaited(_scroll.animateTo(offset,
          duration: AppMotion.slow, curve: AppMotion.standard));
    }
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

  void _measureLines(BuildContext context, double width) {
    final layout = (
      lines: _lines,
      width: width,
      scaler: MediaQuery.textScalerOf(context),
      inheritedStyle: DefaultTextStyle.of(context).style,
      locale: Localizations.maybeLocaleOf(context),
      direction: Directionality.of(context),
    );
    if (_layout == layout) return;
    _layout = layout;
    // The list builds only nearby lyric rows. Cached text heights let a seek
    // jump directly to a distant row, even if its translation wraps.
    final lineStyle = layout.inheritedStyle.merge(_Line.lineStyle(_synced));
    final translationStyle =
        layout.inheritedStyle.merge(_Line.translationStyle);
    final painter = TextPainter(
      textDirection: layout.direction,
      textScaler: layout.scaler,
      locale: layout.locale,
    );
    double measure(String text, TextStyle style) {
      painter
        ..text = TextSpan(text: text, style: style)
        ..layout(maxWidth: width);
      return painter.height;
    }

    final offsets = <double>[0];
    for (final line in _lines) {
      var extent =
          _Line.paddingFor(_synced) * 2 + measure(line.text, lineStyle);
      final translation = line.translation;
      if (translation != null && translation.isNotEmpty) {
        extent += 4 + measure(translation, translationStyle);
      }
      offsets.add(offsets.last + extent);
    }
    painter.dispose();
    _lineOffsets = offsets;
  }

  void _followAfterLayout() {
    if (!_browsing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_browsing) _follow(jump: true);
      });
    }
  }

  Size? _viewport;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (_synced) {
          final previous = _layout;
          _measureLines(context, constraints.maxWidth);
          if (previous != _layout || _viewport != constraints.biggest) {
            _viewport = constraints.biggest;
            _followAfterLayout();
          }
        }
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
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: _lines.length,
                  itemExtentBuilder: _synced
                      ? (index, _) => index >= _lines.length
                          ? null
                          : _lineOffsets[index + 1] - _lineOffsets[index]
                      : null,
                  padding: EdgeInsets.only(
                    top: height * (_synced ? _restAt : 0.12),
                    bottom: height * (_synced ? 0.6 : 0.2),
                  ),
                  itemBuilder: (context, index) => _Line(
                    line: _lines[index],
                    synced: _synced,
                    distance: _synced ? (index - _active).abs() : 1,
                    active: index == _active,
                    position: widget.position,
                    playing: widget.playing,
                    offset: widget.lyrics.offset,
                    onTap: tappable ? () => _tap(index) : null,
                  ),
                ),
              ),
            ),
            if (_browsing && !widget.calibrating)
              Positioned(
                right: 0,
                bottom: 10,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_synced && widget.onStartCalibration != null) ...[
                      _LyricsActionButton(
                        tooltip: '校准歌词',
                        icon: Icons.tune_rounded,
                        onPressed: widget.onStartCalibration!,
                      ),
                      const SizedBox(width: 8),
                    ],
                    _LyricsActionButton(
                      tooltip: '回到当前',
                      icon: Icons.vertical_align_center_rounded,
                      onPressed: () {
                        Haptics.selection();
                        _resume();
                      },
                    ),
                  ],
                ),
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
    required this.line,
    required this.synced,
    required this.active,
    required this.distance,
    required this.onTap,
    required this.position,
    required this.playing,
    required this.offset,
  });

  static double paddingFor(bool synced) => synced ? 11 : 6;

  static TextStyle lineStyle(bool synced) => TextStyle(
        fontSize: synced ? 24 : 18,
        height: 1.3,
        fontWeight: synced ? FontWeight.w700 : FontWeight.w500,
        letterSpacing: synced ? -0.3 : 0,
      );

  static const translationStyle = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );

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
        padding: EdgeInsets.symmetric(vertical: paddingFor(synced)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedDefaultTextStyle(
              duration: AppMotion.base,
              curve: AppMotion.standard,
              style: lineStyle(synced).copyWith(color: color),
              child: _text(),
            ),
            if (translation != null && translation.isNotEmpty) ...[
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: AppMotion.base,
                curve: AppMotion.standard,
                style: translationStyle.copyWith(
                  color: active ? AppColors.textSecondary : AppColors.white30,
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
  Duration _reportedAt = Duration.zero;
  Duration _elapsed = Duration.zero;
  double _runBaseMs = 0;

  /// Never run ahead of the last report by more than this: if the reports
  /// stop (a stall the playing flag has not caught up with), so does the fill.
  static const int _maxLeadMs = 600;

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_onReport);
    widget.playing?.addListener(_syncTicker);
    _onReport();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant KaraokeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onReport);
      widget.position.addListener(_onReport);
    }
    if (oldWidget.playing != widget.playing) {
      oldWidget.playing?.removeListener(_syncTicker);
      widget.playing?.addListener(_syncTicker);
    }
    if (oldWidget.position != widget.position ||
        oldWidget.offset != widget.offset) {
      _onReport();
      now.value = _runBaseMs / 1000 - widget.offset;
    }
    if (oldWidget.playing != widget.playing) _syncTicker();
  }

  void _onReport() {
    _reportedAt = _elapsed;
    _runBaseMs = widget.position.value.inMilliseconds.toDouble();
    if (!_ticker.isActive) now.value = _runBaseMs / 1000 - widget.offset;
  }

  void _syncTicker() {
    final moving = widget.playing?.value ?? true;
    if (!moving) {
      _ticker.stop();
      final position =
          widget.position.value.inMilliseconds / 1000 - widget.offset;
      // Keep a small interpolation lead on pause to avoid a backwards flash.
      if (now.value - position >= 0.35 || now.value <= position) {
        now.value = position;
      }
      return;
    }
    if (_ticker.isActive) return;
    final displayed = (now.value + widget.offset) * 1000;
    final reported = widget.position.value.inMilliseconds.toDouble();
    final lead = displayed - reported;
    _runBaseMs = lead > 0 && lead < 350 ? displayed : reported;
    _elapsed = _reportedAt = Duration.zero;
    now.value = _runBaseMs / 1000 - widget.offset;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    final reported = widget.position.value.inMilliseconds;
    final lead = (elapsed - _reportedAt).inMilliseconds.clamp(0, _maxLeadMs);
    final next = (_runBaseMs + lead).clamp(0, reported + _maxLeadMs) / 1000 -
        widget.offset;
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
    widget.position.removeListener(_onReport);
    widget.playing?.removeListener(_syncTicker);
    _ticker.dispose();
    _sung.dispose();
    _ahead.dispose();
    now.dispose();
    super.dispose();
  }

  final _sung = TextPainter();
  final _ahead = TextPainter();

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: LayoutBuilder(builder: (context, constraints) {
        void layout(TextPainter painter, Color? color) {
          painter
            ..text =
                TextSpan(text: widget.text, style: style.copyWith(color: color))
            ..textDirection = direction
            ..textScaler = scaler
            ..locale = locale
            ..layout(maxWidth: constraints.maxWidth);
        }

        layout(_sung, style.color);
        layout(_ahead, AppColors.white45);
        return CustomPaint(
          size: _sung.size,
          painter: _KaraokePainter(
            sung: _sung,
            ahead: _ahead,
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
  late final _wordBoxes = _measureWords();

  _KaraokePainter({
    required this.sung,
    required this.ahead,
    required this.words,
    required this.now,
  }) : super(repaint: now);

  List<({List<ui.TextBox> boxes, double width})> _measureWords() {
    final measured = <({List<ui.TextBox> boxes, double width})>[];
    var from = 0;
    for (final word in words) {
      final to = from + word.text.length;
      final boxes = sung.getBoxesForSelection(
        TextSelection(baseOffset: from, extentOffset: to),
        boxHeightStyle: ui.BoxHeightStyle.max,
      );
      measured.add((
        boxes: boxes,
        width: boxes.fold<double>(0, (sum, b) => sum + b.right - b.left),
      ));
      from = to;
    }
    return measured;
  }

  @override
  void paint(Canvas canvas, Size size) {
    ahead.paint(canvas, Offset.zero);
    final fractions = KaraokeText.progress(words, now.value);
    final clip = Path();
    for (var i = 0; i < words.length; i++) {
      final f = fractions[i];
      if (f > 0) {
        // A word can wrap onto the next line: fill its pieces in order.
        final (:boxes, :width) = _wordBoxes[i];
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
    }
    canvas.save();
    canvas.clipPath(clip);
    sung.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_KaraokePainter old) => true;
}

class _LyricsActionButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String tooltip;
  final IconData icon;

  const _LyricsActionButton(
      {required this.onPressed, required this.tooltip, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white12,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: AppColors.textPrimary, size: 22),
          ),
        ),
      ),
    );
  }
}
