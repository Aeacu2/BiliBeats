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

  static const MethodChannel _channel = MethodChannel('bilibeats/permissions');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static bool _askedNotifications = false;

  /// Asks for the notification permission where Android has one, once per
  /// run. When the media service started the engine there is no activity
  /// to ask through yet; the call is then repeated when one appears.
  static Future<void> requestNotifications() async {
    if (!supported || _askedNotifications) return;
    try {
      await _channel.invokeMethod<void>('requestNotifications');
      _askedNotifications = true;
    } on MissingPluginException {
      // No activity yet.
    } catch (_) {
      _askedNotifications = true;
    }
  }

  /// True when exempt (or when the question does not apply).
  static Future<bool> isEnabled() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } on MissingPluginException {
      // No activity yet (the media service started the engine): unknown,
      // which is not a reason to ask the listener for anything.
      return true;
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
