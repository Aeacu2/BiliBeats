import 'dart:convert';

import 'store_files.dart';

/// Small settings and remembered choices (sort order, dismissed hints,
/// toggles), in `bilibeat_prefs.json`.
class Prefs {
  Prefs._();

  static const String _file = 'bilibeat_prefs.json';

  static Future<Map<String, dynamic>>? _loading;

  static Future<Map<String, dynamic>> _prefs() => _loading ??= _load();

  static Future<Map<String, dynamic>> _load() async =>
      await StoreFiles.load(_file, _parse) ?? <String, dynamic>{};

  static Map<String, dynamic> _parse(String text) {
    final payload = StoreFiles.unwrap(jsonDecode(text));
    return payload is Map ? Map<String, dynamic>.from(payload) : {};
  }

  static Future<Object?> get(String key) async => (await _prefs())[key];

  /// Sets [key], or with null removes it.
  static Future<void> set(String key, Object? value) async {
    final prefs = await _prefs();
    if (value == null) {
      prefs.remove(key);
    } else {
      prefs[key] = value;
    }
    await StoreFiles.save(_file, prefs);
  }
}
