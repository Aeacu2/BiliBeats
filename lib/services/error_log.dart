import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Errors nothing caught, kept on the device for a bug report.
///
/// A release build prints nothing (see main.dart), so without this an
/// uncaught error in a sideloaded build left no trace at all. The log is in
/// the app's private storage and leaves it only when the listener copies it
/// (设置 → 复制错误日志).
class ErrorLog {
  ErrorLog._();

  static const String _file = 'bilibeat_errors.log';

  /// Past this the older half is dropped.
  static const int _maxBytes = 256 << 10;

  /// Whether anything has been logged, this launch or before.
  static final ValueNotifier<bool> hasEntries = ValueNotifier(false);

  static Future<void> _writes = Future.value();
  static String? _path;

  /// Routes uncaught errors here, and says whether a log is already there.
  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      previous?.call(details);
      record(details.exception, details.stack,
          context: details.context?.toDescription());
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack);
      // Logged: not a reason to end the app.
      return true;
    };
    unawaited(_append(null));
  }

  /// Notes [error]; never throws.
  static void record(Object error, StackTrace? stack, {String? context}) {
    debugPrint('Uncaught: $error\n$stack');
    final at = DateTime.now().toIso8601String();
    final frames = (stack?.toString() ?? '').split('\n').take(12).join('\n');
    unawaited(_append('[$at] ${context == null ? '' : '$context: '}$error\n'
        '$frames\n\n'));
  }

  /// The whole log, oldest first; empty when there is none.
  static Future<String> read() async {
    await _writes;
    try {
      final file = File(await _pathOf());
      return await file.exists() ? await file.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> clear() {
    hasEntries.value = false;
    return _writes = _writes.then((_) async {
      try {
        final file = File(await _pathOf());
        if (await file.exists()) await file.delete();
      } catch (_) {}
    });
  }

  static Future<String> _pathOf() async =>
      _path ??= '${(await getApplicationDocumentsDirectory()).path}/$_file';

  /// One write at a time, in order. [entry] null only checks for a log.
  static Future<void> _append(String? entry) {
    return _writes = _writes.then((_) async {
      try {
        final file = File(await _pathOf());
        if (entry != null) {
          await file.writeAsString(entry, mode: FileMode.append, flush: true);
        }
        if (!await file.exists()) return;
        final length = await file.length();
        if (length > 0) hasEntries.value = true;
        if (length > _maxBytes) {
          // From the first whole entry past the middle.
          final text = await file.readAsString();
          final cut = text.indexOf('\n[', text.length ~/ 2);
          await file.writeAsString(cut < 0 ? '' : text.substring(cut + 1),
              flush: true);
        }
      } catch (_) {
        // A log that cannot be written is no reason for another error.
      }
    });
  }
}
