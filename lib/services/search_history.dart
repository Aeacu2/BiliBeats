import 'dart:convert';

import 'store_files.dart';

/// The last few searches, newest first (`bilibeat_search_history.json`).
class SearchHistory {
  SearchHistory._();

  static const String _file = 'bilibeat_search_history.json';
  static const int _limit = 12;

  static Future<List<String>>? _loading;

  static Future<List<String>> _entries() => _loading ??= _load();

  static Future<List<String>> _load() async =>
      await StoreFiles.load(_file, _parse) ?? <String>[];

  static List<String> _parse(String text) {
    final list = StoreFiles.unwrap(jsonDecode(text)) as List<dynamic>? ?? [];
    return [for (final e in list) e.toString()];
  }

  static Future<List<String>> get() async => List.of(await _entries());

  /// Puts [query] first; returns the history as it now is.
  static Future<List<String>> add(String query) async {
    final entries = await _entries();
    final q = query.trim();
    if (q.isEmpty) return List.of(entries);
    entries
      ..remove(q)
      ..insert(0, q);
    if (entries.length > _limit) entries.removeLast();
    await StoreFiles.save(_file, entries);
    return List.of(entries);
  }

  static Future<void> clear() async {
    (await _entries()).clear();
    await StoreFiles.save(_file, const <String>[]);
  }
}
