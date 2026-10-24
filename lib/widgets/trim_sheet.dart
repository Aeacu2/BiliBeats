import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/track.dart';
import '../services/trim_store.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/format.dart';
import '../utils/snack.dart';
import 'sheet.dart';

/// 裁剪: where the song starts and ends inside its video.
///
/// Two handles on one bar. While the song is playing, letting go of a handle
/// plays from there (the start, or the last seconds before the end), and
/// 从这里开始 / 到这里结束 take the moment being heard — so the cut can be
/// set by ear, without reading times.
class TrimSheet extends StatefulWidget {
  final Track track;

  const TrimSheet({super.key, required this.track});

  static Future<void> show(BuildContext context, Track track) =>
      showAppSheet<void>(context, builder: (_) => TrimSheet(track: track));

  @override
  State<TrimSheet> createState() => _TrimSheetState();
}

class _TrimSheetState extends State<TrimSheet> {
  final _handler = AppServices.instance.handler;
  late final Trim? _saved = TrimStore.of(widget.track.id);
  late Duration _length;
  late RangeValues _range;

  /// Shortest song a trim may leave.
  static const Duration _minimum = Duration(seconds: 5);

  /// How much before the end a preview of the end starts.
  static const Duration _lead = Duration(seconds: 4);

  bool get _playingThis => _handler.currentTrack?.id == widget.track.id;

  @override
  void initState() {
    super.initState();
    final known = _playingThis ? _handler.durationNotifier.value : Duration.zero;
    _length = known > Duration.zero
        ? known
        : Duration(seconds: widget.track.duration);
    if (_length <= _minimum) _length = _minimum * 2;
    final saved = _saved;
    _range = RangeValues(
      _ms(saved?.start ?? Duration.zero),
      _ms(saved?.end ?? _length),
    );
  }

  double _ms(Duration d) =>
      d.inMilliseconds.clamp(0, _length.inMilliseconds).toDouble();

  Duration get _start => Duration(milliseconds: _range.start.round());
  Duration get _end => Duration(milliseconds: _range.end.round());

  Trim get _trim => Trim(
        start: _start < const Duration(milliseconds: 500)
            ? Duration.zero
            : _start,
        // Within a second of the end is the end.
        end: _length - _end < const Duration(seconds: 1) ? null : _end,
      );

  void _onChanged(RangeValues values) {
    final minimum = _minimum.inMilliseconds.toDouble();
    if (values.end - values.start < minimum) return;
    setState(() => _range = values);
  }

  /// Let go of a handle: hear the cut.
  void _preview(RangeValues values, {required bool start}) {
    if (!_playingThis) return;
    final at = start ? _start : _end - _lead;
    unawaited(_handler.seek(at < _start ? _start : at));
    if (!_handler.isPlaying) unawaited(_handler.play());
  }

  RangeValues? _before;

  void _setFromNow({required bool start}) {
    Haptics.selection();
    final now = _ms(_handler.position);
    final minimum = _minimum.inMilliseconds.toDouble();
    setState(() {
      if (start) {
        _range = RangeValues(
            now.clamp(0, _range.end - minimum).toDouble(), _range.end);
      } else {
        _range = RangeValues(
            _range.start,
            now
                .clamp(_range.start + minimum, _length.inMilliseconds)
                .toDouble());
      }
    });
  }

  Future<void> _save(Trim? trim) async {
    Haptics.light();
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      await TrimStore.set(widget.track.id, trim);
    } catch (e) {
      debugPrint('Trim save failed: $e');
      showAppSnackBar(messenger, message: '裁剪未能保存');
      return;
    }
    // Takes effect at once when the song is on and now outside the cut.
    if (trim != null && _playingThis && _handler.position < trim.start) {
      unawaited(_handler.seek(trim.start));
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = _trim != (_saved ?? const Trim());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle('裁剪', detail: '保留 ${formatDuration(_end - _start)}'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Row(
            children: [
              _Time(label: '开始', value: _start),
              const Spacer(),
              _Time(label: '结束', value: _end, end: true),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: RangeSlider(
            values: _range,
            max: _length.inMilliseconds.toDouble(),
            onChangeStart: (values) => _before = values,
            onChanged: _onChanged,
            onChangeEnd: (values) => _preview(values,
                start: _before == null || values.start != _before!.start),
          ),
        ),
        if (_playingThis)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    icon: Icons.first_page_rounded,
                    label: '从这里开始',
                    secondary: true,
                    onPressed: () => _setFromNow(start: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    icon: Icons.last_page_rounded,
                    label: '到这里结束',
                    secondary: true,
                    onPressed: () => _setFromNow(start: false),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Row(
            children: [
              if (_saved != null) ...[
                Expanded(
                  child: PrimaryButton(
                    label: '还原',
                    secondary: true,
                    onPressed: () => _save(null),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: PrimaryButton(
                  label: '保存',
                  onPressed: changed ? () => _save(_trim) : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Time extends StatelessWidget {
  final String label;
  final Duration value;
  final bool end;

  const _Time({required this.label, required this.value, this.end = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.caption),
        const SizedBox(height: 2),
        Text(
          formatDuration(value),
          style: AppTypography.headline.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
