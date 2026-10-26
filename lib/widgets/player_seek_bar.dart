import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/format.dart';

/// Playback position: a thin line you can grab, with the elapsed and
/// remaining time beneath it.
///
/// While the thumb is held the bar shows the dragged value rather than the
/// live position, and seeks once on release.
///
/// A trimmed song ([start], [end]) is shown as the part that plays: the bar
/// and both times span the trim, while [position] and [onSeek] stay in the
/// file's time.
class PlayerSeekBar extends StatefulWidget {
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;

  /// Used until the real duration is known.
  final Duration fallback;
  final ValueChanged<Duration> onSeek;

  /// Where the song starts in the file.
  final Duration start;

  /// Where it ends; null for the end of the file.
  final Duration? end;

  const PlayerSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.fallback,
    required this.onSeek,
    this.start = Duration.zero,
    this.end,
  });

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  double? _drag;

  static const TextStyle _time = TextStyle(
    color: AppColors.textMuted,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.duration, widget.position]),
      builder: (context, _) {
        final known = widget.duration.value;
        final span = trimmedSpan(
          known > Duration.zero ? known : widget.fallback,
          start: widget.start,
          end: widget.end,
        );
        final total = (span.end - span.start).inMilliseconds / 1000.0;
        final max = total > 0 ? total : 1.0;
        final at = (_drag ??
                (widget.position.value - span.start).inMilliseconds / 1000.0)
            .clamp(0.0, max);
        Duration seconds(double s) =>
            Duration(milliseconds: (s * 1000).round());

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: _drag == null ? 3 : 5,
                activeTrackColor: AppColors.textPrimary,
                inactiveTrackColor: AppColors.white24,
                thumbColor: AppColors.textPrimary,
                overlayColor: AppColors.white12,
                trackShape: const _FullWidthTrack(),
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _drag == null ? 4 : 7,
                  elevation: 0,
                  pressedElevation: 0,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: SizedBox(
                height: 28,
                child: Slider(
                  value: at,
                  max: max,
                  semanticFormatterCallback: (v) => formatDuration(seconds(v)),
                  onChangeStart: (v) => setState(() => _drag = v),
                  onChanged: (v) => setState(() => _drag = v),
                  onChangeEnd: (v) {
                    Haptics.light();
                    widget.onSeek(span.start + seconds(v));
                    setState(() => _drag = null);
                  },
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatDuration(seconds(at)), style: _time),
                Text('-${formatDuration(seconds(max - at))}', style: _time),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The part of a [length]-long file that plays, trimmed to [start] and
/// [end]; the whole file where the trim leaves nothing (or the length is not
/// known yet and the trim would run past it).
({Duration start, Duration end}) trimmedSpan(Duration length,
    {Duration start = Duration.zero, Duration? end}) {
  var to = end ?? length;
  if (length > Duration.zero && to > length) to = length;
  if (start < Duration.zero || to - start <= Duration.zero) {
    return (start: Duration.zero, end: length);
  }
  return (start: start, end: to);
}

/// A slider track that spans the whole width, so the bar lines up with the
/// title above and the times below instead of being inset by the thumb.
class _FullWidthTrack extends RoundedRectSliderTrackShape {
  const _FullWidthTrack();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final height = sliderTheme.trackHeight ?? 3;
    final top = offset.dy + (parentBox.size.height - height) / 2;
    return Rect.fromLTWH(offset.dx, top, parentBox.size.width, height);
  }
}
