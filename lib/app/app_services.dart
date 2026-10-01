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

  /// Called once at launch. Calling it again replaces the services with
  /// ones bound to [handler] (tests build a fresh player per case).
  static void init(BiliBeatAudioHandler handler) {
    final previous = _instance;
    if (previous != null) {
      if (identical(previous.handler, handler)) return;
      previous.lyrics.dispose();
    }
    _instance = AppServices._(handler);
  }

  final BiliBeatAudioHandler handler;
  final LyricsController lyrics;
  final OnlineSearchController onlineSearch = OnlineSearchController();
  final RecommendationsController recommendations = RecommendationsController();

  LibraryController get library => LibraryController.instance;
}
