import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/track.dart';
import '../services/database_service.dart';
import '../services/track_naming.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/cover_picker.dart';
import '../utils/snack.dart';
import 'cached_cover_image.dart';
import 'sheet.dart';

/// Edits a song's name, artist and cover.
///
/// The sheet belongs to the track it was opened for: saving applies to that
/// song even if playback has moved on underneath.
class TrackInfoSheet extends StatefulWidget {
  final Track track;

  const TrackInfoSheet({super.key, required this.track});

  static Future<void> show(BuildContext context, Track track) {
    return showAppSheet<void>(
      context,
      builder: (_) => TrackInfoSheet(track: track),
    );
  }

  @override
  State<TrackInfoSheet> createState() => _TrackInfoSheetState();
}

class _TrackInfoSheetState extends State<TrackInfoSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.track.title);
  late final TextEditingController _artist =
      TextEditingController(text: widget.track.uploader);
  late String _cover = widget.track.coverUrl;

  bool _identifying = false;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final path = await pickCoverImage('cover');
    if (path != null && mounted) setState(() => _cover = path);
  }

  /// Always works from the original video title, so tapping again after an
  /// edit gives the same answer rather than re-parsing the edit.
  Future<void> _identify() async {
    if (_identifying) return;
    Haptics.selection();
    setState(() => _identifying = true);
    final found = await TrackNaming.identify(widget.track);
    if (!mounted) return;
    setState(() => _identifying = false);
    if (found == null) {
      showAppSnackBar(ScaffoldMessenger.of(context), message: '没有识别出这首歌');
      return;
    }
    _title.text = found.title;
    _artist.text = found.artist;
    final cover = found.coverUrl;
    if (cover != null) setState(() => _cover = cover);
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    final artist = _artist.text.trim();
    final track = widget.track;
    if (title.isEmpty ||
        (title == track.title &&
            artist == track.uploader &&
            _cover == track.coverUrl)) {
      Navigator.pop(context);
      return;
    }

    setState(() => _saving = true);
    final updated = track.copyWith(
      title: title,
      uploader: artist.isEmpty ? track.uploader : artist,
      coverUrl: _cover,
    );
    try {
      await DatabaseService.updateTrackMetadata(updated);
      AppServices.instance.handler.updateTrackMetadata(updated);
      if (mounted) Navigator.pop(context);
    } catch (error, stack) {
      debugPrint('Metadata save failed: $error\n$stack');
      if (!mounted) return;
      setState(() => _saving = false);
      showAppSnackBar(ScaffoldMessenger.of(context), message: '保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.track.rawTitle;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                button: true,
                label: '更换封面',
                child: GestureDetector(
                  onTap: _pickCover,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        child: CachedCoverImage(
                          url: _cover,
                          width: 104,
                          height: 104,
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.all(6),
                        padding: const EdgeInsets.all(5),
                        decoration: const BoxDecoration(
                          color: AppColors.black55,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.photo_camera_outlined,
                            color: AppColors.textPrimary, size: 15),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: [
                    _field(_title, '歌名'),
                    const SizedBox(height: 8),
                    _field(_artist, '歌手'),
                  ],
                ),
              ),
            ],
          ),
          if (raw.isNotEmpty) ...[
            const SizedBox(height: 14),
            Material(
              color: AppColors.fieldFill,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.md),
                onTap: _identifying ? null : _identify,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          raw,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption.copyWith(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (_identifying)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.auto_awesome_rounded,
                            color: AppColors.accent, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        '识别',
                        style: AppTypography.bodyMedium
                            .copyWith(color: AppColors.accent),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          PrimaryButton(label: '保存', onPressed: _saving ? null : _save),
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      style: AppTypography.body,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: AppTypography.body.copyWith(color: AppColors.textFaint),
        filled: true,
        fillColor: AppColors.fieldFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}
