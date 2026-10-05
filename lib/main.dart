import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app_services.dart';
import 'app/app_shell.dart';
import 'services/audio_player_handler.dart';
import 'services/track_naming.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // debugPrint is not compiled out of release builds: titles and file paths
  // would go to the system log, readable by anything with log access.
  if (kReleaseMode) debugPrint = (String? message, {int? wrapWidth}) {};

  // Covers are decoded at display size, so many small entries fit in a
  // modest budget. A large cache is what gets a backgrounded app killed
  // first under memory pressure.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 40 << 20
    ..maximumSize = 150;

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));

  final handler = await AudioService.init(
    builder: BiliBeatsAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.bilibeats.channel.audio',
      androidNotificationChannelName: 'BiliBeats',
      // Keep the media service in the foreground while paused. With the
      // default (demote on pause), resuming after an interruption — a
      // notification sound, a voice message, a call — had to start a
      // foreground service from the background, which Android 12+ refuses
      // by killing the app. The handler stops the service itself after a
      // long pause, so the notification does not linger.
      androidStopForegroundOnPause: false,
    ),
  );

  AppServices.init(handler);
  unawaited(TrackNaming.init(handler));
  // Bring back the last queue, song and position (paused), so a process
  // killed in the background resumes exactly where it was.
  unawaited(handler.restoreSession());

  // Android 13+ gates notifications behind a runtime grant on stricter OEM
  // builds. Fire-and-forget.
  if (!kIsWeb && Platform.isAndroid) {
    const channel = MethodChannel('bilibeats/permissions');
    unawaited(channel.invokeMethod<void>('requestNotifications').catchError(
          (Object _) {},
        ));
  }

  runApp(const BiliBeatsApp());
}

class BiliBeatsApp extends StatelessWidget {
  const BiliBeatsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BiliBeats',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const AppShell(),
    );
  }
}
