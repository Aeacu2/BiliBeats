import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android battery-optimization exemption.
///
/// Stock Android leaves a playing media app alone, but several OEM builds
/// (MIUI, EMUI, ColorOS, OriginOS …) still kill it in the background unless
/// the user exempts it from battery optimization. This asks for exactly
/// that, through the system's own dialog.
class BackgroundProtection {
  BackgroundProtection._();

  static const MethodChannel _channel = MethodChannel('bilibeat/permissions');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// True when exempt (or when the question does not apply).
  static Future<bool> isEnabled() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog. Returns true if already exempt.
  static Future<bool> request() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
