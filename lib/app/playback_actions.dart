import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../theme/haptics.dart';
import '../widgets/track_sheet.dart';
import 'app_services.dart';

/// The one row-tap contract, used by every list in the app:
///
///  * a downloaded song plays (within [queue], or the whole library);
///  * a song that is not downloaded opens its sheet, whose primary action
///    is 下载并播放 — nothing downloads silently from a tap.
void openTrack(BuildContext context, Track track, {List<Track>? queue}) {
  final services = AppServices.instance;
  if (services.library.isDownloaded(track.id)) {
    Haptics.light();
    unawaited(services.handler.playTrack(track, queue: queue));
  } else {
    unawaited(TrackSheet.show(context, track, queue: queue));
  }
}

/// Plays a collection from the top, or shuffled.
void playCollection(List<Track> tracks, {bool shuffle = false}) {
  Haptics.medium();
  unawaited(AppServices.instance.handler.playCollection(
    tracks,
    shuffle: shuffle,
  ));
}
