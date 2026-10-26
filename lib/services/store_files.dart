import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// JSON a store has already encoded: written as it is, so a large store can
/// encode only what changed.
@immutable
class EncodedJson {
  final String text;
  const EncodedJson(this.text);
}

/// The app's persisted state: whole-file JSON in the documents directory,
/// one file per store (`bilibeat_*.json`), each wrapped in a versioned
/// envelope and written atomically through one queue.
///
/// Every store (the library, preferences, lyrics, trims, the account…)
/// reads and writes through here; none touches its file directly.
class StoreFiles {
  StoreFiles._();

  /// Cached documents directory. The path is fixed for the lifetime of the
  /// app, yet every persist used to re-fetch it across the platform channel.
  static String? _docsPath;

  static Future<String> documents() async {
    final cached = _docsPath;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    return _docsPath = docs.path;
  }

  /// `<documents>/[name]`.
  static Future<String> pathOf(String name) async =>
      '${await documents()}/$name';

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  /// The text of `<documents>/[name]`, or null when there is none.
  static Future<String?> readText(String name) async {
    final file = File(await pathOf(name));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// `<documents>/[name]` made sense of by [parse] (given the file's text;
  /// see [unwrap]), or null when there is no such file. A file [parse]
  /// cannot read is set aside ([setAside]) and null returned: the store
  /// starts empty rather than overwrite it. With [offThread], [parse] runs
  /// in a background isolate (it must then be top-level or static).
  static Future<R?> load<R>(String name, R Function(String text) parse,
      {bool offThread = false}) async {
    final String path;
    try {
      path = await pathOf(name);
    } catch (e) {
      debugPrint('StoreFiles: no documents directory for $name: $e');
      return null;
    }
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      return offThread ? await _parseOffThread(parse, text) : parse(text);
    } catch (e) {
      debugPrint('StoreFiles: $name not loaded: $e');
      await _setAside(path);
      return null;
    }
  }

  /// Parses off the UI isolate; when no isolate can be had (memory
  /// pressure) parses here instead. Only a file that cannot be *read* is
  /// ever set aside, not one that could not be handed to an isolate.
  static Future<R> _parseOffThread<R>(
      R Function(String) parse, String text) async {
    try {
      return await compute(parse, text);
    } on FormatException {
      rethrow;
    } on TypeError {
      rethrow;
    } catch (e) {
      debugPrint('StoreFiles: isolate parse failed, parsing inline: $e');
      return parse(text);
    }
  }

  /// Envelope version for every file written here. Bump when a payload
  /// shape changes incompatibly and teach the matching loader to migrate the
  /// old version. Files written before versioning existed hold bare payloads
  /// (no envelope); every loader accepts both, so the first write after an
  /// upgrade migrates each file in place.
  static const int schemaVersion = 1;

  static Object _envelope(Object payload) => payload is EncodedJson
      ? EncodedJson('{"schema_version":$schemaVersion,"data":${payload.text}}')
      : {'schema_version': schemaVersion, 'data': payload};

  /// Unwraps a decoded file, accepting both the versioned envelope and the
  /// bare legacy shape. Throws for envelopes written by a NEWER schema than
  /// this build understands: guessing at unknown future data and then
  /// re-persisting the guess would destroy it. [load] treats that like a
  /// file it cannot parse.
  static dynamic unwrap(dynamic decoded) {
    if (decoded is Map && decoded.containsKey('schema_version')) {
      final version = decoded['schema_version'];
      if (version is int && version > schemaVersion) {
        throw FormatException('schema_version $version is newer than '
            '$schemaVersion; written by a newer build');
      }
      return decoded['data'];
    }
    return decoded;
  }

  /// Whether a file was set aside in this launch.
  static bool get setAsideThisLaunch => _setAsideAny;
  static bool _setAsideAny = false;

  /// Moves `<documents>/[name]`, which this build cannot read (damaged, or
  /// written by a newer build), out of the way to `<name>.unreadable`. The
  /// store then starts empty, and the next save writes a fresh file
  /// instead of overwriting the only copy of whatever was in the old one.
  static Future<void> setAside(String name) async =>
      _setAside(await pathOf(name));

  static Future<void> _setAside(String path) async {
    _setAsideAny = true;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      var target = '$path.unreadable';
      if (await File(target).exists()) {
        target = '$path.${DateTime.now().millisecondsSinceEpoch}.unreadable';
      }
      await file.rename(target);
      debugPrint('StoreFiles: kept unreadable file as $target');
    } catch (e) {
      debugPrint('StoreFiles: could not set aside $path: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Writing
  // ---------------------------------------------------------------------------

  /// Atomically writes [payload] (wrapped in the versioned envelope; it may
  /// be [EncodedJson] already) to `<documents>/[name]`. Failures propagate.
  static Future<void> write(String name, Object payload) async =>
      _writeAtomically(await pathOf(name), _envelope(payload));

  /// [write], with a failure reported to the listener ([saveFailures])
  /// instead of thrown.
  static Future<void> save(String name, Object payload) async {
    try {
      await write(name, payload);
    } catch (e) {
      debugPrint('StoreFiles: saving $name failed: $e');
      _reportSaveFailure();
    }
  }

  // Write serialization: whole-file rewrites must not interleave. Each
  // persist is small but concurrent calls (e.g. addRecentlyPlayed +
  // toggleFavorite) shared the same `$path.tmp` and truncated each other. A
  // simple async mutex plus per-call unique tmp file fixes lost-update +
  // Windows rename semantics.
  static Future<void> _writeLock = Future.value();

  /// Whole-file rewrites are truncated-then-written by default; a crash in the
  /// middle corrupts the file. Writing to a temp file and renaming keeps the
  /// previous snapshot intact instead.
  ///
  /// Every caller hands over a snapshot of the whole file, so a write still
  /// waiting for the lock when a newer one for the same file is queued is
  /// skipped: the newer one carries its changes too, and its outcome is
  /// this one's. A burst (naming a library, dragging a playlist) then
  /// rewrites each file once, not once per change.
  static Future<void> _writeAtomically(String path, Object data) {
    final ticket = _writeTickets[path] = (_writeTickets[path] ?? 0) + 1;
    return _newestWrites[path] = _writeQueued(path, data, ticket);
  }

  static final Map<String, int> _writeTickets = {};
  static final Map<String, Future<void>> _newestWrites = {};

  static Future<void> _writeQueued(String path, Object data, int ticket) async {
    // Serialize all whole-file writes through a single async mutex so two
    // concurrent persists never share the same tmp file.
    final previous = _writeLock;
    final completer = Completer<void>();
    _writeLock = completer.future;
    await previous;
    if (_writeTickets[path] != ticket) {
      completer.complete();
      await _newestWrites[path];
      return;
    }
    File? tmp;
    try {
      final payload =
          utf8.encode(data is EncodedJson ? data.text : jsonEncode(data));
      for (var attempt = 0; attempt < 2; attempt++) {
        final unique = DateTime.now().microsecondsSinceEpoch;
        tmp = File('$path.$unique.tmp');
        await tmp.writeAsBytes(payload, flush: true);
        final target = File(path);
        // rename() replaces the target atomically everywhere but Windows,
        // where it fails if the target exists. Only there is the old file
        // removed first — elsewhere that would open a window in which a
        // crash leaves no file at all.
        if (Platform.isWindows && await target.exists()) {
          try {
            await target.delete();
          } catch (e) {
            debugPrint('StoreFiles write: delete failed: $e');
          }
        }
        await tmp.rename(path);
        tmp = null;
        // Verify what landed: a torn write must not silently become the
        // library. One retry, then propagate the failure to the caller.
        // A torn write is a short one, so the length is the check: reading
        // the whole file back doubled the work of every save.
        try {
          if (await File(path).length() == payload.length) return;
          debugPrint('StoreFiles write: verify mismatch: $path');
        } catch (e) {
          debugPrint('StoreFiles write: verify failed: $e');
          if (attempt == 0) continue;
          rethrow;
        }
        if (attempt == 0) continue;
        throw StateError('persist verification failed: $path');
      }
    } catch (e) {
      debugPrint('StoreFiles write error: $e');
      rethrow;
    } finally {
      // Best-effort cleanup of stray tmp (e.g. rename threw).
      if (tmp != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
      completer.complete();
    }
  }

  static final StreamController<void> _saveFailureController =
      StreamController<void>.broadcast();
  static DateTime? _lastSaveFailure;

  /// Fires when a file could not be written (typically a full disk): what
  /// is on screen is then not what the next launch will load, and the
  /// listener has to be told. At most once every ten seconds.
  static Stream<void> get saveFailures => _saveFailureController.stream;

  static void _reportSaveFailure() {
    final now = DateTime.now();
    final last = _lastSaveFailure;
    if (last != null &&
        now.difference(last).abs() < const Duration(seconds: 10)) {
      return;
    }
    _lastSaveFailure = now;
    if (!_saveFailureController.isClosed) _saveFailureController.add(null);
  }

  // ---------------------------------------------------------------------------
  // Housekeeping
  // ---------------------------------------------------------------------------

  /// Clears temp files of writes the process did not survive, and says
  /// whether a store was ever set aside and is still there.
  static Future<bool> tidy() async {
    var unreadable = false;
    try {
      await for (final entity in Directory(await documents()).list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('bilibeat_')) continue;
        if (name.endsWith('.unreadable')) unreadable = true;
        if (name.endsWith('.tmp')) await deleteQuietly(entity);
      }
    } catch (e) {
      debugPrint('StoreFiles tidy skipped: $e');
    }
    return unreadable;
  }

  static Future<void> deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }
}
