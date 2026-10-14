import 'dart:async';

import 'package:bilibeats/services/audio_download_service.dart';

/// Runs before every test file in this directory.
///
/// A failed download is tried again for minutes in the app; in tests it
/// fails at once, so a test about failure does not wait (or, on the fake
/// clock of a widget test, never finish). Tests about retrying set
/// [AudioDownloadService.retryDelays] themselves.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AudioDownloadService.retryDelays = const [];
  await testMain();
}
