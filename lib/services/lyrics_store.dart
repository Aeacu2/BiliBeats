import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/lyrics.dart';
import 'database_service.dart';

Map<String, Lyrics> _parseLyricsFile(String json) {
  final payload = DatabaseService.unwrapStorePayload(jsonDecode(json));
  final result = <String, Lyrics>{};
  if (payload is! Map) return result;
  payload.forEach((key, value) {
    try {
      result['$key'] = Lyrics.fromMap(Map<String, dynamic>.from(value as Map));
    } catch (e) {
      debugPrint('Lyrics entry $key skipped: $e');
    }
  });
  return result;
}

/// Every song's lyrics, on disk and in memory.
///
/// Two kinds of entry live here:
///  * **automatic** matches — a cache, bounded and replaceable;
///  * **pinned** lyrics — what the listener picked, pasted or calibrated.
///    These are theirs: no automatic lookup overwrites them and they are
///    never evicted, in this session or after a restart.
///
/// A pin takes effect synchronously (before the file is even loaded), so a
/// lookup that was already in flight can never land on top of it; each pin
/// bumps the track's [revisionOf], which automatic writes must still match.
class LyricsStore {
  LyricsStore._();

  static const String _file = 'bilibeat_lyrics.json';

  /// Automatic entries kept; pinned ones do not count.
  static const int _maxAutomatic = 300;

  /// Insertion order is recency: the first automatic entry is the oldest.
  static final Map<String, Lyrics> _entries = {};

  /// Ids cleared before the file finished loading, so loading does not
  /// bring them back.
  static final Set<String> _clearedBeforeLoad = {};

  static final Map<String, int> _revisions = {};
  static int _nextRevision = 0;
  static Future<void>? _loading;
  static bool _loaded = false;

  static int revisionOf(String trackId) => _revisions[trackId] ?? 0;

  /// What is known right now, without waiting for the file.
  static Lyrics? peek(String trackId) => _entries[trackId];

  static Future<void> _ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final text = await DatabaseService.readStoreFile(_file);
      if (text != null) {
        final parsed = await compute(_parseLyricsFile, text);
        // Anything registered while loading is newer than the file.
        final session = Map.of(_entries);
        _entries
          ..clear()
          ..addAll(parsed)
          ..removeWhere((id, _) => _clearedBeforeLoad.contains(id))
          ..addAll(session);
      }
    } catch (e) {
      debugPrint('LyricsStore load skipped: $e');
      // Pinned lyrics are the listener's work: an unreadable file is kept,
      // not overwritten by the next save.
      await DatabaseService.setAsideStoreFile(_file);
    }
    _loaded = true;
    _clearedBeforeLoad.clear();
  }

  static Future<Lyrics?> get(String trackId) async {
    await _ensureLoaded();
    final entry = _entries.remove(trackId);
    if (entry != null) _entries[trackId] = entry; // touch
    return entry;
  }

  /// Saves the listener's choice. Readable through [peek] immediately; the
  /// returned future completes when it is on disk and fails if it is not
  /// (the choice still stands for this session).
  static Future<void> pin(String trackId, Lyrics lyrics) {
    final revision = _revisions[trackId] = ++_nextRevision;
    _entries
      ..remove(trackId)
      ..[trackId] = lyrics.copyWith(pinned: true);
    return _persistIfCurrent(trackId, revision);
  }

  /// Forgets a track's lyrics (pinned or not) so the next lookup starts over.
  static Future<void> clear(String trackId) {
    final revision = _revisions[trackId] = ++_nextRevision;
    _entries.remove(trackId);
    if (!_loaded) _clearedBeforeLoad.add(trackId);
    return _persistIfCurrent(trackId, revision);
  }

  static Future<void> _persistIfCurrent(String trackId, int revision) async {
    await _ensureLoaded();
    // A newer deliberate change will write (and already holds the truth).
    if (revisionOf(trackId) != revision) return;
    await _persist();
  }

  /// Stores an automatic match unless the listener has decided otherwise
  /// since [expectedRevision] was read. Returns whether it now stands.
  /// An empty result is not stored: "not found" must stay retryable.
  static Future<bool> putAutomatic(
    String trackId,
    Lyrics lyrics, {
    required int expectedRevision,
  }) async {
    await _ensureLoaded();
    bool stands() =>
        revisionOf(trackId) == expectedRevision &&
        _entries[trackId]?.pinned != true;
    if (!stands()) return false;

    _entries.remove(trackId);
    if (lyrics.isNotEmpty) {
      _entries[trackId] = lyrics.copyWith(pinned: false);
      _evict();
    }
    try {
      await _persist();
    } catch (e) {
      debugPrint('LyricsStore automatic persist failed: $e');
    }
    return stands();
  }

  static void _evict() {
    var automatic = _entries.values.where((l) => !l.pinned).length;
    if (automatic <= _maxAutomatic) return;
    for (final id in _entries.keys.toList()) {
      if (automatic <= _maxAutomatic) break;
      if (_entries[id]!.pinned) continue;
      _entries.remove(id);
      automatic--;
    }
  }

  static Future<void> _persist() => DatabaseService.writeStoreFile(
        _file,
        _entries.map((id, lyrics) => MapEntry(id, lyrics.toMap())),
      );
}
