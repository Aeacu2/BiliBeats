import 'package:flutter/foundation.dart';

/// One playable Bilibili audio part.
///
/// Deliberately narrow: fields that were written but never read (uploaderFace,
/// quality, localFilePath, addedAt, and an `isDownloaded` flag that duplicated
/// — and could contradict — what is actually on disk) have been removed.
/// Download state has exactly one source of truth: [AudioDownloadService].
class Track {
  /// `bvid_p<page>`, uniquely naming one part of one video. This is the
  /// identity used for equality, de-duplication and on-disk file naming.
  ///
  /// Deliberately *not* keyed on cid: search results do not carry one, so a
  /// cid-based id gave the same song two identities — `bvid_0` from search and
  /// `bvid_<cid>` from a BV number — with separate library entries and
  /// separate downloads. The page number is known on both paths.
  final String id;
  final String bvid;
  final int cid;
  final String title;

  /// The B站 raw video title, immutable after fetch. Metadata edits overwrite
  /// [title] (the display name) but must never touch this field — 智能识别
  /// parses THIS, or a polluted display title would be re-parsed forever.
  final String rawTitle;
  final String uploader;
  final String coverUrl;
  final int duration; // in seconds
  final String? audioUrl;

  /// Integrated loudness in LUFS as measured by Bilibili (EBU R128), or null
  /// when unknown. Playback evens tracks out against this.
  final double? loudness;

  const Track({
    required this.id,
    required this.bvid,
    required this.cid,
    required this.title,
    required this.rawTitle,
    required this.uploader,
    required this.coverUrl,
    required this.duration,
    this.audioUrl,
    this.loudness,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'bvid': bvid,
      'cid': cid,
      'title': title,
      'rawTitle': rawTitle,
      'uploader': uploader,
      'coverUrl': coverUrl,
      'duration': duration,
      'audioUrl': audioUrl,
      if (loudness != null) 'loudness': loudness,
    };
  }

  /// Tolerates both older files carrying extra keys and newer ones missing
  /// them, so a version change never orphans a library.
  factory Track.fromMap(Map<String, dynamic> map) {
    final rawId = map['id'];
    final id = rawId is String ? rawId : (rawId?.toString() ?? '');
    if (id.isEmpty) {
      throw FormatException('Track id missing or empty: $map');
    }
    final rawBvid = map['bvid'];
    final bvid = rawBvid is String ? rawBvid : (rawBvid?.toString() ?? '');
    final rawCid = map['cid'];
    int cid;
    if (rawCid is int) {
      cid = rawCid;
    } else if (rawCid is num) {
      cid = rawCid.toInt();
    } else if (rawCid is String) {
      cid = int.tryParse(rawCid) ?? 0;
    } else {
      cid = 0;
    }
    final rawTitle = map['title'];
    final title =
        rawTitle is String ? rawTitle : (rawTitle?.toString() ?? '未知曲目');
    final rawRawTitle = map['rawTitle'];
    // Falls back to the persisted title only — never the "未知曲目"
    // placeholder, which 智能识别 would otherwise parse as if it were real.
    final rawTitleStr = rawRawTitle is String
        ? rawRawTitle
        : (rawRawTitle?.toString() ?? (rawTitle is String ? rawTitle : ''));
    final rawUploader = map['uploader'];
    final uploader = rawUploader is String
        ? rawUploader
        : (rawUploader?.toString() ?? '未知UP主');
    final rawCover = map['coverUrl'];
    final coverUrl =
        rawCover is String ? rawCover : (rawCover?.toString() ?? '');
    final rawDuration = map['duration'];
    int duration;
    if (rawDuration is int) {
      duration = rawDuration;
    } else if (rawDuration is num) {
      duration = rawDuration.toInt();
    } else if (rawDuration is String) {
      duration = int.tryParse(rawDuration) ?? 0;
    } else {
      duration = 0;
    }
    final rawAudioUrl = map['audioUrl'];
    final audioUrl =
        rawAudioUrl is String ? rawAudioUrl : rawAudioUrl?.toString();
    final rawLoudness = map['loudness'];
    return Track(
      id: id,
      bvid: bvid,
      cid: cid,
      title: title,
      rawTitle: rawTitleStr,
      uploader: uploader,
      coverUrl: coverUrl,
      duration: duration,
      audioUrl: audioUrl,
      loudness: rawLoudness is num ? rawLoudness.toDouble() : null,
    );
  }

  Track copyWith({
    String? title,
    String? uploader,
    String? coverUrl,
    int? duration,
    String? audioUrl,
    double? loudness,
  }) {
    return Track(
      id: id,
      bvid: bvid,
      cid: cid,
      title: title ?? this.title,
      rawTitle: rawTitle,
      uploader: uploader ?? this.uploader,
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration ?? this.duration,
      audioUrl: audioUrl ?? this.audioUrl,
      loudness: loudness ?? this.loudness,
    );
  }

  /// Identity is the track id. Two `Track` objects for the same part — one
  /// from search, one rehydrated from disk — must compare equal so list
  /// lookups behave.
  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Track($id, $title)';
}

/// A holder for "the track the UI is showing" that notifies on *every*
/// assignment of a different object.
///
/// A plain `ValueNotifier<Track?>` cannot be used here. [Track] compares by id
/// (deliberately — see above), so assigning an edited copy of the same track is
/// an assignment of an *equal* value, and `ValueNotifier` silently swallows it.
/// That is exactly what happens after a metadata edit: the docked player kept
/// rendering the pre-edit title, artist and cover until the track changed.
class TrackNotifier extends ChangeNotifier implements ValueListenable<Track?> {
  TrackNotifier([this._value]);

  Track? _value;

  @override
  Track? get value => _value;

  set value(Track? newValue) {
    if (identical(_value, newValue)) return;
    _value = newValue;
    notifyListeners();
  }
}
