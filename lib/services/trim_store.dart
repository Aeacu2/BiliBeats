import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// Where a song really starts and ends inside its video: the talk before
/// it and the 求三连 after it left out.
@immutable
class Trim {
  final Duration start;

  /// Null: to the end of the file.
  final Duration? end;

  const Trim({this.start = Duration.zero, this.end});

  bool get isEmpty => start <= Duration.zero && end == null;

  Map<String, dynamic> toMap() => {
        's': start.inMilliseconds,
        if (end != null) 'e': end!.inMilliseconds,
      };

  static Trim? fromMap(Object? map) {
    if (map is! Map) return null;
    final s = map['s'];
    final e = map['e'];
    if (s is! int || (e != null && e is! int)) return null;
    final trim = Trim(
      start: Duration(milliseconds: s),
      end: e == null ? null : Duration(milliseconds: e as int),
    );
    return trim.isEmpty ? null : trim;
  }

  @override
  bool operator ==(Object other) =>
      other is Trim && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Every song's [Trim], by track id, in `bilibeat_trims.json`.
///
/// Read synchronously by the player ([of]); load it once at startup.
class TrimStore {
  TrimStore._();

  static const String _file = 'bilibeat_trims.json';

  static final Map<String, Trim> _trims = {};
  static Future<void>? _loading;

  /// The file has been read (or found absent); until then a save could
  /// drop the trims in it.
  static bool _loaded = false;

  /// Bumped on every change, for anything showing a trim.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    final String? text;
    try {
      text = await DatabaseService.readStoreFile(_file);
    } catch (e) {
      // No documents directory (yet): nothing to read, nothing to set aside.
      debugPrint('TrimStore load skipped: $e');
      _loading = null;
      return;
    }
    _loaded = true;
    if (text == null) return;
    try {
      final payload = DatabaseService.unwrapStorePayload(jsonDecode(text));
      if (payload is! Map) return;
      final loaded = {
        for (final e in payload.entries)
          if (Trim.fromMap(e.value) case final trim?) '${e.key}': trim,
      };
      // Anything set while loading is newer than the file.
      _trims.addAll({...loaded, ..._trims});
      changes.value++;
    } catch (e) {
      debugPrint('TrimStore load skipped: $e');
      await DatabaseService.setAsideStoreFile(_file);
    }
  }

  static Trim? of(String trackId) => _trims[trackId];

  /// Sets (or, with null or an empty trim, clears) [trackId]'s trim.
  static Future<void> set(String trackId, Trim? trim) async {
    if (trim == null || trim.isEmpty) {
      if (_trims.remove(trackId) == null) return;
    } else {
      if (_trims[trackId] == trim) return;
      _trims[trackId] = trim;
    }
    changes.value++;
    await ensureLoaded();
    if (!_loaded) throw StateError('trims not loaded');
    await DatabaseService.writeStoreFile(
        _file, {for (final e in _trims.entries) e.key: e.value.toMap()});
  }

  @visibleForTesting
  static void reset() {
    _trims.clear();
    _loading = null;
    _loaded = false;
  }
}
