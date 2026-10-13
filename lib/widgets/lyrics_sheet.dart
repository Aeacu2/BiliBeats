import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/lyrics.dart';
import '../models/track.dart';
import '../services/lyrics_engine.dart';
import '../services/lyrics_store.dart';
import '../state/lyrics_controller.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/snack.dart';
import 'sheet.dart';
import 'shimmer.dart';

/// What the sheet asks the player to do after it closes.
enum LyricsSheetAction { calibrate }

/// Everything about one song's lyrics, in one place: pick another match,
/// calibrate the timing, write your own, or start over.
///
/// Picking is immediate — tap a match and it is the song's lyrics; there is
/// no preview-then-confirm. The sheet belongs to the track it was opened
/// for, so a choice made after playback moved on is still saved for that
/// song (and not shown over the next one).
class LyricsSheet extends StatefulWidget {
  final Track track;

  const LyricsSheet({super.key, required this.track});

  static Future<LyricsSheetAction?> show(BuildContext context, Track track) {
    return showAppSheet<LyricsSheetAction>(
      context,
      expand: true,
      builder: (_) => LyricsSheet(track: track),
    );
  }

  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  LyricsController get _lyrics => AppServices.instance.lyrics;

  late final TextEditingController _query =
      TextEditingController(text: LyricsController.defaultQuery(widget.track));

  List<Lyrics> _results = const [];
  bool _searching = false;
  int _searchToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    ++_searchToken;
    _query.dispose();
    super.dispose();
  }

  Lyrics? get _current => LyricsStore.peek(widget.track.id);

  Future<void> _search() async {
    final query = _query.text.trim();
    final token = ++_searchToken;
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final results = await LyricsEngine.searchCandidates(query);
    // Only the newest search may land.
    if (!mounted || token != _searchToken) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  Future<void> _save(Future<void> Function() change) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await change();
    } catch (error, stack) {
      debugPrint('Lyrics save failed: $error\n$stack');
      showAppSnackBar(messenger, message: '歌词已应用，但未能保存');
    }
  }

  void _choose(Lyrics lyrics) {
    Haptics.light();
    Navigator.pop(context);
    unawaited(_save(() => _lyrics.choose(widget.track, lyrics)));
  }

  Future<void> _write() async {
    final current = _current;
    final text = await LrcEditorPage.open(
      context,
      initial: current == null || current.isEmpty
          ? ''
          : LyricsEngine.toLrc(current.lines, offset: current.offset),
    );
    if (text == null || !mounted) return;
    final lines = LyricsEngine.parseAny(text);
    if (lines.isEmpty) return;
    Navigator.pop(context);
    unawaited(_save(() => _lyrics.choose(
          widget.track,
          Lyrics(
            source: 'user',
            title: widget.track.title,
            artist: widget.track.uploader,
            lines: lines,
          ),
        )));
  }

  void _rematch() {
    Haptics.light();
    Navigator.pop(context);
    unawaited(_save(() => _lyrics.rematch(widget.track)));
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final hasLyrics = current != null && current.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: TextField(
            controller: _query,
            style: AppTypography.body,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              isDense: true,
              hintText: '歌名 歌手',
              hintStyle:
                  AppTypography.body.copyWith(color: AppColors.textFaint),
              prefixIcon: const Icon(Icons.search_rounded,
                  color: AppColors.textMuted, size: 21),
              filled: true,
              fillColor: AppColors.fieldFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        Expanded(child: _list(current)),
        const Divider(height: 1, color: AppColors.hairline),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            children: [
              _FooterButton(
                icon: Icons.tune_rounded,
                label: '校准',
                onPressed: hasLyrics && current.synced
                    ? () {
                        Haptics.selection();
                        Navigator.pop(context, LyricsSheetAction.calibrate);
                      }
                    : null,
              ),
              _FooterButton(
                icon: Icons.edit_outlined,
                label: hasLyrics ? '编辑' : '粘贴',
                onPressed: _write,
              ),
              _FooterButton(
                icon: Icons.refresh_rounded,
                label: '重新匹配',
                onPressed: _rematch,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _list(Lyrics? current) {
    if (_searching) {
      return ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: const [
          SkeletonTrackTile(),
          SkeletonTrackTile(),
          SkeletonTrackTile(),
        ],
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text('没有找到歌词', style: AppTypography.bodyMedium),
      );
    }
    final currentPrint = current?.fingerprint;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final lyrics = _results[index];
        return _CandidateRow(
          lyrics: lyrics,
          selected: lyrics.fingerprint == currentPrint,
          onTap: () => _choose(lyrics),
        );
      },
    );
  }
}

class _CandidateRow extends StatelessWidget {
  final Lyrics lyrics;
  final bool selected;
  final VoidCallback onTap;

  const _CandidateRow({
    required this.lyrics,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = (lyrics.title ?? '').trim();
    final artist = (lyrics.artist ?? '').trim();
    // The first words are what tells two versions of a song apart.
    final opening = lyrics.lines
        .map((line) => line.text.trim())
        .where((text) => text.isNotEmpty)
        .take(2)
        .join('  ');

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 11, 16, 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: title.isEmpty ? '未命名' : title,
                        children: [
                          if (artist.isNotEmpty)
                            TextSpan(
                              text: '  $artist',
                              style: AppTypography.caption.copyWith(
                                fontSize: 13,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color:
                            selected ? AppColors.accent : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      opening,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption.copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (selected)
                const Icon(Icons.check_rounded,
                    color: AppColors.accent, size: 20)
              else if (!lyrics.synced)
                // Worth knowing before choosing: these will not follow along.
                Text('无时间轴',
                    style: AppTypography.caption
                        .copyWith(color: AppColors.textFaint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _FooterButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        onPressed == null ? AppColors.white24 : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onPressed,
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(width: 6),
              Text(label,
                  style: AppTypography.bodyMedium.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A full page for writing or pasting lyrics. LRC timestamps are honoured;
/// text without them is kept as plain lyrics.
class LrcEditorPage extends StatefulWidget {
  final String initial;

  const LrcEditorPage({super.key, required this.initial});

  /// Completes with the text to save, or null when cancelled.
  static Future<String?> open(BuildContext context, {String initial = ''}) {
    return Navigator.of(context).push(MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => LrcEditorPage(initial: initial),
    ));
  }

  @override
  State<LrcEditorPage> createState() => _LrcEditorPageState();
}

class _LrcEditorPageState extends State<LrcEditorPage> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _dirty => _text.text.trim() != widget.initial.trim();

  Future<void> _cancel() async {
    final navigator = Navigator.of(context);
    if (_dirty &&
        !await confirmAction(context, title: '放弃修改？', confirm: '放弃')) {
      return;
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          leading: IconButton(
            tooltip: '取消',
            onPressed: _cancel,
            icon: const Icon(Icons.close_rounded),
          ),
          actions: [
            TextButton(
              onPressed: () {
                final text = _text.text.trim();
                Navigator.of(context).pop(text.isEmpty ? null : text);
              },
              child: const Text(
                '保存',
                style: TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: TextField(
            controller: _text,
            maxLines: null,
            expands: true,
            autofocus: widget.initial.isEmpty,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              height: 1.6,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(20, 8, 20, 24),
              hintText: '粘贴歌词\n\n[00:12.34] 带时间轴的 LRC 会跟随歌曲滚动',
              hintStyle: TextStyle(
                color: AppColors.textFaint,
                fontSize: 15,
                height: 1.6,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
