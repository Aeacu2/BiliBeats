# Local validation of the cloud session

Validated on 24 October 2026 after fast-forwarding the clean local checkout
from `f0b4778` to `5582f82` (`origin/claude/charming-brahmagupta-ollfaj`).

## Changes made locally

- Favourites import now requests the folder's reported size. A real folder
  returned 1,717 entries; the previous call used the SDK's 1,000-track limit.
- The Python subtitle evaluator now preserves traditional Chinese, matching
  `SubtitleMatcher.normalize`. Previously it could measure confirmations that
  the app would not make.
- The measurement README identifies the required prediction files and explains
  why the shipping model cannot substitute for the held-out checkpoint.

## Completed checks

- `flutter analyze`: no issues.
- `flutter test --exclude-tags live`: 307 passed, including a final run after
  the import change.
- Full `flutter test`: 336 passed, two live tests failed (details below).
- Screen rendering: three render tests passed. Inspected the settings sheet;
  the account entry is a quiet row near the bottom, with no login button styling.
- Real JDK 21 / Gradle Android release build: passed, including Kotlin, R8 and
  signing. Rebuilt after the import fix. The development APK is
  `build/app/outputs/flutter-apk/app-release.apk`, with symbols in `symbols/dev/`.
  This uses the existing version 0.2.2+7; no release or tag was published.
- Live QR-code generation API: code 0 and a QR URL. This does not test scanning
  or completing login.
- Safari's existing Bilibili session: authenticated navigation, favourites-folder,
  favourites-page, watch-history and player/subtitle responses all returned code 0.
- Three additional local checks against actual saved responses passed: all 20
  favourites parsed with video and part IDs; the 30 history records yielded three
  music tracks; Chinese AI subtitles were selected and all 234 lines parsed. The
  unrelated-song comparison did not confirm a song in that spoken interview.
- A separate full-song performance returned an empty subtitle list despite login.
- Python checks confirmed that the evaluator preserves traditional characters and
  still matches identical simplified-Chinese lyric lines.

Account responses and test inputs remain local and are not committed. No login
cookies were extracted or saved.

## Live-suite failures

1. `zhoushen_test.dart`, “a singer covering a bracketed song is still found”:
   `【从前从前有个人爱你很久】周杰伦-晴天MV` resolved to the bracketed phrase
   rather than `晴天`. A direct current NetEase search returned covers and other
   artists rather than the expected original recording.
2. `recognition_live_test.dart`, “the surveyed videos are named as a listener
   would name them”: three surveyed titles (`浮生未歇`, `来啊`, `漫漫`) returned
   no match. The run also logged closed NetEase connections. A separate Bilibili
   lookup logged HTTP 412.

The existing identification function was not changed by the cloud commits.
These live failures remain unresolved; they are not reported as passing.

## Remaining dependencies

- No Android device was connected. On-phone WebView login, completed QR login,
  favourites download/import and playback/alignment still need device validation.
- The full hold-out threshold measurement did not run. The labelled fixtures are
  available and `mkeval.py` generated 1,146 evaluation rows, but the corresponding
  `rules.json`, `reads.json` and held-out `mmbert.pt` were not found locally. The
  shipped model was trained on `hold`, so using it would invalidate that check.
- After explicit user authorization, macOS still denied reading Safari's protected
  cookie store. Browser-based authenticated smoke checks succeeded, but a session
  available to the benchmark process is still required for the bulk measurement.
  Subtitle thresholds remain at 6 matched lines, 0.5 precision and 0.3 coverage.

## v0.3.0 follow-up

The subsequent product review was implemented: selective favourites import with
part expansion, stable account/folder source IDs, resumable folder reads, optional
local downloads and recommendation seeds, persistent queue controls, account-scoped
history opt-in and caches, bounded history pagination, accidental-view filtering,
current-song refresh after login, and stricter subtitle fallback/timing checks.

- Final offline suite: 328 tests passed.
- Static analysis: no issues.
- Render checks: all four passed, with the new account render fixtures in a
  separate isolate (`test/render_account_screens.dart`). Inspected the selection
  and queue images.
- Live recheck: 30 passed, one failed. The pre-existing `晴天` catalogue recognition
  case above still fails; the surveyed-video test passed on this run. One Bilibili
  request still logged HTTP 412. Live tests are excluded from CI by repository policy.
- Recognition confirmation thresholds were not empirically retuned. The missing
  held-out predictions and benchmark login remain dependencies for that measurement.
- Physical-device login and playback testing is deferred to the user's phone after
  the requested v0.3.0 release; local tests do not claim to replace it.
