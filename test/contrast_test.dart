import 'dart:math' as math;

import 'package:bilibeats/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the type scale's WCAG contrast claims on the app's flat surfaces.
///
/// Scope is deliberately flat backgrounds only: text composited over the
/// artwork-derived aura needs on-device verification with real covers, and
/// no unit test can establish that. What this guards is regressions to the
/// palette itself (e.g. someone dimming `textFaint` below AA).
double _luminance(Color c) {
  double lin(int channel) {
    final v = channel / 255.0;
    return v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin((c.r * 255.0).round()) +
      0.7152 * lin((c.g * 255.0).round()) +
      0.0722 * lin((c.b * 255.0).round());
}

double _ratio(Color fg, Color bg) {
  // Composite translucent foregrounds over the background first.
  // All channels normalized to 0..1 throughout.
  int ch(double f, double b, double a) =>
      ((f * a + b * (1 - a)) * 255.0).round().clamp(0, 255);
  final a = fg.a;
  final r = ch(fg.r, bg.r, a);
  final g = ch(fg.g, bg.g, a);
  final b = ch(fg.b, bg.b, a);
  final l1 = _luminance(Color.from(
    alpha: 1,
    red: r / 255,
    green: g / 255,
    blue: b / 255,
  ));
  final l2 = _luminance(bg);
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // Flat surfaces the type scale is specified against.
  const surfaces = {
    'background': AppColors.background,
    'backgroundElevated': AppColors.backgroundElevated,
    'surfaceDeep': AppColors.surfaceDeep,
  };

  test('body text meets AA (4.5:1) on all flat surfaces', () {
    const texts = {
      'textPrimary': AppColors.textPrimary,
      'textSecondary': AppColors.textSecondary,
      'textMuted': AppColors.textMuted,
      'textFaint': AppColors.textFaint,
    };
    for (final surface in surfaces.entries) {
      for (final text in texts.entries) {
        expect(
          _ratio(text.value, surface.value),
          greaterThanOrEqualTo(4.5),
          reason: '${text.key} on ${surface.key}',
        );
      }
    }
  });

  test('accent meets 3:1 UI-component contrast on flat surfaces', () {
    for (final surface in surfaces.entries) {
      expect(
        _ratio(AppColors.accent, surface.value),
        greaterThanOrEqualTo(3.0),
        reason: 'accent on ${surface.key}',
      );
    }
  });
}
