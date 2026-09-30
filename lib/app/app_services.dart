import '../services/audio_player_handler.dart';
import '../state/library_controller.dart';
import '../state/lyrics_controller.dart';
import '../state/online_search_controller.dart';
import '../state/recommendations_controller.dart';

/// The app's long-lived objects, created once in `main`.
///
/// Widgets read these directly instead of receiving callbacks threaded
/// through every constructor (the old shell passed four "play" callbacks
/// down each screen, each with slightly different semantics).
class AppServices {
  AppServices._(this.handler) : lyrics = LyricsController(handler);

  static AppServices? _instance;

  static AppServices get instance {
    final services = _instance;
    assert(services != null, 'AppServices.init was not called');
    return services!;
  }

  static void init(BiliBeatAudioHandler handler) {
    _instance ??= AppServices._(handler);
  }

  final BiliBeatAudioHandler handler;
  final LyricsController lyrics;
  final OnlineSearchController onlineSearch = OnlineSearchController();
  final RecommendationsController recommendations =
      RecommendationsController();

  LibraryController get library => LibraryController.instance;
}
