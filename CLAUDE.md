# BiliBeats

A Bilibili audio player in Flutter (Android first; iOS, macOS build too). Songs are
downloaded to disk and always played from local files. One user, sideloaded builds.

- Dart package `bilibeats`; Android/Apple id `com.bilibeats.app`; display name BiliBeats.
- On-disk file names still start with `bilibeat_` (`bilibeat_downloaded.json`,
  `bilibeat_audio/`…). They are data, not branding — do not rename them.
- UI copy is Simplified Chinese. Code, comments and commit messages are English.

## Commands

Flutter is at `~/flutter/bin` and is not on PATH in non-interactive shells.

```bash
export PATH="$HOME/flutter/bin:$PATH"
flutter analyze                 # must stay at "No issues found"
flutter test                    # ~40 s; a few tests query NetEase for real
flutter test test/render_screens.dart --update-goldens   # PNGs in build/screens/
tool/build_release.sh [ios|all] # obfuscated release; needs JDK 21+
tool/release.sh patch "note"    # bump version + CHANGELOG + commit + tag (no build)
```

Look at the rendered PNGs before calling a layout change done. In those renders the
library switch labels show as boxes (an artefact of the test font, not a bug).

## Layout

```
lib/
  main.dart                 audio_service init, AppServices, restore session
  app/                      AppShell (search bar + home/search + docked player),
                            AppServices (singletons), playback_actions (row-tap contract)
  screens/                  home_page, search_view, now_playing_page, playlist_page,
                            artist_page, settings_sheet
  widgets/                  song_tile (the one song row), mini_player, sheets, lyrics_view…
  state/                    LibraryController, LyricsController, search/recommendation controllers
  services/                 audio_player_handler (playback), audio_download_service,
                            download_manager, database_service (JSON files), bilibili_sdk,
                            lyrics_engine (title parsing, song matching, lyric providers),
                            lyrics_store, track_naming, track_credit
  models/  theme/  utils/
test/                       *_test.dart; fake_audio_player + audio_test_harness for playback
docs/archive/               old review notes and a superseded feature list — history only
```

## How it fits together

- **Playback has one source of truth.** The queue lives in the native player; the UI
  reads `handler.nowPlaying / queueNotifier / playingNotifier`. Nothing in Dart tracks
  "the current song" separately. Only downloaded tracks enter the queue; a track that
  needs downloading is fetched first while the current one keeps playing
  (`handler.preparing`).
- **Persistence is whole-file JSON** in the documents directory, written through
  `DatabaseService._writeJsonAtomically` (single write lock, temp file + rename).
  Screens do not read `DatabaseService` directly; they listen to `LibraryController`.
- **`Track` identity is `bvid_p<page>`**; equality is by id, so use `TrackNotifier`
  (not `ValueNotifier<Track>`) where an edited copy must notify.
- **Song vs. video.** `rawTitle` is the video title and never changes. `title`/`uploader`
  start as the video's and become the song's once `Track.isNamed` (the `named` flag, set
  by 编辑信息 or by automatic matching). Always show the artist through
  `TrackCredit.artistOf` — never `track.uploader` directly. Parts of a multi-part video
  are titled `"<video> - P3: <part>"`; `Track.partTitle` extracts the part.
- **Matching (设置 → 自动匹配歌曲信息).** `TrackNaming` asks `LyricsEngine.identify`,
  which searches NetEase for structural readings of the title and accepts a song only
  with evidence: artist in the title/uploader, matching length, or a title that
  isolates the name. Compilations and anything over 15 minutes are never one song.
  The title corpus for the offline parser is `test/fixtures/real_bilibili_titles.json`.
- **Lyrics.** `LyricsController` follows the playing track. Lyrics the listener chose,
  pasted or calibrated are pinned in `LyricsStore` and never overwritten automatically.

## UI conventions

- Dark only. Colours, radii and type come from `theme/app_theme.dart`; motion from
  `theme/motion.dart`. No new hard-coded colours.
- As little text and as few visible controls as possible; secondary features live in a
  bottom sheet (`showAppSheet`, `SheetAction`, `PrimaryButton` in `widgets/sheet.dart`).
- Every list draws songs with `SongTile` and handles taps with `openTrack`.
- Touch targets are at least 48 pt; keep tooltips on icon-only buttons (tests and
  screen readers find controls by them).
- Player page spacing is computed in `_Spacing` (now_playing_page.dart): spare height is
  shared between the artwork and the control rows rather than left at one end.

## Gotchas

- Widget tests run on a fake clock: real IO and isolates (`compute`) only complete inside
  `tester.runAsync`. Load the library in `setUpAll` or `runAsync`, not in the test body.
- External HTTP is blocked in most tests (`useHermeticHttp`); `zhoushen_test.dart` uses
  the real network on purpose.
- The Android keystore is `android/bilibeat-release.jks` (old name, kept so signing does
  not change). It and `android/key.properties` are gitignored; never commit them.
- iOS has no CocoaPods — plugins integrate through Swift Package Manager.
- Release notes read like an Apple update note: formal, concise, no hype.
