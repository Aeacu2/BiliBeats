# BiliBeat v4 Plan — gpt-astra Review Archive

This document records the full v4 UI/UX and correctness review produced by
**gpt-astra** (external SOTA LLM chat) for BiliBeat v3.13.0, based on a
PDF dump of the project's `lib/` source.

- Messages M1–M7 below are **direct, word-for-word quotes** of what Astra
  wrote. Nothing inside the quote blocks has been edited, reordered, or
  summarized. Code snippets are reproduced exactly as given, including any
  mistakes, truncations, or uncompilable fragments.
- One-line *Context* notes (not quotes) record what was asked before each
  reply. Everything else in this file outside the quote blocks is editor's
  framing, not Astra's words.
- Astra's own caveats apply throughout: it reviewed supplied source text,
  not a running build or screenshots, and it did not compile most patches
  against the project.

## Contents

- M1 — First UI/UX visual patch (quiet, artwork-led minimalism)
- M2 — Full v4 direction (assessment, release blockers A–F, product
  direction, patches 1–6, extra UX issues, features, shipping order)
- M3 — New-UI attempt 1 (fragment; errored mid-message, superseded by M4)
- M4 — New-UI complete rewrite (editorial navigation, shell, mini-player,
  cards, search, library, Now Playing)
- M5 — Product decisions for the agent (deletion, playback contract,
  favorites, scope) + how to send the technical prompts
- M6 — Prompt 1 implementation: playback ownership and serialization patch
- M7 — Prompt 2 implementation: lyric ownership patch
- M8 — Prompt 3: queue snapshot patch (read-only queue)

---

# M1 — First UI/UX visual patch

*Context: Astra was given the two screens (home + search) and asked for
UI/UX optimization suggestions.*

> I’d take this toward **quiet, artwork-led minimalism**: fewer gradients, softer surfaces, stronger typography, and more deliberate interactions—not more decoration.
>
> Your structure is already sensible. The biggest opportunities are:
>
> - **Reduce competing accents.** Gradient icons, glowing play buttons, glass cards, and moving titles all compete for attention.
> - **Make browsing calmer.** Static titles, restrained controls, and consistent row spacing will feel more premium.
> - **Make actions predictable.** Opening a collection and playing it should remain separate, but unavailable actions should look disabled.
> - **Fix a few state issues.** Your download section is currently ordered incorrectly, and failed searches can appear as “no results.”
>
> Below is a focused visual patch that reuses your existing theme, models, and callbacks. It doesn’t require new packages.
>
> ## 1. Introduce two restrained shared components
>
> Create `widgets/quiet_surface.dart`:
>
> ```dart
> import 'package:flutter/material.dart';
> import '../theme/app_theme.dart';
>
>
> /// Use sparingly: quick-access cards, not every list item.
> class QuietSurface extends StatelessWidget {
>   final Widget child;
>   final EdgeInsetsGeometry padding;
>   final VoidCallback? onTap;
>   final VoidCallback? onLongPress;
>
>
>   const QuietSurface({
>     super.key,
>     required this.child,
>     this.padding = const EdgeInsets.all(16),
>     this.onTap,
>     this.onLongPress,
>   });
>
>
>   @override
>   Widget build(BuildContext context) {
>     final radius = BorderRadius.circular(20);
>
>
>     return Material(
>       color: AppColors.backgroundElevated,
>       shape: RoundedRectangleBorder(
>         borderRadius: radius,
>         side: const BorderSide(
>           color: AppColors.hairlineStrong,
>           width: 0.5,
>         ),
>       ),
>       clipBehavior: Clip.antiAlias,
>       child: InkWell(
>         onTap: onTap,
>         onLongPress: onLongPress,
>         borderRadius: radius,
>         child: Padding(
>           padding: padding,
>           child: child,
>         ),
>       ),
>     );
>   }
> }
>
>
> /// An unboxed list row with touch feedback and room for larger text.
> class QuietRow extends StatelessWidget {
>   final Widget child;
>   final VoidCallback? onTap;
>   final VoidCallback? onLongPress;
>
>
>   const QuietRow({
>     super.key,
>     required this.child,
>     this.onTap,
>     this.onLongPress,
>   });
>
>
>   @override
>   Widget build(BuildContext context) {
>     return Material(
>       color: Colors.transparent,
>       borderRadius: BorderRadius.circular(14),
>       clipBehavior: Clip.antiAlias,
>       child: InkWell(
>         onTap: onTap,
>         onLongPress: onLongPress,
>         child: ConstrainedBox(
>           constraints: const BoxConstraints(minHeight: 76),
>           child: Padding(
>             padding: const EdgeInsets.symmetric(
>               horizontal: 8,
>               vertical: 10,
>             ),
>             child: child,
>           ),
>         ),
>       ),
>     );
>   }
> }
> ```
>
> The distinction matters: **collections get a surface; songs get whitespace.** That prevents the screen from becoming a stack of boxes.
>
> ---
>
> ## 2. Home: quieter collection cards
>
> Add:
>
> ```dart
> import '../widgets/quiet_surface.dart';
> ```
>
> ### Replace `_quickCard`
>
> This keeps your existing call sites. The `gradient` parameter now supplies a single subtle tint rather than painting another gradient.
>
> ```dart
> Widget _quickCard({
>   required IconData icon,
>   required List<Color> gradient,
>   required String title,
>   required String subtitle,
>   required VoidCallback onTap,
>   required List<Track> Function() tracks,
>   String? cover,
> }) {
>   final tint = gradient.isEmpty ? AppColors.accent : gradient.first;
>
>
>   return QuietSurface(
>     onTap: onTap,
>     child: Column(
>       crossAxisAlignment: CrossAxisAlignment.start,
>       children: [
>         Row(
>           children: [
>             ClipRRect(
>               borderRadius: BorderRadius.circular(12),
>               child: cover != null && cover.isNotEmpty
>                   ? CachedCoverImage(
>                       url: cover,
>                       width: 42,
>                       height: 42,
>                     )
>                   : Container(
>                       width: 42,
>                       height: 42,
>                       color: tint.withAlpha(24),
>                       alignment: Alignment.center,
>                       child: Icon(
>                         icon,
>                         color: tint,
>                         size: 22,
>                       ),
>                     ),
>             ),
>             const Spacer(),
>             _playCollectionButton(
>               tracks,
>               label: '播放$title',
>             ),
>           ],
>         ),
>         const SizedBox(height: 18),
>         Text(
>           title,
>           maxLines: 1,
>           overflow: TextOverflow.ellipsis,
>           style: AppTypography.headline.copyWith(
>             fontSize: 18,
>             fontWeight: FontWeight.w600,
>             color: AppColors.textPrimary,
>           ),
>         ),
>         const SizedBox(height: 5),
>         Text(
>           subtitle,
>           maxLines: 2,
>           overflow: TextOverflow.ellipsis,
>           style: AppTypography.caption.copyWith(
>             color: AppColors.textSecondary,
>             height: 1.4,
>           ),
>         ),
>       ],
>     ),
>   );
> }
> ```
>
> ### Replace `_playCollectionButton`
>
> Keep the generous hit target, but remove the glow. Also disable the button when playback isn’t available.
>
> ```dart
> Widget _playCollectionButton(
>   List<Track> Function() tracks, {
>   String label = '播放歌单',
> }) {
>   final enabled =
>       widget.onPlayCollection != null && tracks().isNotEmpty;
>
>
>   return IconButton(
>     tooltip: label,
>     onPressed: enabled
>         ? () {
>             // Re-read at tap time in case the collection changed.
>             final collection = tracks();
>             if (collection.isEmpty) return;
>
>
>             Haptics.medium();
>             widget.onPlayCollection?.call(collection);
>           }
>         : null,
>     padding: EdgeInsets.zero,
>     constraints: const BoxConstraints(
>       minWidth: 48,
>       minHeight: 48,
>     ),
>     splashRadius: 24,
>     icon: Container(
>       width: 32,
>       height: 32,
>       alignment: Alignment.center,
>       decoration: BoxDecoration(
>         shape: BoxShape.circle,
>         color: enabled
>             ? AppColors.accent.withAlpha(24)
>             : AppColors.surfaceNeutral,
>       ),
>       child: Icon(
>         Icons.play_arrow_rounded,
>         size: 22,
>         color: enabled
>             ? AppColors.accent
>             : AppColors.textFaint,
>       ),
>     ),
>   );
> }
> ```
>
> ### Keep local playback genuinely local
>
> Your current `_localTracks` includes unfinished downloads. If “本地” means available offline, its play button should use completed downloads:
>
> ```dart
> tracks: () => _downloadedTracks,
> ```
>
> And keep the count visible even during downloads:
>
> ```dart
> subtitle: _downloadingTasks.isEmpty
>     ? '${_downloadedTracks.length} 首 · 离线可播'
>     : '${_downloadedTracks.length} 首 · '
>         '${_downloadingTasks.length} 首下载中',
> ```
>
> You can still show pending downloads inside the collection if that is intentional—just don’t automatically include them in an offline playback queue unless your player explicitly supports it.
>
> ### Fix the section order
>
> Currently, this is effectively rendered:
>
> ```text
> 下载中
> 我的歌单
> [download rows]
> [playlist rows]
> ```
>
> Remove `我的歌单` and its surrounding spacing from your first `SliverChildListDelegate`. Then insert its own header **after the download sliver and before the playlist sliver**:
>
> ```dart
> SliverPadding(
>   padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
>   sliver: SliverToBoxAdapter(
>     child: Row(
>       children: [
>         Expanded(
>           child: Text(
>             '我的歌单',
>             style: AppTypography.title.copyWith(
>               fontSize: 20,
>               fontWeight: FontWeight.w600,
>             ),
>           ),
>         ),
>         Text(
>           '${otherPlaylists.length}',
>           style: AppTypography.caption.copyWith(
>             color: AppColors.textMuted,
>           ),
>         ),
>       ],
>     ),
>   ),
> ),
> ```
>
> For `_playlistBar` and `_newPlaylistBar`, replace their `TrackRow(...)` wrapper with `QuietRow(...)`. Their children and callbacks can remain unchanged.
>
> **Keep only one prominent “新建歌单” entry.** Your existing bottom row is fine; there’s no need to also add a floating button.
>
> ---

> ## 3. Search: a stable, subtly responsive input
>
> The current search field changes height when the clear button appears: that button adds a 48px child inside vertical padding.
>
> Replace the `GlassCard` search input in `_header()` with:
>
> ```dart
> _buildSearchField(),
> ```
>
> Then add:
>
> ```dart
> Widget _buildSearchField() {
>   final focused = _focusNode.hasFocus;
>   final reduceMotion = MediaQuery.of(context).disableAnimations;
>
>
>   return AnimatedContainer(
>     duration: reduceMotion
>         ? Duration.zero
>         : const Duration(milliseconds: 180),
>     curve: Curves.easeOutCubic,
>     constraints: const BoxConstraints(minHeight: 58),
>     decoration: BoxDecoration(
>       color: AppColors.backgroundElevated,
>       borderRadius: BorderRadius.circular(18),
>       border: Border.all(
>         color: focused
>             ? AppColors.accent.withAlpha(140)
>             : AppColors.hairlineStrong,
>         width: 1,
>       ),
>     ),
>     child: Row(
>       children: [
>         const SizedBox(width: 16),
>         Icon(
>           Icons.search_rounded,
>           size: 22,
>           color: focused
>               ? AppColors.accent
>               : AppColors.textMuted,
>         ),
>         const SizedBox(width: 12),
>         Expanded(
>           child: TextField(
>             controller: _searchController,
>             focusNode: _focusNode,
>             textInputAction: TextInputAction.search,
>             autocorrect: false,
>             onSubmitted: _performSearch,
>             style: AppTypography.body.copyWith(
>               fontSize: 15,
>               color: AppColors.textPrimary,
>             ),
>             cursorColor: AppColors.accent,
>             decoration: const InputDecoration(
>               hintText: '歌曲、BV 号或链接',
>               hintStyle: TextStyle(
>                 color: AppColors.textFaint,
>                 fontSize: 15,
>               ),
>               isDense: true,
>               filled: false,
>               contentPadding: EdgeInsets.symmetric(vertical: 16),
>               border: InputBorder.none,
>               enabledBorder: InputBorder.none,
>               focusedBorder: InputBorder.none,
>             ),
>           ),
>         ),
>         // Always reserve the space so the input doesn't jump.
>         SizedBox(
>           width: 48,
>           height: 48,
>           child: _searchController.text.isEmpty
>               ? null
>               : IconButton(
>                   tooltip: '清空搜索',
>                   onPressed: _showRecommendations,
>                   icon: const Icon(
>                     Icons.close_rounded,
>                     size: 19,
>                     color: AppColors.textSecondary,
>                   ),
>                 ),
>         ),
>         const SizedBox(width: 4),
>       ],
>     ),
>   );
> }
> ```
>
> The focus treatment is intentionally just a border and icon change. No glow, scaling, or layout shift.
>
> ---
>
> ## 4. Search results: static text, artwork, quieter actions
>
> I would remove marquee animation from browsing lists. Multiple independent moving titles make the interface feel busy even when the user isn’t interacting.
>
> Use marquee only for the currently playing track, where it has a clear purpose.
>
> Add the shared component import to Search, then replace `_buildTrackTile`:
>
> ```dart
> Widget _buildTrackTile(Track track, int index) {
>   void openOptions() {
>     TrackOptionsMenu.show(
>       context,
>       track,
>       onTrackChanged: () async {
>         if (!mounted) return;
>         setState(() => _recommendationsStale = true);
>       },
>     );
>   }
>
>
>   return QuietRow(
>     key: ValueKey(track.id),
>     onTap: () => widget.onSelectTrack(track),
>     onLongPress: openOptions,
>     child: Row(
>       children: [
>         ClipRRect(
>           borderRadius: BorderRadius.circular(12),
>           child: CachedCoverImage(
>             url: track.coverUrl,
>             width: 54,
>             height: 54,
>           ),
>         ),
>         const SizedBox(width: 12),
>         Expanded(
>           child: Column(
>             crossAxisAlignment: CrossAxisAlignment.start,
>             children: [
>               Text(
>                 track.title,
>                 maxLines: 2,
>                 overflow: TextOverflow.ellipsis,
>                 style: AppTypography.body.copyWith(
>                   fontSize: 15,
>                   fontWeight: FontWeight.w600,
>                   color: AppColors.textPrimary,
>                   height: 1.3,
>                 ),
>               ),
>               const SizedBox(height: 5),
>               Text(
>                 '${track.uploader} · '
>                 '${formatDuration(Duration(seconds: track.duration))}',
>                 maxLines: 1,
>                 overflow: TextOverflow.ellipsis,
>                 style: AppTypography.caption.copyWith(
>                   fontSize: 12,
>                   color: AppColors.textSecondary,
>                   height: 1.3,
>                 ),
>               ),
>             ],
>           ),
>         ),
>         const SizedBox(width: 4),
>         SizedBox(
>           width: 48,
>           height: 48,
>           child: Center(
>             child: TrackDownloadButton(
>               track: track,
>               size: 22,
>               onPlay: () {
>                 final play = widget.onPlayOnly ?? widget.onSelectTrack;
>                 play(track);
>               },
>             ),
>           ),
>         ),
>         IconButton(
>           tooltip: '更多选项',
>           onPressed: openOptions,
>           padding: EdgeInsets.zero,
>           constraints: const BoxConstraints(
>             minWidth: 48,
>             minHeight: 48,
>           ),
>           icon: const Icon(
>             Icons.more_horiz_rounded,
>             size: 22,
>             color: AppColors.textMuted,
>           ),
>         ),
>       ],
>     ),
>   );
> }
> ```
>
> This intentionally changes the last action from **add to playlist** to **more options**, while keeping long-press as a shortcut. It makes the existing options menu discoverable.
>
> If adding to playlists is a frequent primary action in your app, keep your existing `+` button instead. That’s a product decision, not something minimalism should override.
>
> ### Simplify the results header
>
> Because results are paginated, `23 个结果` can look like a total count when it’s only the loaded count. Prefer:
>
> ```dart
> Row(
>   children: [
>     Expanded(
>       child: Text(
>         '搜索结果',
>         style: AppTypography.title.copyWith(
>           fontSize: 20,
>           fontWeight: FontWeight.w600,
>         ),
>       ),
>     ),
>     Text(
>       '已加载 ${_searchResults.length} 首',
>       style: AppTypography.caption,
>     ),
>   ],
> ),
> ```
>
> The field already has a clear button, so the extra `清空搜索` text button isn’t necessary.
>
> For recommendations, I’d use **“为你推荐”** without the sparkle icon. The heading is enough.
>
> ---
>
> ## 5. UX fixes worth making before polishing further
>
> These are visible in the provided code and affect how polished the app feels.
>
> ### Separate failure from an empty result
>
> In `_header()`, insert this branch **before** the existing “no results” branch:
>
> ```dart
> else if (_hasSearched &&
>     _searchResults.isEmpty &&
>     _searchLoadFailed) ...[
>   Padding(
>     padding: const EdgeInsets.symmetric(vertical: 40),
>     child: Column(
>       children: [
>         const EmptyState(
>           icon: Icons.wifi_off_rounded,
>           title: '暂时无法搜索',
>           subtitle: '检查网络连接后再试一次',
>         ),
>         const SizedBox(height: 12),
>         TextButton.icon(
>           onPressed: () => _performSearch(_lastQuery),
>           icon: const Icon(Icons.refresh_rounded, size: 18),
>           label: const Text('重新加载'),
>         ),
>       ],
>     ),
>   ),
> ]
> ```
>
> A network error should never tell the user their song doesn’t exist.
>
> ### Correct request ownership
>
> Your search tokens are a good start, but there are gaps:
>
> - `_performSearch` allocates its token **after** awaiting history persistence. Allocate it before the first `await`, and check it after each asynchronous operation. Otherwise, rapid submissions can finish their history writes out of order.
> - `_showRecommendations` should invalidate the current search token, clear `_isLoading`, and reset search pagination. Currently an in-flight search can finish after the user clears the field.
> - `_clearSearchHistory` should invalidate `_recPass` and clear recommendation loading state. Otherwise, an old recommendation request can repopulate data after history is cleared.
> - Pagination loading state should belong to a particular request or generation. Simply resetting the shared `_isLoadingMore` boolean introduces another race: an old request’s `finally` can clear the loading state of a newer request.
>
> These are worth fixing together rather than adding isolated boolean resets.
>
> ### Make refresh mean refresh
>
> Your comments describe pull-to-refresh, but the supplied `build()` has no `RefreshIndicator`.
>
> If you add one:
>
> - Pull down → refresh the current query or recommendation pass.
> - Scroll to the bottom → fetch the next page.
> - Pagination failure → show a tappable **“重试加载”** footer.
>
> Using pull-to-refresh to append older results is surprising.
>
> ### Don’t hide every playlist-management action behind long-press
>
> Keep long-press, but also expose deletion through a visible menu in the playlist detail sheet if it doesn’t already have one. The Home row doesn’t need another icon if the detail view provides discoverability.
>
> ---
>
> ## Final visual rules I’d apply across both screens
>
> | Element | Treatment |
> |---|---|
> | Page margins | 20px, consistent |
> | Section spacing | 28–32px |
> | Section titles | 20px, semibold |
> | Track titles | 15px, semibold, static |
> | Supporting text | 12–13px, readable—not excessively faint |
> | Artwork | 54px in rows, 12px corner radius |
> | Quick cards | Flat elevated surface, 20px radius |
> | Action targets | At least 48 × 48px |
> | Accent color | Focus, playback, selection—not every decoration |
> | Motion | Short interaction feedback; no idle list animation |
>
> Also test the recently played rail at larger system text sizes: its fixed `height: 200` can become restrictive. Let its height account for text scaling, or switch it to vertical rows in accessibility layouts.
>
> **The largest visual win will come from subtracting:** remove glowing play buttons, remove list marquees, and reserve card surfaces for the two quick-access collections. That gives the artwork and typography room to make the app feel premium.
>
> These patches use the interfaces shown in your snippets; I haven’t compiled them against your project. Remove imports such as `glass_card.dart` and `marquee_text.dart` wherever they become unused.

---

# M2 — Full v4 direction

*Context: Astra was given the complete source dump (services, main.dart,
screens, widgets — packaged as a PDF) and asked for the next-major-version
direction.*

> Yes. **BiliBeat has a good foundation, but the next major version should prioritize consistency and trust over adding more visual effects.**
>
> The strongest direction is:
>
> > **A quiet, artwork-led player where playback, saving, and downloading always mean exactly what the user expects.**
>
> You already have useful building blocks: `AppColors`, `AppTypography`, `TrackRow`, `GlassCard`, lazy lists, artwork caching, and overflow-aware marquee. I would evolve these—not replace them with another component system.
>
> **Review scope:** I reviewed the supplied source text, not a running build or screenshots. The code supports the findings below, but visual balance, performance, and platform behavior still need device verification. Many Chinese strings were lost in the PDF extraction; any readable Chinese copy below is suggested replacement copy, not recovered text.
>
> ---
>
> # 1. Overall assessment
>
> ## What I would keep
>
> - **Two primary destinations.** Library and Search are enough. A third “Discover” tab would currently add navigation without enough distinct functionality.
> - **Artwork-first presentation.**
> - **Plain track rows rather than cards around every song.**
> - **Marquee in browsing lists.** Long Bilibili titles are a real identification problem; removing marquee would sacrifice usability.
> - **The compact-to-full-player transition**, but only when the full player actually represents the docked track.
> - **Local playback reliability as a product characteristic**, provided downloading is explained clearly.
> - **Advanced lyric correction**, but presented as a secondary tool rather than competing with listening.
>
> ## What currently weakens the experience
>
> Three things stand out:
>
> 1. **The UI sometimes represents an intention as if it were a completed state.**
>    A track can appear current before playback succeeds; a failed download can disappear; a failed search can look empty.
>
> 2. **Actions have hidden side effects.**
>    Favoriting starts a download. Adding to a playlist starts downloads. Removing a download removes the track from playlists and history.
>
> 3. **The visual language is quieter in comments than in implementation.**
>    For example, the mini-player comment describes a quiet control, but the actual button still has a pink gradient and glow.
>
> These matter more than changing the palette.
>
> ---
>
> # 2. Release blockers: fix these before the redesign ships
>
> ## A. Playback startup can remain “rebuilding” throughout playback
>
> **File:** `lib/services/audio_player_handler.dart`
> **Symbols:** `_startCurrent`, `play`, `_playAtIndex`
>
> In `just_audio`, the future returned by `play()` does not simply mean “playback has started”; it can remain pending until playback pauses, stops, or completes.
>
> Consequently, this code is especially concerning:
>
> ```dart
> if (autoplay && token == _startToken) {
>   await _player.play();
>   ...
> }
> ```
>
> It sits inside `_startCurrent` before the `finally` that clears `_isRebuilding`, and before `_prefetchNext()`.
>
> **Likely consequence:** `_isRebuilding` stays true while the track plays, index reconciliation is suppressed, and prefetch is delayed until playback ends or pauses.
>
> **Required correction:** finish source preparation and release rebuild ownership independently of the playback-lifetime future. Observe playing state through the player stream, and handle asynchronous playback errors explicitly.
>
> Also, `_startCurrent` checks its token after downloading, but not between every subsequent queue mutation. Two starts can still interleave during `clear`, `add`, and `setAudioSource`. These native queue mutations need serialization, not just an early token check.
>
> This is a service correctness fix, not a UI restyle.
>
> ---
>
> ## B. “Search failed” cannot be reliably distinguished from “no matches”
>
> **Files:** `search_screen.dart`, `bilibili_sdk.dart`
>
> The unused `_searchLoadFailed` branch is only half the problem.
>
> `_httpGet`, `_searchOnce`, and `fetchVideoInfo` swallow failures and return `null` or `[]`. Therefore, much of the time, `_performSearch` never reaches its `catch`.
>
> **Adding a Wi-Fi-off widget alone will not solve this.**
>
> Keep the existing public signature if desired:
>
> ```dart
> Future<List<Track>> search(String query, {int page = 1})
> ```
>
> But give it a reliable contract:
>
> - Successful request with no matches → `[]`.
> - All applicable request/fallback attempts fail → throw.
> - Invalid/unavailable direct video → distinguish from a transport failure.
> - Recommendation batches may tolerate partial failures, but **all seeds failing must not become a successful empty batch**.
>
> Use neutral failure copy such as “Couldn’t load results.” Do not claim the device is offline when the cause may be API rejection or a server error.
>
> ---
>
> ## C. Search request ownership is incomplete
>
> **File:** `search_screen.dart`
>
> All the ownership issues identified in the dump are present.
>
> The required invariant is:
>
> > A request may update results, errors, pagination, or loading state only while it still owns that operation.
>
> Apply it to these exact methods:
>
> | Method | Required change |
> |---|---|
> | `_performSearch` | Allocate `_searchToken` **before** the history await; show loading immediately; guard after every await. |
> | `_showRecommendations` | Invalidate pending search work and release its loading/pagination state. Do not merely clear the visible results. |
> | `_clearSearchHistory` | Invalidate recommendation work before awaiting storage; prevent an older history read from restoring cleared chips. |
> | `_loadRecommendations` | Invalidate the previous recommendation pass even in the `_canRecommend == false` branch. |
> | `_loadMoreSearch` | Its `finally` must not clear a newer request’s loading flag. |
> | `_loadMoreRecommendations` | Remove the unconditional stale-request cleanup that clears shared loading state. |
> | `_loadSearchHistory` | Do not let startup history loading overwrite a later user action. |
>
> For pagination, an operation-identity ticket is safer than a shared Boolean alone:
>
> ```dart
> final owner = Object();
> _loadMoreOwner = owner;
> ```
>
> A completion should only release loading when:
>
> ```dart
> identical(_loadMoreOwner, owner)
> ```
>
> The result commit must additionally match its search token or recommendation pass.
>
> **Do not treat this as a one-line token fix.** Fixing token allocation while leaving stale `finally` blocks intact still produces races.
>
> ---

> ## D. Removing a download also removes the user’s collection membership
>
> **File:** `database_service.dart`
> **Symbol:** `removeDownloadedTrack`
>
> This method deletes the audio **and removes the track from every playlist, Favorites, and Recently Played**.
>
> That is materially more destructive than an action normally labeled “Remove download.”
>
> For v4, separate these meanings:
>
> | Action | Expected result |
> |---|---|
> | Remove download | Delete local audio; preserve playlists and Favorites. |
> | Remove from this playlist | Change only that playlist. |
> | Remove from library | Explicit broader removal, with accurate confirmation. |
>
> Until the service operations are separated, the UI must disclose the actual scope. Do not ship a gentle storage-cleanup label over this behavior.
>
> ---
>
> ## E. Local collection playback includes unfinished downloads
>
> **File:** `home_screen.dart`
> **Symbol:** `_localTracks`
>
> Verified: `_localTracks` combines active download tasks with completed downloads, and the Local card’s play button uses it.
>
> There is another related issue in `PlaylistDetailSheet`:
>
> ```dart
> .where((t) => !DownloadManager.instance.isDownloading(t.id))
> ```
>
> **“Not downloading” is not equivalent to “available offline.”** A failed download also satisfies that condition.
>
> Decide separately:
>
> - Local collection queue → completed local files only.
> - Normal playlist queue → either downloadable tracks with explicit preparation states, or an explicitly labeled “Downloaded only” mode.
>
> ---
>
> ## F. Lyric editing has two serious correctness problems
>
> ### Paste disappears precisely when it is needed
>
> **File:** `lyric_editor_dialog.dart`
> **Symbol:** `_buildResultList`
>
> When `_searchResults.isEmpty`, the builder is replaced by an empty-state message. Since the Paste LRC card is inside that builder, it disappears when providers find nothing.
>
> This is an immediate usability bug.
>
> ### Automatic results can overwrite deliberate edits
>
> **Files:** `main.dart`, `now_playing_sheet.dart`
>
> A track-ID guard is not enough.
>
> An automatic lyric request can begin for track A, the user can apply corrected lyrics for A, and the earlier request can still complete and overwrite them because the track ID still matches.
>
> A→B→A also defeats a pure ID guard.
>
> **Required correction:** lyric-load generation plus a manual-edit revision/ownership guard. Automatic results may only commit if neither has changed.
>
> Additionally, the editor remains attached to mutable `_displayTrack`. `holdAutoAdvance()` does not prevent manual Next/Previous or OS media controls. Capture the edited track and its ID when opening the editor; apply edits to that captured target, not whichever track happens to be displayed later.
>
> ---
>
> # 3. The v4 product direction
>
> I would keep the app small and make its behavior more legible.
>
> ## Library
>
> Recommended order:
>
> ```text
> Library                              Settings
>
>
> [ Downloaded ]       [ Favorites ]
>   128 available        64 tracks
>   2 downloading
>
>
> Recently played                      See all
> [ artwork ] [ artwork ] [ artwork ]
>
>
> Playlists                            +
> [ cover ] Evening collection         …
> [ cover ] Piano                      …
> [ cover ] Running                    …
>
>
> Downloads                            2 active
> [ track ] progress
> ```
>
> ### Why this is better
>
> - Listening content precedes management.
> - Recently Played becomes a real “continue listening” surface.
> - Downloads remain visible without being mistaken for playable library items.
> - Playlist creation becomes a header action rather than a permanent oversized pseudo-playlist.
> - If Recently Played is empty, omit that section rather than filling the Library with another large empty-state medallion.
>
> Keep the two quick-access cards, but make them **neutral surfaces with meaningful artwork or simple icons**, not competing green and pink gradient blocks.
>
> For large libraries, add **search inside a collection** before adding more discovery features.
>
> ---
>
> ## Search
>
> Recommended hierarchy:
>
> ```text
> Search field
>
>
> Focused:
>   Recent searches                 Clear
>
>
> Submitted:
>   Results for “query”
>   [art] Long title → marquee      ↓  …
>         Uploader · 03:42
>
>
> Failed:
>   Couldn’t load results
>   Your search is still here.
>   [Retry]
>
>
> Successful but empty:
>   No matches for “query”
>   Try a title, uploader, or BV link.
> ```
>
> ### Changes I recommend
>
> - Keep marquee for titles.
> - Keep uploader and duration static.
> - Change the trailing `+` to `…`, opening the existing `TrackOptionsMenu`.
> - Keep downloading directly available if offline collection is central to the product.
> - Use explicit pagination Retry, not “scroll again later.”
> - Add pull-to-refresh only with familiar semantics: **reload the current query**, not append another page.
> - For short lists, provide a visible Load More affordance; do not require impossible scrolling.
> - Do not present the loaded result count as the total number of matches.
>
> I would retain submitted search rather than introducing search-on-every-keystroke. It is quieter and avoids unnecessary requests.
>
> ---
>
> ## Playback behavior
>
> The current app is download-then-play, not a streaming player. The UI should be honest about that.
>
> A clear near-term contract:
>
> | User action | Result |
> |---|---|
> | Tap downloaded track | Start playback; stay in the collection. |
> | Tap undownloaded search result | Open track details, clearly labeled as not currently playing. |
> | Tap Play in those details | “Download & play,” then progress, then playback. |
> | Tap download icon | Download only. |
> | Tap Favorite | Favorite only, unless an explicit auto-download preference is enabled. |
> | Tap mini-player | Open the active player. |
>
> **Do not silently change the current Download button into Download & Play without implementing pending-play ownership.** A completed download must not interrupt a newer listening choice.
>
> A v4 preparation state should distinguish:
>
> - preparing,
> - downloading,
> - ready/paused,
> - playing,
> - failed with Retry.
>
> `isPlaying` alone cannot represent these states.
>
> ---
>
> ## Now Playing
>
> Suggested hierarchy:
>
> ```text
> ⌄              From Evening collection             …
>
>
>                   Album artwork
>
>
> Long song title → marquee
> Artist / uploader
>
>
> ──────────── seek ────────────
> 01:24                         −02:18
>
>
>           Previous   Play/Pause   Next
>
>
>        Favorite       Lyrics       Queue
> ```
>
> ### Important changes
>
> - Replace the centered logo with **source context** or a clear “Track details” label.
> - Move metadata editing into `…`.
> - Keep the dominant play button, but use a flat fill instead of gradient plus glow.
> - Give shuffle/repeat explicit controls in Queue or a playback-options sheet. Cycling three behaviors through one changing icon is compact but hard to predict.
> - Limit swipe-to-dismiss to the top handle/chrome.
> - On short screens or with the keyboard open, use a compact layout instead of squeezing artwork and editor above a permanently large transport panel.
>
> For lyrics:
>
> - Remove the pink text shadow.
> - Avoid animating between 20 and 24 pt for every active-line change; changing line height makes centering harder.
> - Prefer stable font size, with weight/color emphasis.
> - Keep browsing mode until the user chooses “Return to current,” or make the timed return clearly deliberate.
> - Use more readable inactive text. Current opacity drops to `0.24`, including already-muted translations.
>
> ---

> # 4. Focused patches against the supplied interfaces
>
> These are intentionally bounded patches. They do **not** claim to solve the service ownership issues above.
>
> ## Patch 1 — Separate Local from active downloads
>
> **File:** `lib/screens/home_screen.dart`
>
> Remove `_localTracks` and replace `_openDownloadedPlaylist` with:
>
> ```dart
> void _openDownloadedPlaylist() {
>   _openPlaylist(Playlist(
>     id: 'downloaded',
>     name: '本地',
>     tracks: List<Track>.of(_downloadedTracks),
>   ));
> }
> ```
>
> In the Local quick card:
>
> ```dart
> subtitle: _downloadingTasks.isEmpty
>     ? '${_downloadedTracks.length} 首可离线播放'
>     : '${_downloadedTracks.length} 首可播放 · '
>       '${_downloadingTasks.length} 首下载中',
> onTap: _openDownloadedPlaylist,
> tracks: () => List<Track>.of(_downloadedTracks),
> ```
>
> This uses the existing completed-download registry. It does not add synchronous filesystem checks to build.
>
> ### Fix the section order
>
> Remove the Playlists heading and its surrounding spacing from the first `SliverChildListDelegate`.
>
> Insert it **after** the downloading-rows sliver, immediately before the playlists sliver:
>
> ```dart
> const SliverPadding(
>   padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
>   sliver: SliverToBoxAdapter(
>     child: Text('我的歌单', style: AppTypography.title),
>   ),
> ),
> ```
>
> That fixes the verified header/data mismatch without changing the component system.
>
> ### Remove duplicate bottom clearance
>
> `MainLayout` already reserves `dockedHeight` below the pages.
>
> In Home, replace:
>
> ```dart
> padding: EdgeInsets.fromLTRB(
>   20, 0, 20, MiniPlayer.totalHeight(context) + 24),
> ```
>
> with:
>
> ```dart
> padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
> ```
>
> In Search, replace the final mini-player-height spacer with:
>
> ```dart
> const SliverToBoxAdapter(
>   child: SizedBox(height: 24),
> ),
> ```
>
> **Remove `mini_player.dart` imports from Home and Search** once those are their last references. Keep the import in `main.dart`.
>
> ---
>
> ## Patch 2 — Make the search field stable
>
> **File:** `lib/screens/search_screen.dart`
> **Symbol:** `_header`
>
> Change the search `GlassCard` padding:
>
> ```dart
> padding: const EdgeInsets.symmetric(
>   horizontal: 14,
>   vertical: 4,
> ),
> ```
>
> Replace the conditionally inserted clear button with a permanently reserved slot:
>
> ```dart
> SizedBox(
>   width: 48,
>   height: 48,
>   child: _searchController.text.isEmpty
>       ? null
>       : IconButton(
>           onPressed: _showRecommendations,
>           tooltip: '清除搜索',
>           icon: const Icon(
>             Icons.clear,
>             color: AppColors.textMuted,
>             size: 18,
>           ),
>         ),
> ),
> ```
>
> The field no longer changes height when the first character is typed.
>
> ### Add the missing failure branch
>
> Insert this **before** the successful-empty branch:
>
> ```dart
> else if (_hasSearched &&
>     _searchResults.isEmpty &&
>     _searchLoadFailed) ...[
>   const EmptyState(
>     icon: Icons.wifi_off_rounded,
>     title: '暂时无法加载结果',
>     subtitle: '请稍后重试，你的搜索内容已保留',
>   ),
>   Center(
>     child: OutlinedButton.icon(
>       onPressed: () => _performSearch(_lastQuery),
>       icon: const Icon(Icons.refresh_rounded, size: 18),
>       label: const Text('重试'),
>     ),
>   ),
> ]
> ```
>
> **Dependency:** this only becomes reliable after the SDK distinguishes errors from successful emptiness.
>
> ---
>
> ## Patch 3 — Keep Paste LRC reachable when search finds nothing
>
> **File:** `lib/widgets/lyric_editor_dialog.dart`
> **Symbol:** `_buildResultList`
>
> Replace its results `Expanded` with:
>
> ```dart
> Expanded(
>   child: ListView.builder(
>     itemCount: _searchResults.length + 1,
>     itemBuilder: (context, index) {
>       if (index < _searchResults.length) {
>         return _resultRow(_searchResults[index], index);
>       }
>
>
>       return Column(
>         crossAxisAlignment: CrossAxisAlignment.stretch,
>         children: [
>           if (_searchResults.isEmpty)
>             Padding(
>               padding: const EdgeInsets.symmetric(vertical: 24),
>               child: Text(
>                 _isSearching ? '正在查找歌词…' : '暂未找到匹配歌词',
>                 textAlign: TextAlign.center,
>                 style: AppTypography.bodyMedium,
>               ),
>             ),
>           _pasteCard(),
>         ],
>       );
>     },
>   ),
> ),
> ```
>
> The existing search-field spinner can continue indicating activity. The fallback action is now always available.
>
> Also invalidate `_searchToken` in the editor’s empty-query branch; currently an older nonempty query can repopulate results after an empty search.
>
> ---

> ## Patch 4 — Surface download failures
>
> **File:** `lib/main.dart`
>
> `DownloadManager.errors` exists, but I found no UI subscriber in the supplied files.
>
> Add:
>
> ```dart
> import 'services/download_manager.dart';
> import 'utils/snack.dart';
> ```
>
> Inside `_initListeners()`:
>
> ```dart
> _subs.add(
>   DownloadManager.instance.errors.listen((_) {
>     if (!mounted) return;
>
>
>     showAppSnackBar(
>       ScaffoldMessenger.of(context),
>       message: '下载未完成，请重试',
>       backgroundColor: AppColors.backgroundElevated,
>       duration: const Duration(seconds: 4),
>     );
>   }),
> );
> ```
>
> Your existing `_subs` cleanup handles disposal.
>
> This is a minimum fallback, not the final download UX. A persistent failed row with Retry is better, but the current `errors` stream only carries a string—not the track ID needed for a reliable Retry action.
>
> Avoid showing raw exception strings directly to users.
>
> ---
>
> ## Patch 5 — Correct the player-transition origin
>
> **File:** `lib/main.dart`
> **Symbol:** `_openNowPlaying`
>
> Replace:
>
> ```dart
> final from = _miniPlayerRect();
> ```
>
> with:
>
> ```dart
> final from = focused.id == _audioHandler.currentTrack?.id
>     ? _miniPlayerRect()
>     : null;
> ```
>
> Why: `_miniPlayerRect()` can exist even when nothing is playing, because the empty mini-player is permanently mounted.
>
> An unrelated search-result preview should not appear to emerge from the currently playing track’s card. With this patch, unrelated details use the existing slide-up fallback.
>
> ---
>
> ## Patch 6 — Quiet the existing surfaces and controls
>
> ### `lib/widgets/glass_card.dart`
>
> Replace its gradient with a flat surface:
>
> ```dart
> decoration: BoxDecoration(
>   color: AppColors.surfaceCard,
>   borderRadius: BorderRadius.circular(borderRadius),
>   border: Border.all(color: AppColors.hairline),
> ),
> ```
>
> Keep the `GlassCard` API and update its documentation. No new card abstraction is needed.
>
> ### `lib/widgets/mini_player.dart`
>
> In `_playButton`, replace the inner circle decoration:
>
> ```dart
> decoration: const BoxDecoration(
>   shape: BoxShape.circle,
>   color: AppColors.white12,
> ),
> ```
>
> Remove the gradient and accent shadow. The artwork and track title should lead the mini-player.
>
> Also replace the hardcoded 160 ms duration with:
>
> ```dart
> duration: AppMotion.instant,
> ```
>
> ### `lib/widgets/now_playing_sheet.dart`
>
> In `_circleButton`, replace gradient/color/shadow styling with:
>
> ```dart
> decoration: BoxDecoration(
>   shape: BoxShape.circle,
>   color: filled ? AppColors.accent : AppColors.white12,
>   border: filled
>       ? null
>       : Border.all(color: AppColors.hairlineStrong),
> ),
> ```
>
> The full-player primary action remains strong without glowing.
>
> ### `lib/widgets/track_download_button.dart`
>
> Change:
>
> ```dart
> static const double _box = 48.0;
> ```
>
> Then fix the downloaded-but-no-callback case:
>
> ```dart
> } else if (_isDownloaded) {
>   final canPlay = widget.onPlay != null;
>
>
>   glyph = Icon(
>     canPlay
>         ? Icons.play_circle_fill
>         : Icons.download_done_rounded,
>     color: canPlay ? AppColors.accent : AppColors.textMuted,
>     size: canPlay ? widget.size + 4 : widget.size,
>   );
>
>
>   onTap = canPlay
>       ? () {
>           Haptics.light();
>           widget.onPlay!();
>         }
>       : null;
>
>
>   tooltip = canPlay ? '播放' : '已下载';
> }
> ```
>
> A completed-download indicator should not look like an enabled Play button that does nothing.
>
> This fixes footprint and behavior. A separate semantics/focus pass is still needed for custom gesture-based buttons.
>
> ---
>
> # 5. Additional UX issues worth fixing in v4
>
> ## Navigation and input
>
> - **Tab taps can generate multiple haptics.**
>   `SegmentTabs`, `_onTabTap`, and `onPageChanged` all trigger feedback. Choose one owner per interaction.
>
> - **`SegmentTabs` animates its indicator, but its label styles are outside that animation builder.**
>   Label selection can lag unless the parent rebuilds. Make label selection follow the same animation explicitly.
>
> - **Playlist overlay is not a Navigator route.**
>   There is no `PopScope` in `MainLayout` to close it first. System Back should close edit mode/playlist before leaving the app.
>
> - **Playlist renaming is hidden behind double-tap.**
>   Add Rename to a visible menu. Keep double-tap only as an optional shortcut.
>
> - **Reordering belongs in edit mode.**
>   Currently delayed drag is available in normal browsing, while edit mode mainly exposes selection. Put visible drag handles in edit mode.
>
> - **Nested editor Back should step back within the editor.**
>   Back from LRC text or preview currently risks closing the entire editor rather than returning to its previous state. Unsaved text also needs protection.
>
> ## Data and state presentation
>
> - **Favorites state is not refreshed when the full-player route returns from unrelated library edits.**
>   Listen to relevant library updates and guard asynchronous refresh ownership.
>
> - **`_handleFavorite` uses mutable `_displayTrack` across an await.**
>   Capture the track before toggling, block repeated taps, and only update the visible favorite state if that track is still displayed. Otherwise the wrong track can be downloaded after the await.
>
> - **`TrackDownloadButton` does not observe download deletion through library updates.**
>   A preserved search row can continue showing Play after its local file is removed.
>
> - **Search pagination stops on a duplicate-only page.**
>   `fresh.isEmpty` does not prove the source has ended. Recommendations make this especially likely because filtering can discard a whole batch.
>
> - **`showAddToPlaylistForTracks` does not await/return the modal future.**
>   Its declared future can finish before the sheet is dismissed. Fix that contract before relying on it for ordered UI transitions.
>
> ## Visual and accessibility
>
> - Keep marquee, but test a longer initial reading pause and pausing motion during active scrolling. That changes behavior, not the component system.
> - Add marquee to the Recently Played title and local-track picker where static ellipsis still hides identification.
> - Reduced motion is respected by marquee and lyric scrolling, but not consistently by shimmer, artwork scale, route morphs, or other transitions.
> - The mini-player seek strip is only 22 px high. I would make mini-player progress **display-only** and keep accessible seeking in the full player rather than expand a conflicting gesture surface.
> - Fixed 44 px editor buttons should become at least 48 px.
> - Verify text contrast on the actual composited backgrounds. A comment claiming `textFaint` meets AA against one background does not establish contrast over the artwork-derived aura.
> - Replace the global browsing ambient layer with a static neutral background. Reserve artwork tint for Now Playing.
> - Avoid forcing saturation into grayscale artwork; the existing minimum saturation can invent a hue the artwork never had.
>
> ---
>
> # 6. Features I would actually add
>
> Only three are strong enough to justify v4 scope.
>
> ## 1. Queue visibility
>
> Show:
>
> - where playback came from,
> - what plays next,
> - current shuffle/repeat state,
> - an option to jump to another queued item.
>
> Start read-only plus selection. Queue reordering can follow.
>
> **Implementation caveat:** the handler currently keeps its logical queue private and does not publish it through the inherited `queue` stream. A proper queue UI needs that authoritative snapshot; do not build a second queue inside a widget.
>
> ## 2. Sleep timer
>
> A small player-menu feature:
>
> - 15 / 30 / 60 minutes,
> - end of current track,
> - cancel timer.
>
> Implement it in the playback layer so behavior does not depend on an open screen. “End of track” should pause explicitly; merely preventing auto-advance can leave native playing state inconsistent.
>
> ## 3. Download management
>
> One quiet view containing:
>
> - active downloads,
> - failed downloads with Retry,
> - completed size/storage usage,
> - explicit remove-download behavior.
>
> Do not add Cancel until cancellation exists in the service. A disappearing row is not cancellation.
>
> I would postpone social features, elaborate discovery carousels, visualizers, and more themes.
>
> ---
>
> # 7. Recommended shipping order
>
> ### First: correctness
>
> - Playback startup/queue ownership.
> - Search error contract and request ownership.
> - Completed-only Local queue.
> - Download failure visibility.
> - Safe lyric-edit ownership.
> - Accurate deletion semantics.
>
> ### Second: the v4 visual pass
>
> - Neutral browsing background.
> - Flat primary controls.
> - Stable search field.
> - Consistent 20 px outer margins.
> - One bottom-inset owner.
> - Standard row actions.
> - Accessible targets and reduced motion.
> - Player versus track-details distinction.
>
> ### Third: focused features
>
> - Queue.
> - Sleep timer.
> - Download management.
>
> ## Release acceptance tests
>
> At minimum:
>
> - Search A → B; A completes last.
> - Search → Clear; old results never return.
> - Clear history during recommendation loading.
> - Load-more A → new query B; A cannot clear B’s spinner.
> - Rapid Play A → B → C; only the latest intent wins.
> - Pause during preparation; playback must not start later against that intent.
> - Edit lyrics while an automatic fetch is pending.
> - Switch tracks using OS controls while editing metadata.
> - Failed download remains understandable and retryable.
> - Remove local audio without unexpectedly destroying playlists.
> - System Back closes the playlist overlay.
> - 320 px width, landscape, keyboard open, and 200% text scaling.
> - Reduced motion and screen-reader navigation.
>
> **My recommendation:** make v4 feel less like “a more decorated music app” and more like **a dependable personal listening tool**. Your existing components are sufficient. The substantial improvement comes from removing ambiguous actions, making state truthful, and giving artwork and typography room to lead.

---

# M3 — New-UI attempt 1 (fragment, superseded by M4)

*Context: Astra was asked to write code for a new, improved UI. Its first
attempt errored mid-message; the user regenerated, producing M4. The
fragment is quoted exactly as received, truncation included.*

> es—and I would start by removing the pill-shaped top navigation, not refining it.
>
> The current header feels unnatural because it mixes three competing ideas:
>
> Large labels that resemble page headings.
> A colored segmented-control capsule.
> A logo occupying the remaining space without providing an action.
> For two top-level destinations, I would use editorial text navigation: two clearly tappable labels, an understated moving underline, and no decorative container or logo.
>
> The overall direction:
>
> text
>
>
> 资料库     搜索
> ━━━━
>
>
> [ 本地音乐        ] [ 我的收藏        ]
>   128 首可播放       64 首
>
>
> 最近播放
> [ artwork ] [ artwork ] [ artwork ]
>
>
> 我的歌单                              +
> [ artwork ] Playlist name             ›
> Neutral browsing surfaces. Artwork supplies the color. Pink indicates interaction—not decoration.
>
> Below are direct replacements against your supplied interfaces. They preserve SegmentTabs, GlassCard, AppTypography, and marquee. I cannot promise “perfect” without viewing the running app, but this is a coherent, implementable design pass rather than a collection of cosmetic suggestions.
>
> 1. Replace the top navigation component
>
> Replace lib/widgets/segment_tabs.dart completely.
>
> This version:
>
> Removes the capsule and colored border.
> Uses stable, equal-weight text.
> Animates the underline with your existing PageController/TabController animation.
> Gives every label at least a 48 px target.
> Supports text scaling and RTL.
> Provides proper selected semantics.
> Removes the render-box measurement/retry machinery.
> Keeps the existing public interface.
> dart
>
> import 'package:flutter/material.dart';
>
>
> import '../theme/app_theme.dart';
> import '../theme/haptics.dart';
>
>
> /// Quiet, text-led navigation.
> ///
> /// Retains the existing API for both:
> /// - MainLayout's PageController-backed animation.
> /// - LyricEditorDialog's TabController animation.
> ///
> /// There is no enclosing capsule. Labels provide hierarchy; a small
> /// underline communicates selection and follows page swipes.
> class SegmentTabs extends StatelessWidget {
>   final List<String> labels;
>   final Animation<double> animation;
>   final ValueChanged<int> onTap;
>   final double fontSize;
>
>
>   const SegmentTabs({
>     super.key,
>     required this.labels,
>     required this.animation,
>     required this.onTap,
>     this.fontSize = 23,
>   });
>
>
>   static const double _horizontalPadding = 12;
>   static const double _gap = 8;
>   static const double _minimumHeight = 48;
>
>
>   @override
>   Widget build(BuildContext context) {
>     if (labels.isEmpty) return const SizedBox.shrink();
>
>
>     final direction = Directionality.of(context);
>     final scaler = MediaQuery.textScalerOf(context);
>
>
>     final labelStyle = AppTypography.title.copyWith(
>       fontSize: fontSize,
>       height: 1.2,
>       fontWeight: FontWeight.w600,
>       letterSpacing: -0.45,
>     );
>
>
>     final naturalWidths = labels.map((label) {
>       final painter = TextPainter(
>         text: TextSpan(text: label, style: labelStyle),
>         textDirection: direction,
>         textScaler: scaler,
>         maxLines: 1,
>       )..layout();
>
>
>       final width = painter.width + _horizontalPadding * 2;
>       painter.dispose();
>
>
>       return width < 48 ? 48.0 : width;
>     }).toList();
>
>
>     return LayoutBuilder(
>       builder: (context, constraints) {
>         final naturalTotal =
>             naturalWidths.fold<double>(0, (sum, width) => sum + width) +
>                 _gap * (labels.length - 1);
>
>
>         // Normally the labels use their natural widths. On narrow layouts,
>         // shrink their slots rather than overflowing the header.
>         final available = constraints.maxWidth.isFinite
>             ? constraints.maxWidth
>             : naturalTotal;
>
>
>         final totalWidth = naturalTotal < available
>             ? naturalTotal
>             : available;
>
>
>         final gapTotal = _gap * (labels.length - 1);
>         final roomForItems =
>             (totalWidth - gapTotal).clamp(0.0, double.infinity);
>
>
>         final naturalItemTotal =
>             naturalWidths.fold<double>(0, (sum, width) => sum + width);
>
>
>         final scale = naturalItemTotal > 0
>             ? (roomForItems / naturalItemTotal).clamp(0.0, 1.0)
>             : 1.0;
>
>
>         final widths =
>             naturalWidths.map((width) => width * scale).toList();
>
>
>         final starts = <double>[];
>         var cursor = 0.0;
>
>
>         for (final width in widths) {
>           starts.add(cursor);
>           cursor += width + _gap;
>         }
>
>
>         return Align(
>           alignment: AlignmentDirectional.centerStart,
>           child: SizedBox(
>             width: totalWidth,
>             child: AnimatedBuilder(
>               animation: animation,
>               builder: (context, _) {
>                 final value = animation.value
>                     .clamp(0.0, (labels.length - 1).toDouble());
>
>
>                 final selected = value.round();
>                 final from = value.floor();
>                 final to = from + 1 < labels.length ? from + 1 : from;
>                 final fraction = value - from;
>
>
>                 final fromCenter = starts[from] + widths[from] / 2;
>                 final toCenter = starts[to] + widths[to] / 2;
>
>
>                 final center =
>                     fromCenter + (toCenter - fromCenter) * fraction;
>
>
>                 final slotWidth =
>                     widths[from] + (widths[to] - widths[from]) * fraction;
>
>
>                 final underlineWidth = slotWidth < 24 ? slotWidth : 24.0;
>
>
>                 return Stack(
>                   children: [
>                     Row(
>                       crossAxisAlignment: CrossAxisAlignment.center,
>                       children: [
>                         for (var i = 0; i < labels.length; i++) ...[
>                           if (i > 0) const SizedBox(width: _gap),
>                           SizedBox(
>                             width: widths[i],
>                             child: _label(
>                               context,
>                               index: i,
>                               selected: selected == i,
>                               emphasis:
>                                   (1 - (value - i).abs()).clamp(0.0, 1.0),
>                               style: labelStyle,
>                             ),
>                           ),
>                         ],
>                       ],
>                     ),
>                     PositionedDirectional(
>                       start: center - underlineWidth / 2,
>                       bottom: 0,
>                       width: underlineWidth,
>                       height: 2,
>                       child: IgnorePointer(
>                         child: DecoratedBox(
>                           decoration: BoxDecoration(
>                             color: AppColors.accent,
>                             borderRadius: BorderRadius.circular(1),
>                           ),
>                         ),
>                       ),
>                     ),
>                   ],
>                 );
>               },
>             ),
>           ),
>         );
>       },
>     );
>   }
>
>
>   Widget _label(
>     BuildContext context, {
>     required int index,
>     required bool selected,
>     required double emphasis,
>     required TextStyle style,
>   }) {
>     final color = Color.lerp(
>       AppColors.textMuted,
>       AppColors.textPrimary,
>       emphasis,
>     )!;
>
>
>     void activate() {
>       if (selected) return;
>       Haptics.selection();
>       onTap(index);
>     }
>
>
>     return Semantics(
>       label: labels[index],
>       button: true,
>       selected: selected,
>       onTap: activate,
>       excludeSemantics: true,
>       child: Material(
>         type: MaterialType.transparency,
>         child: InkWell(
>           onTap: activate,
>           borderRadius: BorderRadius.circular(AppRadius.sm),
>           splashFactory: NoSplash.splashFactory,
>           child: ConstrainedBox(
>             constraints: const BoxConstraints(
>               minHeight: _minimumHeight,
>             ),
>             child: Padding(
>               padding: const EdgeInsets.fromLTRB(
>                 _horizontalPadding,
>                 8,
>                 _horizontalPadding,
>                 12,
>               ),
>               child: Text(
>                 labels[index],
>                 maxLines: 1,
>                 overflow: TextOverflow.ellipsis,
>                 textAlign: TextAlign.center,
>                 style: style.copyWith(color: color),
>               ),
>             ),
>           ),
>         ),
>       ),
>     );
>   }
> }
> Why an underline instead of nothing?
>
> Two adjacent text labels can otherwise resemble a heading and a secondary action. A short underline establishes navigation without recreating another large container.
>
> It is intentionally 24 px wide, not a line spanning the whole label.
>
> 2. Update MainLayout: neutral background and a clean header
>
> A. Replace the browsing ambient layer
>
> File: lib/main.dart
>
> Replace the first Positioned.fill containing the _currentTrack listener and AmbientBackground with:
>
> dart
>
> const Positioned.fill(
>   child: ColoredBox(color: AppColors.background),
> ),
> This is important: changing songs should not recolor the Library and Search screens.
>
> Keep AmbientBackground in Now Playing, where it has a direct relationship to the artwork.
>
> Remove this import from main.dart if it has no remaining references:
>
> dart
>
> import 'widgets/ambient_background.dart';
> B. Replace the top header SafeArea
>
> Replace the existing header containing SegmentTabs and assets/logo.png with:
>
> dart
>
> SafeArea(
>   bottom: false,
>   child: Padding(
>     // SegmentTabs supplies 12 px of internal label padding:
>     // 8 + 12 gives a 20 px leading text alignment.
>     padding: const EdgeInsets.fromLTRB(8, 12, 20, 4),
>     child: Align(
>       alignment: AlignmentDirectional.centerStart,
>       child: SegmentTabs(
>         labels: const ['资料库', '搜索'],
>         animation: _pageFraction,
>         fontSize: 26,
>         onTap: _onTabTap,
>       ),
>     ),
>   ),
> ),
> No logo. No extra heading below it. No background capsule.
>
> The remaining space is intentional whitespace, not something that needs filling.
>
> C. Remove duplicate tab haptics and respect reduced motion
>
> Replace _onTabTap:
>
> dart
>
> void _onTabTap(int index) {
>   if (index == _activeTabIndex) return;
>
>
>   // SegmentTabs owns the tap haptic.
>   setState(() => _activeTabIndex = index);
>
>
>   final media = MediaQuery.of(context);
>   final reduceMotion =
>       media.disableAnimations || media.accessibleNavigation;
>
>
>   if (reduceMotion) {
>     _pageController.jumpToPage(index);
>   } else {
>     _pageController.animateToPage(
>       index,
>       duration: AppMotion.fast,
>       curve: AppMotion.standard,
>     );
>   }
> }
> Replace PageView.onPageChanged:
>
> dart
>
> onPageChanged: (index) {
>   if (index == _activeTabIndex) return;
>
>
>   // A swipe did not pass through SegmentTabs, so it owns one haptic.
>   Haptics.selection();
>   setState(() => _activeTabIndex = index);
> },
> This prevents the current multiple haptic events for a single tab tap.
>
> 3. Make the existing cards feel like quiet surfaces
>
> Replace lib/widgets/glass_card.dart completely.
>
> Keep its name and API; there is no need for a new component family.
>
> dart
>
> import 'package:flutter/material.dart';
>
>
> import '../theme/app_theme.dart';
>
>
> /// A quiet elevated surface.
> ///
> /// Retains the existing GlassCard API, but deliberately avoids
> /// gradients, blur, and decorative highlights.
> class GlassCard extends StatelessWidget {
>   final Widget child;
>   final EdgeInsetsGeometry? padding;
>   final double borderRadius;
>
>
>   const GlassCard({
>     super.key,
>     required this.child,
>     this.padding,
>     this.borderRadius = AppRadius.md,
>   });
>
>
>   @override
>   Widget build(BuildContext context) {
>     return Container(
>       padding: padding ?? const EdgeInsets.all(12),
>       decoration: BoxDecoration(
>         color: AppColors.backgroundElevated,
>         borderRadius: BorderRadius.circular(borderRadius),
>         border: Border.all(color: AppColors.hairline),
>       ),
>       child: child,
>     );
>   }
> }
> A subtle border is enough separation. Artwork should be the richest surface on the page.
>
> 4. Redesign the Library quick-access cards
>
> The existing cards have colored icon tiles, gradients, glowing play buttons, and extra vertical space. They behave like promotional cards rather than parts of a personal library.
>
> File: lib/screens/home_screen.dart
>
> Replace _quickCard with the following. It preserves the existing parameters, including gradient, so your call sites do not need to change immediately.
>
> dart
>
> Widget _quickCard({
>   required IconData icon,
>   required List<Color> gradient,
>   required String title,
>   required String subtitle,
>   required VoidCallback onTap,
>   required List<Track> Function() tracks,
>   String? cover,
> }) {
>   final hasCover = cover != null && cover.isNotEmpty;
>
> *[end of received text — generation errored at this point; see M4 for the
> complete rewrite]*

---

# M4 — New-UI complete rewrite

*Context: after M3 errored, Astra regenerated a complete message for the
same "new, improved UI" request.*

> Yes. The top navigation is one of the first things I would change. Right now, large labels inside a pink pill, plus a separate logo, make it feel like a filter control rather than the app’s primary navigation.
>
> I would give BiliBeat a more editorial design:
>
> Plain, left-aligned navigation: 资料库 / 搜索, without a surrounding pill.
> No decorative logo in the navigation row.
> Neutral browsing background: artwork provides the color.
> A quieter mini-player: artwork, title, and clear transport controls—not another glowing centerpiece.
> One accent treatment: flat pink for important actions.
> Consistent spacing: 20 px page margins and fewer nested borders.
> Marquee stays.
> I cannot honestly promise a “perfect” result without seeing the running app, but I can give you a coherent implementation rather than more abstract advice.
>
> Below is a direct UI patch set against your existing interfaces. It does not introduce a parallel component system or require new packages.
>
> 1. Replace lib/widgets/segment_tabs.dart
>
> This removes the measured sliding pill entirely.
>
> The labels use their natural widths rather than dividing the header into two large equal buttons. Selection is expressed through text contrast and a small underline. The existing PageController/TabController animation still drives the appearance.
>
> It also removes the first-frame measurement retry and gives each label a minimum 48 px target.
>
> dart
>
> import 'package:flutter/material.dart';
>
>
> import '../theme/app_theme.dart';
> import '../theme/haptics.dart';
>
>
> /// Quiet, text-led navigation.
> ///
> /// Labels keep their natural widths. Selection is communicated through
> /// contrast and a short underline, rather than a filled segmented pill.
> ///
> /// Works with the existing PageController animation adapter and with
> /// TabController.animation.
> class SegmentTabs extends StatelessWidget {
>   final List<String> labels;
>   final Animation<double> animation;
>   final ValueChanged<int> onTap;
>   final double fontSize;
>
>
>   const SegmentTabs({
>     super.key,
>     required this.labels,
>     required this.animation,
>     required this.onTap,
>     this.fontSize = 23,
>   });
>
>
>   @override
>   Widget build(BuildContext context) {
>     if (labels.isEmpty) return const SizedBox.shrink();
>
>
>     return AnimatedBuilder(
>       animation: animation,
>       builder: (context, _) {
>         final value = animation.value
>             .clamp(0.0, (labels.length - 1).toDouble())
>             .toDouble();
>
>
>         final selectedIndex = value.round();
>
>
>         return Material(
>           type: MaterialType.transparency,
>           child: Row(
>             mainAxisSize: MainAxisSize.min,
>             crossAxisAlignment: CrossAxisAlignment.start,
>             children: [
>               for (var index = 0; index < labels.length; index++) ...[
>                 if (index > 0) const SizedBox(width: 24),
>                 Flexible(
>                   fit: FlexFit.loose,
>                   child: _label(
>                     context,
>                     index: index,
>                     value: value,
>                     selected: selectedIndex == index,
>                   ),
>                 ),
>               ],
>             ],
>           ),
>         );
>       },
>     );
>   }
>
>
>   Widget _label(
>     BuildContext context, {
>     required int index,
>     required double value,
>     required bool selected,
>   }) {
>     final emphasis =
>         (1.0 - (value - index).abs()).clamp(0.0, 1.0).toDouble();
>
>
>     final color = Color.lerp(
>       AppColors.textMuted,
>       AppColors.textPrimary,
>       emphasis,
>     )!;
>
>
>     return Semantics(
>       button: true,
>       selected: selected,
>       label: labels[index],
>       child: Tooltip(
>         message: labels[index],
>         child: InkWell(
>           borderRadius: BorderRadius.circular(AppRadius.sm),
>           onTap: () {
>             if (!selected) Haptics.selection();
>             onTap(index);
>           },
>           child: ConstrainedBox(
>             constraints: const BoxConstraints(
>               minWidth: 48,
>               minHeight: 52,
>             ),
>             child: Padding(
>               padding: const EdgeInsets.symmetric(vertical: 8),
>               child: Column(
>                 mainAxisSize: MainAxisSize.min,
>                 crossAxisAlignment: CrossAxisAlignment.start,
>                 children: [
>                   ExcludeSemantics(
>                     child: Text(
>                       labels[index],
>                       maxLines: 1,
>                       overflow: TextOverflow.ellipsis,
>                       style: AppTypography.titleLarge.copyWith(
>                         fontSize: fontSize,
>                         height: 1.2,
>                         fontWeight: FontWeight.w700,
>                         letterSpacing: -0.4,
>                         color: color,
>                       ),
>                     ),
>                   ),
>                   const SizedBox(height: 9),
>                   Opacity(
>                     opacity: emphasis,
>                     child: Container(
>                       width: 18,
>                       height: 2,
>                       decoration: BoxDecoration(
>                         color: AppColors.accent,
>                         borderRadius: BorderRadius.circular(1),
>                       ),
>                     ),
>                   ),
>                 ],
>               ),
>             ),
>           ),
>         ),
>       ),
>     );
>   }
> }
> Why this feels more natural: these now read as destinations, not two settings inside a segmented control. The small underline provides a stable selection cue without becoming the visual centerpiece.
>
> 2. Update the application shell in lib/main.dart
>
> Keep the existing state, subscriptions, playback methods, and route-opening logic.
>
> Replace _onTabTap and build inside _MainLayoutState with the following.
>
> This version:
>
> Removes the global artwork-colored browsing background.
> Removes the navigation logo.
> Keeps your two-page swipe navigation.
> Preserves the playlist overlay and permanently accessible mini-player.
> Makes Back close the playlist overlay.
> Removes duplicate navigation haptics.
> Respects reduced motion for tab changes and playlist entrance.
> Replace _onTabTap
>
> dart
>
> void _onTabTap(int index) {
>   if (index == _activeTabIndex) return;
>
>
>   final media = MediaQuery.of(context);
>   final reduceMotion =
>       media.disableAnimations || media.accessibleNavigation;
>
>
>   setState(() => _activeTabIndex = index);
>
>
>   if (reduceMotion) {
>     _pageController.jumpToPage(index);
>   } else {
>     _pageController.animateToPage(
>       index,
>       duration: AppMotion.fast,
>       curve: AppMotion.standard,
>     );
>   }
> }
> Replace build
>
> dart
>
> @override
> Widget build(BuildContext context) {
>   final media = MediaQuery.of(context);
>   final reduceMotion =
>       media.disableAnimations || media.accessibleNavigation;
>   final dockedHeight = MiniPlayer.totalHeight(context);
>   final activePlaylist = _activePlaylistSheet;
>
>
>   return PopScope(
>     canPop: activePlaylist == null,
>     onPopInvokedWithResult: (didPop, result) {
>       if (didPop || _activePlaylistSheet == null) return;
>       setState(() => _activePlaylistSheet = null);
>     },
>     child: Scaffold(
>       backgroundColor: AppColors.background,
>       body: Stack(
>         children: [
>           // Main browsing surface.
>           Column(
>             children: [
>               SafeArea(
>                 bottom: false,
>                 child: Padding(
>                   padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
>                   child: Align(
>                     alignment: AlignmentDirectional.centerStart,
>                     child: SegmentTabs(
>                       labels: const ['资料库', '搜索'],
>                       animation: _pageFraction,
>                       onTap: _onTabTap,
>                     ),
>                   ),
>                 ),
>               ),
>
>
>               Expanded(
>                 child: PageView(
>                   controller: _pageController,
>                   onPageChanged: (index) {
>                     if (_activeTabIndex == index) return;
>                     setState(() => _activeTabIndex = index);
>                   },
>                   children: [
>                     RepaintBoundary(
>                       child: ValueListenableBuilder<List<Track>>(
>                         valueListenable: _recentlyPlayed,
>                         builder: (context, recent, _) {
>                           return HomeScreen(
>                             recentlyPlayed: recent,
>                             onSelectTrack: _onPlayTrackAndExpand,
>                             onPlayOnly: _onPlayTrackOnly,
>                             onPlayCollection: _playCollection,
>                             onOpenPlaylist: (playlist) {
>                               FocusManager.instance.primaryFocus?.unfocus();
>                               setState(
>                                 () => _activePlaylistSheet = playlist,
>                               );
>                             },
>                           );
>                         },
>                       ),
>                     ),
>                     RepaintBoundary(
>                       child: SearchScreen(
>                         onSelectTrack: _onSearchSelectTrack,
>                         onPlayOnly: _onPlayTrackOnly,
>                       ),
>                     ),
>                   ],
>                 ),
>               ),
>
>
>               // The shell owns mini-player clearance.
>               SizedBox(height: dockedHeight),
>             ],
>           ),
>
>
>           // Playlist surface. The mini-player stays accessible below it.
>           if (activePlaylist != null)
>             Positioned(
>               left: 0,
>               right: 0,
>               top: 0,
>               bottom: dockedHeight,
>               child: BlockSemantics(
>                 child: TweenAnimationBuilder<double>(
>                   key: ValueKey(activePlaylist.id),
>                   tween: Tween(begin: 0.0, end: 1.0),
>                   duration: reduceMotion
>                       ? Duration.zero
>                       : AppMotion.fast,
>                   curve: AppMotion.standard,
>                   builder: (context, value, child) {
>                     return Opacity(
>                       opacity: value,
>                       child: Transform.translate(
>                         offset: Offset(0, (1 - value) * 20),
>                         child: child,
>                       ),
>                     );
>                   },
>                   child: Stack(
>                     children: [
>                       Positioned.fill(
>                         child: GestureDetector(
>                           behavior: HitTestBehavior.opaque,
>                           onTap: () {
>                             setState(() => _activePlaylistSheet = null);
>                           },
>                           child: const ColoredBox(
>                             color: AppColors.black45,
>                           ),
>                         ),
>                       ),
>                       Align(
>                         alignment: Alignment.bottomCenter,
>                         child: PlaylistDetailSheet(
>                           playlist: activePlaylist,
>                           onSelectTrack: _onPlayTrackAndExpand,
>                           onPlayOnly: _onPlayTrackOnly,
>                           onPlayCollection: _playCollection,
>                           onPlaylistUpdated: _loadHistory,
>                           onClose: () {
>                             setState(() => _activePlaylistSheet = null);
>                           },
>                         ),
>                       ),
>                     ],
>                   ),
>                 ),
>               ),
>             ),
>
>
>           // One persistent listening surface.
>           Positioned(
>             left: 0,
>             right: 0,
>             bottom: 0,
>             child: ListenableBuilder(
>               key: _miniPlayerKey,
>               listenable: Listenable.merge([
>                 _currentTrack,
>                 _isPlaying,
>               ]),
>               builder: (context, _) {
>                 return MiniPlayer(
>                   currentTrack: _currentTrack.value,
>                   isPlaying: _isPlaying.value,
>                   positionNotifier: _positionNotifier,
>                   durationNotifier: _durationNotifier,
>                   onPlayPause: () {
>                     if (_isPlaying.value) {
>                       _audioHandler.pause();
>                     } else {
>                       _audioHandler.play();
>                     }
>                   },
>                   onNext: _audioHandler.skipToNext,
>                   onPrevious: _audioHandler.skipToPrevious,
>                   onSeek: _audioHandler.seek,
>                   onTap: _openNowPlaying,
>                 );
>               },
>             ),
>           ),
>         ],
>       ),
>     ),
>   );
> }
> Import cleanup
>
> Remove from main.dart:
>
> dart
>
> import 'widgets/ambient_background.dart';
> Keep AmbientBackground in NowPlayingSheet; the full player is where artwork-derived atmosphere belongs.
>
> Also fix the expansion origin
>
> Inside _openNowPlaying, replace:
>
> dart
>
> final from = _miniPlayerRect();
> with:
>
> dart
>
> final from = focused.id == _audioHandler.currentTrack?.id
>     ? _miniPlayerRect()
>     : null;
> An unrelated search preview should not appear to grow out of the currently playing song’s mini-player.
>
> ---

> 3. Replace lib/widgets/mini_player.dart
>
> This is a complete replacement, keeping the existing constructor interface and totalHeight/cardRadius APIs.
>
> Design changes
>
> Flat elevated surface, no pink glow.
> 48 px transport targets.
> Artwork and title lead.
> Progress is display-only; seeking remains in the full player.
> No horizontal swipe-to-skip, avoiding accidental track changes while interacting near progress.
> Text scaling increases the mini-player height.
> Custom controls become real Material buttons with tooltips and keyboard/screen-reader support.
> onPrevious and onSeek remain accepted so your current call sites do not break, but this compact design deliberately does not expose those gestures.
>
> dart
>
> import 'package:flutter/material.dart';
>
>
> import '../models/track.dart';
> import '../theme/app_theme.dart';
> import '../theme/haptics.dart';
> import 'cached_cover_image.dart';
> import 'marquee_text.dart';
>
>
> /// A quiet, persistent listening surface.
> ///
> /// Progress is intentionally display-only. Seeking lives in the full
> /// player, where it can have a proper accessible interaction target.
> class MiniPlayer extends StatelessWidget {
>   final Track? currentTrack;
>   final bool isPlaying;
>
>
>   final ValueNotifier<Duration> positionNotifier;
>   final ValueNotifier<Duration> durationNotifier;
>
>
>   final VoidCallback onPlayPause;
>   final VoidCallback onNext;
>   final VoidCallback? onPrevious;
>   final VoidCallback onTap;
>   final ValueChanged<Duration>? onSeek;
>
>
>   const MiniPlayer({
>     super.key,
>     required this.currentTrack,
>     required this.isPlaying,
>     required this.positionNotifier,
>     required this.durationNotifier,
>     required this.onPlayPause,
>     required this.onNext,
>     this.onPrevious,
>     required this.onTap,
>     this.onSeek,
>   });
>
>
>   static const double contentHeight = 76;
>   static const double _artSize = 48;
>
>
>   static const BorderRadius cardRadius = BorderRadius.vertical(
>     top: Radius.circular(AppRadius.md),
>   );
>
>
>   static double bottomInset(BuildContext context) {
>     final inset = MediaQuery.of(context).padding.bottom;
>     return inset > 0 ? inset : 8;
>   }
>
>
>   static double _contentHeightFor(BuildContext context) {
>     final scaler = MediaQuery.textScalerOf(context);
>
>
>     final additionalHeight =
>         (scaler.scale(15) - 15) * 1.3 +
>         (scaler.scale(12) - 12) * 1.35;
>
>
>     return contentHeight +
>         (additionalHeight > 0 ? additionalHeight : 0);
>   }
>
>
>   static double totalHeight(BuildContext context) {
>     return _contentHeightFor(context) + bottomInset(context);
>   }
>
>
>   @override
>   Widget build(BuildContext context) {
>     final track = currentTrack;
>
>
>     return ClipRRect(
>       borderRadius: cardRadius,
>       child: Material(
>         color: AppColors.backgroundElevated,
>         child: DecoratedBox(
>           decoration: const BoxDecoration(
>             borderRadius: cardRadius,
>             border: Border(
>               top: BorderSide(color: AppColors.hairlineStrong),
>             ),
>           ),
>           child: Padding(
>             padding: EdgeInsets.only(
>               bottom: bottomInset(context),
>             ),
>             child: SizedBox(
>               height: _contentHeightFor(context),
>               child: track == null
>                   ? _emptyState()
>                   : _activePlayer(track),
>             ),
>           ),
>         ),
>       ),
>     );
>   }
>
>
>   Widget _emptyState() {
>     return Padding(
>       padding: const EdgeInsets.symmetric(horizontal: 20),
>       child: Row(
>         children: [
>           Container(
>             width: _artSize,
>             height: _artSize,
>             decoration: BoxDecoration(
>               color: AppColors.surfaceCard,
>               borderRadius: BorderRadius.circular(AppRadius.sm),
>             ),
>             child: const Icon(
>               Icons.music_note_rounded,
>               color: AppColors.textMuted,
>               size: 22,
>             ),
>           ),
>           const SizedBox(width: 12),
>           Expanded(
>             child: Text(
>               '选择一首，开始聆听',
>               maxLines: 2,
>               overflow: TextOverflow.ellipsis,
>               style: AppTypography.bodyMedium,
>             ),
>           ),
>         ],
>       ),
>     );
>   }
>
>
>   Widget _activePlayer(Track track) {
>     return Stack(
>       children: [
>         Padding(
>           padding: const EdgeInsets.fromLTRB(20, 3, 12, 5),
>           child: Row(
>             children: [
>               Expanded(
>                 child: Semantics(
>                   button: true,
>                   label: '打开播放器：${track.title}，${track.uploader}',
>                   child: ExcludeSemantics(
>                     child: InkWell(
>                       borderRadius: BorderRadius.circular(AppRadius.sm),
>                       onTap: onTap,
>                       child: Padding(
>                         padding: const EdgeInsets.symmetric(vertical: 8),
>                         child: Row(
>                           children: [
>                             ClipRRect(
>                               borderRadius: BorderRadius.circular(
>                                 AppRadius.sm,
>                               ),
>                               child: CachedCoverImage(
>                                 url: track.coverUrl,
>                                 width: _artSize,
>                                 height: _artSize,
>                               ),
>                             ),
>                             const SizedBox(width: 12),
>                             Expanded(
>                               child: Column(
>                                 mainAxisSize: MainAxisSize.min,
>                                 crossAxisAlignment: CrossAxisAlignment.start,
>                                 children: [
>                                   MarqueeText(
>                                     text: track.title,
>                                     style: AppTypography.body.copyWith(
>                                       height: 1.3,
>                                       fontWeight: FontWeight.w600,
>                                     ),
>                                   ),
>                                   const SizedBox(height: 3),
>                                   Text(
>                                     track.uploader,
>                                     maxLines: 1,
>                                     overflow: TextOverflow.ellipsis,
>                                     style: AppTypography.caption.copyWith(
>                                       height: 1.35,
>                                     ),
>                                   ),
>                                 ],
>                               ),
>                             ),
>                           ],
>                         ),
>                       ),
>                     ),
>                   ),
>                 ),
>               ),
>               const SizedBox(width: 8),
>               _transportButton(
>                 tooltip: isPlaying ? '暂停' : '播放',
>                 icon: isPlaying
>                     ? Icons.pause_rounded
>                     : Icons.play_arrow_rounded,
>                 primary: true,
>                 onPressed: () {
>                   Haptics.light();
>                   onPlayPause();
>                 },
>               ),
>               _transportButton(
>                 tooltip: '下一首',
>                 icon: Icons.skip_next_rounded,
>                 onPressed: () {
>                   Haptics.selection();
>                   onNext();
>                 },
>               ),
>             ],
>           ),
>         ),
>
>
>         Positioned(
>           left: 20,
>           right: 20,
>           bottom: 0,
>           child: IgnorePointer(
>             child: ExcludeSemantics(
>               child: _MiniProgress(
>                 positionNotifier: positionNotifier,
>                 durationNotifier: durationNotifier,
>               ),
>             ),
>           ),
>         ),
>       ],
>     );
>   }
>
>
>   Widget _transportButton({
>     required String tooltip,
>     required IconData icon,
>     required VoidCallback onPressed,
>     bool primary = false,
>   }) {
>     return SizedBox(
>       width: 48,
>       height: 48,
>       child: IconButton(
>         tooltip: tooltip,
>         onPressed: onPressed,
>         padding: EdgeInsets.zero,
>         icon: Icon(
>           icon,
>           size: primary ? 32 : 27,
>           color: primary
>               ? AppColors.textPrimary
>               : AppColors.textSecondary,
>         ),
>       ),
>     );
>   }
> }
>
>
> class _MiniProgress extends StatelessWidget {
>   final ValueNotifier<Duration> positionNotifier;
>   final ValueNotifier<Duration> durationNotifier;
>
>
>   const _MiniProgress({
>     required this.positionNotifier,
>     required this.durationNotifier,
>   });
>
>
>   @override
>   Widget build(BuildContext context) {
>     return AnimatedBuilder(
>       animation: Listenable.merge([
>         positionNotifier,
>         durationNotifier,
>       ]),
>       builder: (context, _) {
>         final total = durationNotifier.value.inMilliseconds;
>
>
>         final fraction = total <= 0
>             ? 0.0
>             : (positionNotifier.value.inMilliseconds / total)
>                 .clamp(0.0, 1.0)
>                 .toDouble();
>
>
>         return ClipRRect(
>           borderRadius: BorderRadius.circular(1),
>           child: SizedBox(
>             height: 2,
>             child: Stack(
>               fit: StackFit.expand,
>               children: [
>                 const ColoredBox(color: AppColors.hairline),
>                 Align(
>                   alignment: Alignment.centerLeft,
>                   child: FractionallySizedBox(
>                     widthFactor: fraction,
>                     heightFactor: 1,
>                     child: const ColoredBox(
>                       color: AppColors.accent,
>                     ),
>                   ),
>                 ),
>               ],
>             ),
>           ),
>         );
>       },
>     );
>   }
> }
> Important: this is a visual replacement, not a fix for the playback preparation-state issue from the earlier review. Until that is fixed, the mini-player still receives only currentTrack and isPlaying.
>
> 4. Replace lib/widgets/glass_card.dart
>
> The name and API stay the same. Visually, it becomes a restrained surface rather than simulated glass.
>
> dart
>
> import 'package:flutter/material.dart';
>
>
> import '../theme/app_theme.dart';
>
>
> /// A restrained grouping surface.
> ///
> /// Keep this for grouped controls and collection shortcuts.
> /// Track lists should continue using TrackRow.
> class GlassCard extends StatelessWidget {
>   final Widget child;
>   final EdgeInsetsGeometry? padding;
>   final double borderRadius;
>
>
>   const GlassCard({
>     super.key,
>     required this.child,
>     this.padding,
>     this.borderRadius = AppRadius.md,
>   });
>
>
>   @override
>   Widget build(BuildContext context) {
>     return Container(
>       padding: padding ?? const EdgeInsets.all(12),
>       decoration: BoxDecoration(
>         color: AppColors.surfaceCard,
>         borderRadius: BorderRadius.circular(borderRadius),
>         border: Border.all(color: AppColors.hairline),
>       ),
>       child: child,
>     );
>   }
> }
> 5. Make Search look like part of the new navigation
>
> File: lib/screens/search_screen.dart
>
> Replace the first GlassCard(...) in _header()—the search input—with this:
>
> dart
>
> GlassCard(
>   borderRadius: AppRadius.md,
>   padding: const EdgeInsets.only(left: 16, right: 4),
>   child: ConstrainedBox(
>     constraints: const BoxConstraints(minHeight: 56),
>     child: Row(
>       children: [
>         const Icon(
>           Icons.search_rounded,
>           color: AppColors.textMuted,
>           size: 22,
>         ),
>         const SizedBox(width: 12),
>         Expanded(
>           child: TextField(
>             controller: _searchController,
>             focusNode: _focusNode,
>             textInputAction: TextInputAction.search,
>             textCapitalization: TextCapitalization.none,
>             autocorrect: false,
>             style: AppTypography.body,
>             cursorColor: AppColors.accent,
>             onSubmitted: _performSearch,
>             decoration: InputDecoration(
>               isDense: true,
>               hintText: '歌曲、UP 主或 BV 链接',
>               hintStyle: AppTypography.body.copyWith(
>                 color: AppColors.textFaint,
>               ),
>               contentPadding: const EdgeInsets.symmetric(vertical: 16),
>               border: InputBorder.none,
>               enabledBorder: InputBorder.none,
>               focusedBorder: InputBorder.none,
>             ),
>           ),
>         ),
>         SizedBox(
>           width: 48,
>           height: 48,
>           child: _searchController.text.isEmpty
>               ? null
>               : IconButton(
>                   onPressed: _showRecommendations,
>                   tooltip: '清除搜索',
>                   icon: const Icon(
>                     Icons.close_rounded,
>                     size: 20,
>                     color: AppColors.textMuted,
>                   ),
>                 ),
>         ),
>       ],
>     ),
>   ),
> ),
> This keeps the field’s size stable as text appears.
>
> Make row actions more legible
>
> In _buildTrackTile, replace the trailing Add IconButton with:
>
> dart
>
> IconButton(
>   tooltip: '更多选项',
>   padding: EdgeInsets.zero,
>   constraints: const BoxConstraints(
>     minWidth: 48,
>     minHeight: 48,
>   ),
>   icon: const Icon(
>     Icons.more_horiz_rounded,
>     color: AppColors.textMuted,
>     size: 24,
>   ),
>   onPressed: () {
>     TrackOptionsMenu.show(
>       context,
>       track,
>       onTrackChanged: () {
>         if (mounted) setState(() {});
>       },
>     );
>   },
> ),
> The download action remains directly available. The overflow menu contains Favorite and Add to Playlist, using your existing menu.
>
> Note: retain accurate deletion wording in that menu until download deletion is separated from playlist removal.
>
> 6. Remove the oversized trailing gaps
>
> Your shell already reserves the mini-player’s height. Home and Search reserve it again.
>
> That creates a visible dead area at the bottom of the page.
>
> Home
>
> In home_screen.dart, change:
>
> dart
>
> padding: EdgeInsets.fromLTRB(
>   20, 0, 20, MiniPlayer.totalHeight(context) + 24),
> to:
>
> dart
>
> padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
> Search
>
> Replace the final spacer with:
>
> dart
>
> const SliverToBoxAdapter(
>   child: SizedBox(height: 24),
> ),
> Remove the mini_player.dart import from both screens when it is no longer used.
>
> Keep the existing 20 px top padding in the two screens for this first pass; it now separates the understated navigation from the first content surface.
>
> ---

> 7. Quiet the Library shortcuts
>
> The green gradient Downloaded card, pink Favorite card, and glowing play buttons currently compete with actual artwork.
>
> Replace _playCollectionButton in home_screen.dart
>
> dart
>
> Widget _playCollectionButton(List<Track> Function() tracks) {
>   final enabled =
>       widget.onPlayCollection != null && tracks().isNotEmpty;
>
>
>   return SizedBox(
>     width: 48,
>     height: 48,
>     child: IconButton(
>       tooltip: '播放全部',
>       onPressed: !enabled
>           ? null
>           : () {
>               final queue = List<Track>.of(tracks());
>               if (queue.isEmpty) return;
>
>
>               Haptics.light();
>               widget.onPlayCollection?.call(queue);
>             },
>       icon: Icon(
>         Icons.play_arrow_rounded,
>         size: 28,
>         color: enabled
>             ? AppColors.textPrimary
>             : AppColors.textFaint,
>       ),
>     ),
>   );
> }
> This also fixes the current silent no-op appearance for empty collections.
>
> Neutralize shortcut placeholder artwork
>
> Inside _quickCard, replace the placeholder’s decoration and icon with:
>
> dart
>
> decoration: BoxDecoration(
>   color: AppColors.white06,
>   borderRadius: BorderRadius.circular(AppRadius.sm),
> ),
> child: Icon(
>   icon,
>   color: icon == Icons.favorite_rounded
>       ? AppColors.accent
>       : AppColors.textSecondary,
>   size: 22,
> ),
> Then remove the unused gradient parameter from _quickCard and remove its two named arguments at the Downloaded/Favorites call sites.
>
> The card still has a distinct identity, but the icons no longer pretend to be album artwork.
>
> Keep Recently Played titles readable
>
> Replace the static title Text inside the Recently Played rail with:
>
> dart
>
> MarqueeText(
>   text: track.title,
>   phase: (index % 5) / 5,
>   style: AppTypography.body.copyWith(
>     fontSize: 14,
>     fontWeight: FontWeight.w600,
>   ),
> ),
> Keep the uploader line static.
>
> 8. Match Now Playing to the new design
>
> I would not replace your full player wholesale before fixing its state ownership. These targeted changes make it visually consistent without changing its playback behavior.
>
> A. Replace _topBar() in now_playing_sheet.dart
>
> dart
>
> Widget _topBar() {
>   return Padding(
>     padding: const EdgeInsets.symmetric(horizontal: 12),
>     child: Row(
>       children: [
>         SizedBox(
>           width: 48,
>           height: 48,
>           child: IconButton(
>             tooltip: '收起',
>             onPressed: () => Navigator.of(context).maybePop(),
>             icon: const Icon(
>               Icons.keyboard_arrow_down_rounded,
>               color: AppColors.textSecondary,
>               size: 30,
>             ),
>           ),
>         ),
>         Expanded(
>           child: Text(
>             _isActive ? '当前曲目' : '曲目详情',
>             textAlign: TextAlign.center,
>             style: AppTypography.caption.copyWith(
>               color: AppColors.textSecondary,
>               letterSpacing: 0.4,
>             ),
>           ),
>         ),
>         SizedBox(
>           width: 48,
>           height: 48,
>           child: IconButton(
>             tooltip: _showLyrics ? '显示封面' : '显示歌词',
>             onPressed: !_isActive
>                 ? null
>                 : () {
>                     Haptics.selection();
>                     setState(() => _showLyrics = !_showLyrics);
>                   },
>             icon: Icon(
>               _showLyrics
>                   ? Icons.lyrics_rounded
>                   : Icons.lyrics_outlined,
>               color: _showLyrics && _isActive
>                   ? AppColors.accent
>                   : AppColors.textMuted,
>               size: 22,
>             ),
>           ),
>         ),
>       ],
>     ),
>   );
> }
> The center now communicates useful state rather than repeating branding.
>
> B. Flatten the main play button
>
> Inside _circleButton, replace the Container decoration with:
>
> dart
>
> decoration: BoxDecoration(
>   shape: BoxShape.circle,
>   color: filled ? AppColors.accent : AppColors.white12,
>   border: filled
>       ? null
>       : Border.all(color: AppColors.hairlineStrong),
> ),
> Remove the gradient and boxShadow.
>
> C. Make artwork motion subtler
>
> Inside _albumArt, change the AnimatedScale properties to:
>
> dart
>
> scale: (_isActive && _isPlaying) ? 1.0 : 0.96,
> duration: MediaQuery.of(context).disableAnimations ||
>         MediaQuery.of(context).accessibleNavigation
>     ? Duration.zero
>     : AppMotion.base,
> curve: AppMotion.standard,
> A 10% size change plus a spring makes the artwork feel more animated than necessary. A 4% transition is enough to suggest a paused state.
>
> D. Reduce the atmosphere
>
> In ambient_background.dart, change the radial gradient’s first two colors from:
>
> dart
>
> c.withValues(alpha: 0.40),
> c.withValues(alpha: 0.15),
> to:
>
> dart
>
> c.withValues(alpha: 0.20),
> c.withValues(alpha: 0.07),
> Since the browsing shell no longer uses this background, the tint becomes a restrained full-player treatment.
>
> What the result should feel like
>
> The visual hierarchy becomes:
>
> text
>
> 资料库    搜索
> ━━
>
>
> ┌────────────────┐  ┌────────────────┐
> │ Downloaded   ▶ │  │ Favorites    ▶ │
> │ 128 tracks     │  │ 64 tracks       │
> └────────────────┘  └────────────────┘
>
>
> Playlists
> [ artwork ] Collection name        ▶
>             24 tracks
>
>
> Recently played
> [ artwork ] [ artwork ] [ artwork ]
>
>
>
>
> ─────────────────────────────────────
> [ art ] Song title              ❚❚  ▸|
>         Uploader
> ──────── subtle progress ────────────
> The biggest difference is not a new decoration. It is less competition between navigation, controls, surfaces, and artwork.
>
> Apply and verify
>
> After these replacements:
>
> Bash
>
> dart format lib
> flutter analyze
> flutter test
> I have not compiled this against your project; the PDF also does not establish your exact Flutter SDK version. These patches use interfaces and modern Flutter APIs already present in your dump.
>
> My strongest recommendation is to ship this quieter navigation and shell first. It gives BiliBeat a recognizable visual identity without adding features or replacing the parts of the app that already work well."

---

# M5 — Product decisions + how to send the technical prompts

*Context: asked to decide the open product questions (deletion semantics,
playback contract, favorite auto-download, feature scope) and say what to
ask next. Astra replied with decisions for the agent and three technical
prompts to send separately.*

> Give the agent these decisions:
>
> ## 1. Deletion semantics
>
> **Default: Remove download.** Delete local audio, but preserve playlist membership, Favorites, metadata, and history.
>
> Provide a separate **Remove from library** action, with confirmation explicitly stating that it removes the download and the track from all playlists, Favorites, and history.
>
> Prevent accidental re-download through playback behavior—not by deleting history:
>
> - History entries may remain visible after removing their download.
> - Tapping a nonlocal history entry opens track details.
> - Only an explicit **Download & play** action starts downloading.
> - Removing a download must not immediately trigger background prefetch of that same track. Coordinate this with the handler; if necessary, initially disable removal of the actively playing/preparing track and explain why.
>
> ## 2. Playback contract
>
> **Use honest, explicit states. No silent download-then-play on a row tap.**
>
> | Action | Behavior |
> |---|---|
> | Tap a downloaded track | Play it; remain in the browsing screen. |
> | Tap a nonlocal track | Open clearly labeled **Track details**, without changing playback. |
> | Tap **Download & play** | Show preparation/progress; play after completion only if that play intent is still current. |
> | Tap the download icon | Download only. |
> | Tap mini-player | Open the current player. |
>
> A later track selection, Pause, or Stop must cancel the earlier **pending autoplay intent**. The download may continue, but its completion must not unexpectedly interrupt playback.
>
> For now, **automatic queue advance should use completed local tracks only**. Do not silently download missing playlist items. Show the playable count when a collection contains nonlocal tracks.
>
> ## 3. Favorite auto-download
>
> **Default: Favorite only.**
>
> Add an explicit preference later:
>
> > Automatically download favorites — **Off by default**
>
> Adding tracks to a playlist should also **not silently download them**. Saving membership and making music available offline are separate actions.
>
> Do not expose the preference until its behavior is implemented and persisted reliably.
>
> ## 4. Feature scope and order
>
> **Do not build all three features now.**
>
> 1. **Phase 1 — Reliability and core UX:** playback ownership, search states, lyric-edit safety, deletion semantics, visible download failures, and the agreed UI cleanup.
> 2. **Phase 2 — Read-only queue:** publish authoritative handler state, then show the current item and upcoming tracks. No drag reordering or queue editing yet.
> 3. **Phase 3 — Download management:** persistent failed items and Retry first; storage controls next. No Cancel button without actual service cancellation.
> 4. **Phase 4 — Sleep timer:** defer until playback is stable; implement in the handler, not a screen timer.
>
> ## Send the three technical prompts separately
>
> **Order: playback → lyrics → queue.** Review and test each patch before sending the next, including any changed interfaces in the following prompt.
>
> Two corrections are important:
>
> ### Playback prompt
>
> Remove:
>
> > “Local files, so play() completes fast.”
>
> That is incorrect. **Local files can load quickly, but `just_audio.play()` returns a playback-lifetime future, not a startup acknowledgment.**
>
> Also replace “release `_isRebuilding` before await `_player.play()`” with:
>
> > “Finish and release the source-preparation critical section independently of the playback-lifetime future. Start playback without awaiting that future inside the preparation path; attach explicit asynchronous error handling and observe playing state through the existing stream.”
>
> Require the agent to examine **all competing native queue mutations**, not just concurrent `_startCurrent` calls. Locking `clear/add/setAudioSource` alone does not protect against prefetch append, trimming, shuffle, or skip operations modifying the same queue. Keep the fix focused, but require a stated serialization/ownership invariant.
>
> ### Lyrics prompt
>
> Add:
>
> > “The commit guard must protect both the visible lyrics and the persistent cache. Checking a revision only before calling an async cache write is insufficient if an older automatic write can still overwrite a newer manual save. Manual edits must target the captured editor track even after playback changes, and must update the visible notifier only if that captured track is still active.”
>
> **You can send the product decisions above directly to the agent and start Phase 1.**

---

# M6 — Prompt 1 implementation: playback ownership and serialization

*Context: the corrected Prompt 1 (playback) was sent; Astra returned this
patch. Its opening line is quoted verbatim below.*

> Send the following to the agent. **The important correction is to separate download preparation from serialized native-queue installation—not merely remove one `await`.**
>
> This patch keeps the existing handler interface, streams, logical playlist, and native sliding window. It adds no queue UI or new playback features.
>
> **I have not compiled this patch.** Run analysis and targeted playback tests after applying it; unchanged baseline tests are not sufficient for these races.
>
> ---
>
> # Playback patch: ownership and serialization
>
> ## Invariant
>
> This implementation establishes:
>
> 1. **All application-side logical queue changes, native source mutations, indexed seeks, and queue re-anchoring run through one asynchronous gate.**
> 2. **Audio downloads run outside that gate.** A slow download cannot block a newer track selection, Pause, or Stop.
> 3. `_startToken` identifies the latest requested track start. A superseded start cannot install another source or release another start’s pending state.
> 4. `_queueRevision` invalidates prefetch plans after the queue/order changes.
> 5. A prefetch has its own ownership ticket. Old cleanup cannot clear a newer prefetch’s ownership.
> 6. `_isRebuilding` means the gate is executing. `_pendingStartToken` additionally suppresses native-index reconciliation while the announced selection and installed source may differ.
> 7. `play()` is launched without awaiting its playback-lifetime future. Its asynchronous errors are observed explicitly. **Only `playerStateStream` writes normal playing state.**
>
> The gate serializes Dart operations; it does **not** freeze native playback. Native transitions are reconciled from source tags, rather than trusting a possibly stale base index.
>
> An operation already awaiting a native mutation cannot cancel that mutation when superseded. It finishes that await, then stops. The newer operation executes afterward through the same gate.
>
> ---
>
> # 1. Add these fields and helpers
>
> Inside `BiliBeatAudioHandler`, retain `_startToken`, `_isRebuilding`, and `_prefetchingId`. Add:
>
> ```dart
> Future<void> _queueGate = Future<void>.value();
>
>
> int _queueRevision = 0;
> int? _pendingStartToken;
>
>
> int _prefetchSerial = 0;
> int? _prefetchOwner;
>
>
> /// Explicit transport intent, independent of native preparation events.
> bool _playRequested = false;
> int _transportToken = 0;
>
>
> bool get _queueTransitioning =>
>     _isRebuilding || _pendingStartToken != null;
> ```
>
> Add these helpers:
>
> ```dart
> /// Never call this from inside another _withQueueGate callback.
> /// Locked helpers below deliberately do not reacquire the gate.
> Future<T> _withQueueGate<T>(Future<T> Function() action) {
>   final result = _queueGate.then<T>((_) async {
>     _isRebuilding = true;
>
>
>     try {
>       return await action();
>     } finally {
>       _isRebuilding = false;
>
>
>       // A pending start may still be downloading outside the gate.
>       // Its logical selection must not be retargeted to the old source.
>       if (_pendingStartToken == null) {
>         _reconcileActiveTrack();
>       }
>     }
>   });
>
>
>   // A failed operation must not poison the serialization chain.
>   _queueGate = result.then<void>(
>     (_) {},
>     onError: (Object error, StackTrace stack) {},
>   );
>
>
>   return result;
> }
>
>
> void _runDetached(Future<void> future, String operation) {
>   unawaited(
>     future.then<void>(
>       (_) {},
>       onError: (Object error, StackTrace stack) {
>         debugPrint('$operation failed: $error\n$stack');
>       },
>     ),
>   );
> }
>
>
> Track? _nativeTrackAt(int index) {
>   if (index < 0 || index >= _queueSource.length) return null;
>
>
>   final source = _queueSource.children[index];
>   if (source is! ja.IndexedAudioSource) return null;
>
>
>   final tag = source.tag;
>   return tag is Track ? tag : null;
> }
>
>
> /// Returns a reusable native index only when the entire native window
> /// agrees with the current logical order.
> ///
> /// Merely finding the requested id is insufficient after shuffle or
> /// replacement of the logical playlist.
> int? _reusableNativeIndex(Track track) {
>   final logicalIndex =
>       _playlist.indexWhere((item) => item.id == track.id);
>
>
>   if (logicalIndex < 0) return null;
>
>
>   for (var nativeIndex = 0;
>       nativeIndex < _queueSource.length;
>       nativeIndex++) {
>     if (_nativeTrackAt(nativeIndex)?.id != track.id) continue;
>
>
>     final base = logicalIndex - nativeIndex;
>     var matches = true;
>
>
>     for (var i = 0; i < _queueSource.length; i++) {
>       final logical = base + i;
>
>
>       if (logical < 0 ||
>           logical >= _playlist.length ||
>           _nativeTrackAt(i)?.id != _playlist[logical].id) {
>         matches = false;
>         break;
>       }
>     }
>
>
>     if (matches) return nativeIndex;
>   }
>
>
>   return null;
> }
>
>
> void _publishPlaybackError(Object error, StackTrace stack) {
>   debugPrint('Playback error: $error\n$stack');
>
>
>   playbackState.add(
>     playbackState.value.copyWith(
>       processingState: AudioProcessingState.error,
>       errorCode: 1,
>       errorMessage: error.toString(),
>     ),
>   );
> }
>
>
> /// Call only while holding the queue gate.
> ///
> /// play() completes when playback pauses/stops/completes, not when audio
> /// starts. Its lifetime must never own the preparation gate.
> void _launchPlayLocked(int startToken) {
>   if (!_playRequested || startToken != _startToken) return;
>
>
>   final transportToken = _transportToken;
>
>
>   void report(Object error, StackTrace stack) {
>     // Old playback futures may settle after another selection or Pause.
>     if (startToken != _startToken ||
>         transportToken != _transportToken) {
>       debugPrint('Superseded playback error: $error');
>       return;
>     }
>
>
>     _playRequested = false;
>     _publishPlaybackError(error, stack);
>   }
>
>
>   try {
>     final lifetime = _player.play();
>
>
>     unawaited(
>       lifetime.then<void>(
>         (_) {},
>         onError: (Object error, StackTrace stack) {
>           report(error, stack);
>         },
>       ),
>     );
>   } catch (error, stack) {
>     report(error, stack);
>   }
> }
> ```
>
> ---
>
> # 2. Replace the native-index listener
>
> In `_initAudioPlayerListeners`, replace the entire existing `_player.currentIndexStream.listen(...)` block with:
>
> ```dart
> _player.currentIndexStream.listen((playerIndex) {
>   if (playerIndex == null || _queueTransitioning) return;
>
>
>   // Read the actual native index when the gate executes. The event's
>   // index may already be stale by then.
>   _runDetached(
>     _withQueueGate<void>(() async {
>       if (_pendingStartToken != null) return;
>       _reconcileActiveTrack();
>     }),
>     'native-index reconciliation',
>   );
> });
> ```
>
> Keep the existing position, duration, and `playerStateStream` subscriptions.
>
> In particular, retain:
>
> ```dart
> _isPlaying = state.playing;
> _playerStateController.add(_isPlaying);
> ```
>
> Do not duplicate those assignments in the startup or transport methods below.
>
> ---
>
> # 3. Add `_requestStart`
>
> This is the shared entry point for track-changing commands. Selection happens inside the gate; downloading happens outside it.
>
> ```dart
> Future<void> _requestStart(
>   Track? Function() select, {
>   bool autoplay = true,
> }) async {
>   final token = ++_startToken;
>
>
>   ++_transportToken;
>   _playRequested = autoplay;
>   _pendingStartToken = token;
>
>
>   try {
>     final active = await _withQueueGate<Track?>(() async {
>       if (token != _startToken) return null;
>
>
>       final selected = select();
>
>
>       if (selected == null) {
>         if (_pendingStartToken == token) {
>           _pendingStartToken = null;
>         }
>         return null;
>       }
>
>
>       ++_queueRevision;
>
>
>       // Invalidate an earlier prefetch, including its cleanup ownership.
>       _prefetchingId = null;
>       _prefetchOwner = null;
>
>
>       _announce(selected);
>       _positionController.add(Duration.zero);
>
>
>       _broadcastState(
>         processingOverride: AudioProcessingState.loading,
>       );
>
>
>       return selected;
>     });
>
>
>     if (active == null || token != _startToken) return;
>
>
>     await _startCurrent(
>       active: active,
>       token: token,
>     );
>   } catch (error, stack) {
>     await _failStart(token, error, stack);
>   }
> }
>
>
> Future<void> _failStart(
>   int token,
>   Object error,
>   StackTrace stack,
> ) async {
>   await _withQueueGate<void>(() async {
>     if (token != _startToken) return;
>
>
>     if (_pendingStartToken == token) {
>       _pendingStartToken = null;
>     }
>
>
>     _playRequested = false;
>
>
>     // If the previous native track still belongs to the logical queue,
>     // restore its authoritative identity before publishing the failure.
>     _reconcileActiveTrack();
>     _broadcastState();
>     _publishPlaybackError(error, stack);
>   });
> }
> ```
>
> **Failure behavior:** if a replaced playlist no longer contains the old native track, this does not invent a mapping or insert that old track into the new playlist. It leaves the failed selection and publishes an error. A complete “restore previous playback session” policy would be a separate product change.
>
> ---
>
> # 4. Replace `playTrack` and `_startCurrent`
>
> ## `playTrack`
>
> ```dart
> Future<void> playTrack(
>   Track track, {
>   List<Track>? newQueue,
> }) {
>   // Snapshot caller-owned lists before waiting for the gate.
>   final replacement =
>       newQueue == null ? null : List<Track>.of(newQueue);
>
>
>   return _requestStart(() {
>     if (replacement != null && replacement.isNotEmpty) {
>       _naturalOrder
>         ..clear()
>         ..addAll(replacement);
>
>
>       _playlist
>         ..clear()
>         ..addAll(replacement);
>
>
>       if (_isShuffle) {
>         _applyShuffleOrder(pinned: track);
>       }
>     }
>
>
>     if (!_playlist.any((item) => item.id == track.id)) {
>       _playlist.insert(0, track);
>       _naturalOrder.insert(0, track);
>     }
>
>
>     _currentIndex =
>         _playlist.indexWhere((item) => item.id == track.id);
>
>
>     return currentTrack;
>   });
> }
> ```
>
> ## `_startCurrent`
>
> Replace the original method completely:
>
> ```dart
> Future<void> _startCurrent({
>   required Track active,
>   required int token,
> }) async {
>   try {
>     // Preserve the fast path for a track already present in a valid
>     // native window. No download or source replacement is necessary.
>     final reused = await _withQueueGate<bool>(() async {
>       if (token != _startToken ||
>           currentTrack?.id != active.id) {
>         return false;
>       }
>
>
>       final nativeIndex = _reusableNativeIndex(active);
>       if (nativeIndex == null) return false;
>
>
>       ++_queueRevision;
>       _queueBaseIndex = _currentIndex - nativeIndex;
>
>
>       await _player.seek(Duration.zero, index: nativeIndex);
>
>
>       if (token != _startToken) return false;
>
>
>       if (_pendingStartToken == token) {
>         _pendingStartToken = null;
>       }
>
>
>       _broadcastState();
>       _launchPlayLocked(token);
>       return true;
>     });
>
>
>     if (token != _startToken) return;
>
>
>     if (reused) {
>       _runDetached(_prefetchNext(), 'prefetch after native seek');
>       return;
>     }
>
>
>     // Intentionally outside the queue gate.
>     final path =
>         await AudioDownloadService.ensureDownloaded(active);
>
>
>     if (token != _startToken) return;
>
>
>     final installed = await _withQueueGate<bool>(() async {
>       if (token != _startToken ||
>           currentTrack?.id != active.id) {
>         return false;
>       }
>
>
>       ++_queueRevision;
>       _prefetchingId = null;
>       _prefetchOwner = null;
>
>
>       await _queueSource.clear();
>       if (token != _startToken) return false;
>
>
>       // Use the latest metadata instance for the selected track.
>       final installing = currentTrack;
>       if (installing == null || installing.id != active.id) {
>         return false;
>       }
>
>
>       await _queueSource.add(
>         ja.AudioSource.file(path, tag: installing),
>       );
>       if (token != _startToken) return false;
>
>
>       _queueBaseIndex = _currentIndex;
>
>
>       await _player.setLoopMode(
>         _loopMode == LoopMode.one
>             ? ja.LoopMode.one
>             : ja.LoopMode.off,
>       );
>       if (token != _startToken) return false;
>
>
>       await _player.setAudioSource(
>         _queueSource,
>         initialIndex: 0,
>         initialPosition: Duration.zero,
>       );
>       if (token != _startToken) return false;
>
>
>       if (_pendingStartToken == token) {
>         _pendingStartToken = null;
>       }
>
>
>       // Source preparation is complete. Launching play does not retain
>       // this gate for the duration of the song.
>       _broadcastState();
>       _launchPlayLocked(token);
>
>
>       return true;
>     });
>
>
>     if (installed && token == _startToken) {
>       _runDetached(_prefetchNext(), 'prefetch after source install');
>     }
>   } catch (error, stack) {
>     await _failStart(token, error, stack);
>   }
> }
> ```
>
> A Pause during downloading leaves `_playRequested == false`, so installation may complete without starting playback.
>
> ---

> # 5. Replace transport methods
>
> ## `play`
>
> ```dart
> @override
> Future<void> play() async {
>   final transport = ++_transportToken;
>   _playRequested = true;
>
>
>   final needsStart = await _withQueueGate<bool>(() async {
>     if (transport != _transportToken || !_playRequested) {
>       return false;
>     }
>
>
>     // Resume intent applies to the pending selection, not the old source.
>     if (_pendingStartToken != null) return false;
>
>
>     final active = currentTrack;
>     if (active == null) {
>       _playRequested = false;
>       return false;
>     }
>
>
>     final nativeIndex = _reusableNativeIndex(active);
>
>
>     if (nativeIndex == null ||
>         nativeIndex != _player.currentIndex) {
>       return true;
>     }
>
>
>     _launchPlayLocked(_startToken);
>     return false;
>   });
>
>
>   if (needsStart &&
>       transport == _transportToken &&
>       _playRequested) {
>     await _requestStart(() => currentTrack);
>   }
> }
> ```
>
> ## `pause`
>
> ```dart
> @override
> Future<void> pause() async {
>   final transport = ++_transportToken;
>   _playRequested = false;
>
>
>   await _withQueueGate<void>(() async {
>     if (transport != _transportToken) return;
>
>
>     await _player.pause();
>
>
>     if (transport == _transportToken) {
>       _broadcastState();
>     }
>   });
> }
> ```
>
> ## `stop`
>
> ```dart
> @override
> Future<void> stop() async {
>   final token = ++_startToken;
>   ++_transportToken;
>
>
>   _playRequested = false;
>
>
>   // Blocks reconciliation of a superseded, partially installed source
>   // until this stop operation reaches the gate.
>   _pendingStartToken = token;
>
>
>   await _withQueueGate<void>(() async {
>     if (token != _startToken) return;
>
>
>     ++_queueRevision;
>     _prefetchingId = null;
>     _prefetchOwner = null;
>
>
>     await _player.stop();
>     if (token != _startToken) return;
>
>
>     _pendingStartToken = null;
>     _broadcastState();
>
>
>     await super.stop();
>   });
> }
> ```
>
> ## `seek`
>
> ```dart
> @override
> Future<void> seek(Duration position) {
>   final token = _startToken;
>
>
>   return _withQueueGate<void>(() async {
>     if (token != _startToken || _pendingStartToken != null) {
>       return;
>     }
>
>
>     await _player.seek(position);
>
>
>     if (token != _startToken) return;
>
>
>     _positionController.add(position);
>     _broadcastState();
>   });
> }
> ```
>
> Seeking during a pending track replacement is ignored rather than seeking the previous source.
>
> ---
>
> # 6. Replace manual skip paths
>
> ## `_playAtIndex`
>
> ```dart
> Future<void> _playAtIndex(int index) {
>   return _requestStart(() {
>     if (index < 0 || index >= _playlist.length) return null;
>
>
>     _currentIndex = index;
>     return currentTrack;
>   });
> }
> ```
>
> ## `skipToQueueItem`
>
> ```dart
> @override
> Future<void> skipToQueueItem(int index) {
>   return _playAtIndex(index);
> }
> ```
>
> ## `skipToNext`
>
> ```dart
> @override
> Future<void> skipToNext() async {
>   if (_playlist.isEmpty) return;
>
>
>   // Resolve the next logical selection inside the serialization gate.
>   var reachedNonLoopingEnd = false;
>
>
>   await _requestStart(() {
>     if (_playlist.isEmpty) return null;
>
>
>     final next = _currentIndex + 1;
>
>
>     if (next < _playlist.length) {
>       _currentIndex = next;
>     } else if (_loopMode != LoopMode.off) {
>       _currentIndex = 0;
>     } else {
>       reachedNonLoopingEnd = true;
>       return null;
>     }
>
>
>     return currentTrack;
>   });
>
>
>   if (reachedNonLoopingEnd) {
>     // This branch needs its own ownership check; see the replacement
>     // below rather than invoking unguarded seek/pause here.
>   }
> }
> ```
>
> **Use this complete version instead** so an old end-of-queue action cannot pause a newer selection:
>
> ```dart
> @override
> Future<void> skipToNext() async {
>   if (_playlist.isEmpty) return;
>
>
>   int? endToken;
>
>
>   await _requestStart(() {
>     if (_playlist.isEmpty) return null;
>
>
>     final next = _currentIndex + 1;
>
>
>     if (next < _playlist.length) {
>       _currentIndex = next;
>     } else if (_loopMode != LoopMode.off) {
>       _currentIndex = 0;
>     } else {
>       endToken = _startToken;
>       return null;
>     }
>
>
>     return currentTrack;
>   });
>
>
>   final token = endToken;
>   if (token == null) return;
>
>
>   await _withQueueGate<void>(() async {
>     if (token != _startToken) return;
>
>
>     _playRequested = false;
>     ++_transportToken;
>
>
>     await _player.seek(Duration.zero);
>     if (token != _startToken) return;
>
>
>     await _player.pause();
>     if (token != _startToken) return;
>
>
>     _positionController.add(Duration.zero);
>     _broadcastState();
>   });
> }
> ```
>
> ## `skipToPrevious`
>
> ```dart
> @override
> Future<void> skipToPrevious() async {
>   if (_playlist.isEmpty) return;
>
>
>   if (_pendingStartToken == null &&
>       _player.position > const Duration(seconds: 3)) {
>     await seek(Duration.zero);
>     return;
>   }
>
>
>   await _requestStart(() {
>     if (_playlist.isEmpty) return null;
>
>
>     final previous = _currentIndex - 1;
>
>
>     if (previous >= 0) {
>       _currentIndex = previous;
>     } else if (_loopMode != LoopMode.off) {
>       _currentIndex = _playlist.length - 1;
>     } else {
>       _currentIndex = 0;
>     }
>
>
>     return currentTrack;
>   });
> }
> ```
>
> **Interaction note:** track-start requests are latest-wins. Several Next commands submitted before their selection callbacks execute can coalesce, rather than counting every press. If preserving every rapid skip press is required, queue the *logical navigation intents* separately from latest-wins source preparation. Do not silently assume the two behaviors are equivalent.
>
> ---
>
> # 7. Replace trimming
>
> ## `_trimQueueAfterCurrent`
>
> ```dart
> Future<void> _trimQueueAfterCurrent() {
>   return _withQueueGate<void>(_trimQueueAfterCurrentLocked);
> }
>
>
> /// Must be called while holding the queue gate.
> Future<void> _trimQueueAfterCurrentLocked() async {
>   ++_queueRevision;
>   _prefetchingId = null;
>   _prefetchOwner = null;
>
>
>   final playerIndex = _player.currentIndex;
>
>
>   if (playerIndex == null) {
>     if (_queueSource.length > 0) {
>       await _queueSource.clear();
>     }
>     return;
>   }
>
>
>   if (_queueSource.length > playerIndex + 1) {
>     await _queueSource.removeRange(
>       playerIndex + 1,
>       _queueSource.length,
>     );
>   }
> }
> ```
>
> ## `_maybeTrimHead`
>
> ```dart
> void _maybeTrimHead() {
>   Future<void> trim() async {
>     await _withQueueGate<void>(() async {
>       if (_pendingStartToken != null) return;
>       if (_queueSource.length <= 3) return;
>
>
>       final playerIndex = _player.currentIndex;
>       if (playerIndex == null || playerIndex <= 0) return;
>
>
>       final excess = _queueSource.length - 3;
>       final count = excess < playerIndex ? excess : playerIndex;
>
>
>       if (count <= 0) return;
>
>
>       ++_queueRevision;
>
>
>       await _queueSource.removeRange(0, count);
>
>
>       // The gate's final reconciliation reads the actual native tag.
>       // This provisional base update keeps bookkeeping sensible even
>       // before that reconciliation runs.
>       _queueBaseIndex += count;
>     });
>
>
>     await _prefetchNext();
>   }
>
>
>   _runDetached(trim(), 'trim native queue head');
> }
> ```
>
> ---
>
> # 8. Replace shuffle and loop setters
>
> Keep `_applyShuffleOrder` unchanged. Its callers below now hold the gate.
>
> ## `setLoopMode`
>
> ```dart
> Future<void> setLoopMode(LoopMode mode) async {
>   await _withQueueGate<void>(() async {
>     if (_loopMode == mode) return;
>
>
>     ++_queueRevision;
>     _loopMode = mode;
>     _loopModeController.add(mode);
>
>
>     await _player.setLoopMode(
>       mode == LoopMode.one
>           ? ja.LoopMode.one
>           : ja.LoopMode.off,
>     );
>
>
>     if (mode == LoopMode.one) {
>       await _trimQueueAfterCurrentLocked();
>     }
>
>
>     _broadcastState();
>   });
>
>
>   _runDetached(_prefetchNext(), 'prefetch after loop change');
> }
> ```
>
> ## `setShuffle`
>
> ```dart
> Future<void> setShuffle(bool on) async {
>   await _withQueueGate<void>(() async {
>     if (_isShuffle == on) return;
>
>
>     // Anchor to the native track before changing its logical order,
>     // unless a deliberate replacement is still pending.
>     if (_pendingStartToken == null) {
>       _reconcileActiveTrack();
>     }
>
>
>     final pinned = currentTrack;
>
>
>     ++_queueRevision;
>     _isShuffle = on;
>     _shuffleController.add(on);
>
>
>     if (_playlist.isEmpty) return;
>
>
>     if (on) {
>       _applyShuffleOrder(pinned: pinned);
>     } else {
>       _playlist
>         ..clear()
>         ..addAll(_naturalOrder);
>     }
>
>
>     _currentIndex = pinned == null
>         ? 0
>         : _playlist.indexWhere((track) => track.id == pinned.id);
>
>
>     if (_currentIndex < 0 && _playlist.isNotEmpty) {
>       _currentIndex = 0;
>     }
>
>
>     await _trimQueueAfterCurrentLocked();
>
>
>     // Old head items are not generally contiguous with the new order.
>     // Retain only the currently installed native item.
>     final nativeIndex = _player.currentIndex;
>
>
>     if (nativeIndex != null && nativeIndex > 0) {
>       await _queueSource.removeRange(0, nativeIndex);
>     }
>
>
>     final actualIndex = _player.currentIndex;
>     final nativeTrack = actualIndex == null
>         ? null
>         : _nativeTrackAt(actualIndex);
>
>
>     if (actualIndex != null &&
>         nativeTrack?.id == currentTrack?.id) {
>       _queueBaseIndex = _currentIndex - actualIndex;
>     }
>
>
>     _broadcastState();
>   });
>
>
>   _runDetached(_prefetchNext(), 'prefetch after shuffle change');
> }
> ```
>
> `cyclePlayMode()` can remain unchanged; it calls these public setters sequentially and does not acquire the gate itself.
>
> ---

> # 9. Replace `_prefetchNext`
>
> Downloads remain outside the gate. Both the selection snapshot and append commit run inside it.
>
> ```dart
> Future<void> _prefetchNext() async {
>   final plan = await _withQueueGate<
>       ({
>         Track track,
>         int revision,
>         int startToken,
>         int owner,
>       })?>(() async {
>     if (_pendingStartToken != null) return null;
>     if (_loopMode == LoopMode.one || autoAdvanceHeld) return null;
>     if (_playlist.isEmpty || _currentIndex < 0) return null;
>
>
>     final active = currentTrack;
>     if (active == null) return null;
>
>
>     final nativeIndex = _reusableNativeIndex(active);
>
>
>     if (nativeIndex == null ||
>         nativeIndex != _player.currentIndex) {
>       return null;
>     }
>
>
>     final nextIndex = _currentIndex + 1;
>     if (nextIndex >= _playlist.length) return null;
>
>
>     if (nativeIndex != _queueSource.length - 1) return null;
>
>
>     final next = _playlist[nextIndex];
>     if (_prefetchingId == next.id) return null;
>
>
>     final owner = ++_prefetchSerial;
>
>
>     _prefetchingId = next.id;
>     _prefetchOwner = owner;
>
>
>     return (
>       track: next,
>       revision: _queueRevision,
>       startToken: _startToken,
>       owner: owner,
>     );
>   });
>
>
>   if (plan == null) return;
>
>
>   try {
>     final path =
>         await AudioDownloadService.ensureDownloaded(plan.track);
>
>
>     await _withQueueGate<void>(() async {
>       if (_prefetchOwner != plan.owner ||
>           _queueRevision != plan.revision ||
>           _startToken != plan.startToken ||
>           _pendingStartToken != null) {
>         return;
>       }
>
>
>       if (_loopMode == LoopMode.one || autoAdvanceHeld) return;
>
>
>       final active = currentTrack;
>       if (active == null) return;
>
>
>       final nativeIndex = _reusableNativeIndex(active);
>
>
>       if (nativeIndex == null ||
>           nativeIndex != _player.currentIndex ||
>           nativeIndex != _queueSource.length - 1) {
>         return;
>       }
>
>
>       final nextIndex = _currentIndex + 1;
>
>
>       if (nextIndex >= _playlist.length ||
>           _playlist[nextIndex].id != plan.track.id) {
>         return;
>       }
>
>
>       ++_queueRevision;
>
>
>       await _queueSource.add(
>         ja.AudioSource.file(
>           path,
>           tag: _playlist[nextIndex],
>         ),
>       );
>     });
>   } catch (error, stack) {
>     debugPrint('Prefetch failed: $error\n$stack');
>   } finally {
>     await _withQueueGate<void>(() async {
>       if (_prefetchOwner != plan.owner) return;
>
>
>       _prefetchOwner = null;
>       _prefetchingId = null;
>     });
>   }
> }
> ```
>
> **Scope note:** this preserves existing prefetch download behavior. Your agent’s separate **local-only queue** change should prevent nonlocal items from entering automatic playback/prefetch. Do not interpret this patch as implementing that product decision.
>
> ---
>
> # 10. Replace native reconciliation and resume
>
> ## `_reconcileActiveTrack`
>
> This method is called only from the gate body or its finalizer.
>
> ```dart
> void _reconcileActiveTrack() {
>   if (_pendingStartToken != null) return;
>
>
>   final nativeIndex = _player.currentIndex;
>   if (nativeIndex == null) return;
>
>
>   final nativeTrack = _nativeTrackAt(nativeIndex);
>   if (nativeTrack == null) return;
>
>
>   final logicalIndex =
>       _playlist.indexWhere((track) => track.id == nativeTrack.id);
>
>
>   // The previous native source may belong to a replaced playlist.
>   // Never invent a logical mapping for it.
>   if (logicalIndex < 0) return;
>
>
>   final nextBase = logicalIndex - nativeIndex;
>   final changedTrack = logicalIndex != _currentIndex;
>   final changedBase = nextBase != _queueBaseIndex;
>
>
>   if (!changedTrack && !changedBase) return;
>
>
>   ++_queueRevision;
>   _currentIndex = logicalIndex;
>   _queueBaseIndex = nextBase;
>
>
>   if (changedTrack) {
>     _onActiveTrackChanged(_playlist[logicalIndex]);
>   }
> }
> ```
>
> ## `syncOnResume`
>
> ```dart
> void syncOnResume() {
>   _runDetached(
>     _withQueueGate<void>(() async {
>       if (_pendingStartToken != null) return;
>
>
>       _reconcileActiveTrack();
>
>
>       final track = currentTrack;
>       if (track != null) {
>         _updateMediaItem(track);
>         _broadcastState();
>       }
>     }),
>     'resume reconciliation',
>   );
> }
> ```
>
> The method remains `void`, but reconciliation is now queued. Existing UI stream listeners receive any resulting track change; callers must not assume the state is synchronously healed before this method returns.
>
> ---
>
> # 11. Replace automatic completion handling
>
> The completion event must not mutate the logical queue outside the gate.
>
> ```dart
> void _handleQueueCompleted() {
>   final observedToken = _startToken;
>
>
>   Future<void> advance() async {
>     final nextIndex = await _withQueueGate<int?>(() async {
>       if (observedToken != _startToken ||
>           _pendingStartToken != null ||
>           _playlist.isEmpty ||
>           _player.processingState != ja.ProcessingState.completed) {
>         return null;
>       }
>
>
>       _reconcileActiveTrack();
>
>
>       // Native repeat-one owns repetition of the current source.
>       if (_loopMode == LoopMode.one) return null;
>
>
>       if (autoAdvanceHeld) {
>         _playRequested = false;
>         ++_transportToken;
>
>
>         await _player.pause();
>         _broadcastState();
>         return null;
>       }
>
>
>       final next = _currentIndex + 1;
>
>
>       if (next < _playlist.length) return next;
>       if (_loopMode == LoopMode.all) return 0;
>
>
>       _playRequested = false;
>       ++_transportToken;
>
>
>       await _player.pause();
>       _broadcastState();
>       return null;
>     });
>
>
>     if (nextIndex != null && observedToken == _startToken) {
>       await _playAtIndex(nextIndex);
>     }
>   }
>
>
>   _runDetached(advance(), 'automatic queue advance');
> }
> ```
>
> ---
>
> # 12. Small supporting replacements
>
> ## `_onActiveTrackChanged`
>
> ```dart
> void _onActiveTrackChanged(Track track) {
>   _announce(track);
>   _maybeTrimHead();
>   _runDetached(_prefetchNext(), 'prefetch after native advance');
> }
> ```
>
> ## `holdAutoAdvance`
>
> Keep the counter semantics, but observe detached errors:
>
> ```dart
> VoidCallback holdAutoAdvance() {
>   _autoAdvanceHolds++;
>
>
>   if (_autoAdvanceHolds == 1) {
>     _runDetached(
>       _trimQueueAfterCurrent(),
>       'trim for auto-advance hold',
>     );
>   }
>
>
>   var released = false;
>
>
>   return () {
>     if (released) return;
>     released = true;
>
>
>     _autoAdvanceHolds--;
>
>
>     if (_autoAdvanceHolds == 0 && _loopMode != LoopMode.one) {
>       _runDetached(
>         _prefetchNext(),
>         'prefetch after auto-advance release',
>       );
>     }
>   };
> }
> ```
>
> An auto-advance hold still cannot retroactively undo a native transition already underway. Capturing the editor target remains necessary in the lyrics patch.
>
> ## `updateCurrentTrackMetadata`
>
> This method also writes `_playlist` and `_naturalOrder`. Keep its public `void` signature, but serialize those writes:
>
> ```dart
> void updateCurrentTrackMetadata(Track updatedTrack) {
>   _runDetached(
>     _withQueueGate<void>(() async {
>       var changed = false;
>
>
>       for (final list in [_playlist, _naturalOrder]) {
>         final index =
>             list.indexWhere((track) => track.id == updatedTrack.id);
>
>
>         if (index >= 0) {
>           list[index] = updatedTrack;
>           changed = true;
>         }
>       }
>
>
>       if (!changed) return;
>
>
>       if (currentTrack?.id == updatedTrack.id) {
>         _currentTrackController.add(updatedTrack);
>         _updateMediaItem(updatedTrack);
>       }
>     }),
>     'update queue metadata',
>   );
> }
> ```
>
> Metadata changes do not invalidate a prefetch because they do not alter track identity or order. The append uses the latest playlist instance.
>
> ---
>
> # Required verification before merging
>
> In addition to `flutter analyze`, add tests or instrumented checks for:
>
> 1. **Normal start:** `_isRebuilding` becomes false while the song is still playing; next-item preparation begins before it ends.
> 2. **Slow A → fast B:** B starts without waiting for A’s download. A’s completion cannot install a source.
> 3. **Supersession during native installation:** delay each of `clear`, `add`, and `setAudioSource`; a newer start eventually owns the installed source.
> 4. **Pause during download:** completion may prepare the source but must not autoplay.
> 5. **Stop during preparation:** the old preparation cannot restart playback afterward.
> 6. **Shuffle during prefetch:** an old successor is not appended into the new order.
> 7. **Repeat-one/hold during prefetch:** a stale successor does not commit after the state change has taken ownership.
> 8. **Native advance during trimming:** announced identity matches the actual source tag.
> 9. **Old playback-future error:** it is logged but cannot overwrite the current session’s error/state.
> 10. **Failed native operation:** later gate operations still execute.
>
> **Before applying, the agent should also resolve the rapid-skip behavior explicitly.** The patch guarantees latest-wins source preparation, but its current selection callbacks can coalesce very rapid skip commands. If the app must count every Next press, preserve each logical navigation intent while still superseding obsolete downloads/installations. That refinement belongs in this playback patch—not in the queue UI work.

---

# M7 — Prompt 2 implementation: lyric ownership patch

*Context: before sending Prompt 2, the agent's rapid-skip explanation was
corrected by Astra (serialization preserves callback order but the token
check discards stale callbacks — three presses can advance only once),
and the resume change was accepted provisionally. Astra then returned this
patch, which intentionally leaves the playback handler unchanged.*

> **One correction before Prompt 2:** the rapid-skip explanation is incorrect for the patch I supplied.
>
> `_requestStart` increments `_startToken` **before** its queued selection callback, and that callback contains:
>
> ```dart
> if (token != _startToken) return null;
> ```
>
> If three Next presses arrive before the gate executes them, the first two callbacks can return without advancing `_currentIndex`. **Three presses can therefore advance only once.** Serialization preserves callback order; it does not prevent the token check from discarding callbacks.
>
> Please correct the comment and track this as an unresolved playback behavior. Counting every skip requires preserving logical navigation intents separately from superseding source preparation.
>
> The resume change is acceptable provisionally, but “one stale frame” is not guaranteed—the delay depends on the gate. Do not depend on synchronous healing in the lyrics implementation.
>
> Below is **Prompt 2’s implementation**. It intentionally leaves the playback handler unchanged.
>
> ---
>
> # Lyric ownership patch
>
> ## Design
>
> Use two complementary guards:
>
> 1. **A UI load generation in `MainLayout`.**
>    Every current-track event invalidates earlier lyric work, including A→B→A.
>
> 2. **A per-track lyric revision in `DatabaseService`.**
>    A manual save increments the revision synchronously, before any await. Automatic cache commits must present the revision they started with.
>
> A small session map holds deliberately selected lyrics. This serves two purposes:
>
> - Reads immediately see a manual selection, even while its disk write is pending.
> - A manually chosen provider result is not rejected later in the session by automatic title validation.
>
> The database’s existing serialized write mechanism remains the only disk-write queue. **Do not add a second independent persistence queue in a widget.**
>
> The editor separately captures:
>
> - the target `Track`,
> - its ID,
> - an editor-session number,
> - its initial lyrics.
>
> Its callbacks never read mutable `_displayTrack` to decide which track to save.
>
> ---
>
> # 1. `lib/services/database_service.dart`
>
> ## Add ownership fields and accessors
>
> Inside `DatabaseService`, add:
>
> ```dart
> /// Changes synchronously whenever the user deliberately selects lyrics.
> static int _nextLyricsRevision = 0;
>
>
> static final Map<String, int> _lyricsRevisions = {};
>
>
> /// Deliberate choices made during this process lifetime.
> ///
> /// Retained for the session so a manually selected provider result is
> /// not later rejected by automatic title validation.
> ///
> /// This is not a second persistent cache. The existing lyrics cache
> /// remains the on-disk store.
> static final Map<String, LyricsResult> _manualLyricsSelections = {};
>
>
> static int lyricsRevisionFor(String trackId) =>
>     _lyricsRevisions[trackId] ?? 0;
>
>
> static LyricsResult? manualLyricsFor(String trackId) =>
>     _manualLyricsSelections[trackId];
> ```
>
> Do not evict revision entries while requests can still be in flight. Resetting a revision could make an old request appear current again.
>
> ## Replace `cacheLyrics`
>
> Keep its public `Future<void>` return type. Existing editor callers remain compatible.
>
> **Important:** after this patch, `cacheLyrics` represents a **deliberate/manual selection**. The automatic caller in `main.dart` must use the new `cacheAutomaticLyrics` method below.
>
> ```dart
> /// Saves a deliberate lyric choice.
> ///
> /// This wrapper is intentionally not async: revision invalidation and
> /// the immediately readable manual selection happen before returning.
> static Future<void> cacheLyrics(
>   String trackId,
>   LyricsResult lyrics,
> ) {
>   final revision = ++_nextLyricsRevision;
>
>
>   _lyricsRevisions[trackId] = revision;
>   _manualLyricsSelections[trackId] = lyrics;
>
>
>   return _saveManualLyrics(
>     trackId,
>     lyrics,
>     revision: revision,
>   );
> }
>
>
> static Future<void> _saveManualLyrics(
>   String trackId,
>   LyricsResult lyrics, {
>   required int revision,
> }) async {
>   await _ensureLoaded();
>
>
>   // Another manual selection already superseded this one.
>   if (lyricsRevisionFor(trackId) != revision) return;
>
>
>   _storeLyricsInMemory(trackId, lyrics);
>   await _persistLyrics();
> }
> ```
>
> ## Add the automatic commit method
>
> ```dart
> /// Commits an automatic result only if no deliberate selection has
> /// superseded the request.
> ///
> /// Ownership is checked after _ensureLoaded and immediately before
> /// changing the cache. There is no await between that check and mutation.
> static Future<bool> cacheAutomaticLyrics(
>   String trackId,
>   LyricsResult lyrics, {
>   required int expectedRevision,
> }) async {
>   await _ensureLoaded();
>
>
>   if (lyricsRevisionFor(trackId) != expectedRevision ||
>       _manualLyricsSelections.containsKey(trackId)) {
>     return false;
>   }
>
>
>   _storeLyricsInMemory(trackId, lyrics);
>   await _persistLyrics();
>
>
>   // A manual choice could have arrived while persistence was pending.
>   // The caller must not publish this automatic result in that case.
>   return lyricsRevisionFor(trackId) == expectedRevision &&
>       !_manualLyricsSelections.containsKey(trackId);
> }
> ```
>
> ## Add the shared in-memory mutation helper
>
> ```dart
> static void _storeLyricsInMemory(
>   String trackId,
>   LyricsResult lyrics,
> ) {
>   if (lyrics.source == 'none') {
>     _lyricsCache.remove(trackId);
>     return;
>   }
>
>
>   // Move the entry to the most-recent end.
>   _lyricsCache.remove(trackId);
>   _lyricsCache[trackId] = lyrics;
>
>
>   while (_lyricsCache.length > _maxLyricsCacheEntries) {
>     _lyricsCache.remove(_lyricsCache.keys.first);
>   }
> }
> ```
>
> ## Replace `getCachedLyrics`
>
> ```dart
> static Future<LyricsResult?> getCachedLyrics(
>   String trackId,
> ) async {
>   await _ensureLoaded();
>
>
>   // Check after the await: a manual selection may have been made while
>   // loading the database.
>   final manual = _manualLyricsSelections[trackId];
>   if (manual != null) return manual;
>
>
>   final cached = _lyricsCache[trackId];
>
>
>   if (cached != null) {
>     _lyricsCache.remove(trackId);
>     _lyricsCache[trackId] = cached;
>   }
>
>
>   return cached;
> }
> ```
>
> ## Replace `_persistLyrics`
>
> The existing method swallows persistence errors. For the editor to avoid reporting success after a failed write, let this particular persistence operation propagate failure:
>
> ```dart
> static Future<void> _persistLyrics() async {
>   final dir = await _docs();
>
>
>   // Take the snapshot after resolving the directory.
>   //
>   // Snapshot creation and entry into _writeJsonAtomically happen in one
>   // synchronous turn, so the existing write lock preserves their order.
>   final map = _lyricsCache.map(
>     (key, value) => MapEntry(key, value.toMap()),
>   );
>
>
>   await _writeJsonAtomically(
>     '$dir/bilibeat_lyrics.json',
>     _envelope(map),
>   );
> }
> ```
>
> ### Why an old automatic write cannot become the final newer value
>
> There are two cases:
>
> - **Manual selection happens before automatic cache mutation:** the revision check rejects the automatic result.
> - **Automatic mutation happens first:** its write is either queued before the manual write, or takes a later snapshot that already contains the manual value. The manual mutation and its subsequent write are not overtaken by an older snapshot entering the write queue afterward.
>
> While persistence is pending, reads return the synchronously registered manual selection.
>
> This protects ordering. It does **not** make the existing delete-then-rename implementation crash-atomic, nor guarantee persistence if the filesystem write fails.
>
> ---

> # 2. `lib/main.dart`
>
> ## Add these fields to `_MainLayoutState`
>
> ```dart
> int _lyricsLoadGeneration = 0;
> String? _lyricsTrackId;
> ```
>
> ## Replace only the current-track subscription in `_initListeners`
>
> Replace the existing:
>
> ```dart
> _subs.add(_audioHandler.currentTrackStream.listen((track) async {
>   ...
> }));
> ```
>
> with:
>
> ```dart
> _subs.add(
>   _audioHandler.currentTrackStream.listen((track) {
>     final generation = ++_lyricsLoadGeneration;
>
>
>     if (!mounted) return;
>
>
>     _currentTrack.value = track;
>
>
>     if (track == null) {
>       _lyricsTrackId = null;
>       _lyricsNotifier.value = const [];
>       return;
>     }
>
>
>     if (_lyricsTrackId != track.id) {
>       _lyricsTrackId = track.id;
>
>
>       // Never leave the previous song's lyrics visible while loading.
>       _lyricsNotifier.value = const [];
>     }
>
>
>     unawaited(
>       _loadLyricsForTrack(
>         track,
>         generation: generation,
>       ),
>     );
>   }),
> );
> ```
>
> The helper below catches its own failures.
>
> ## Add `_ownsLyricsLoad`
>
> ```dart
> bool _ownsLyricsLoad(
>   Track track,
>   int generation,
> ) {
>   return mounted &&
>       generation == _lyricsLoadGeneration &&
>       _lyricsTrackId == track.id &&
>       _currentTrack.value?.id == track.id &&
>       _audioHandler.currentTrack?.id == track.id;
> }
> ```
>
> Checking the handler directly avoids relying exclusively on an optimistic UI assignment or synchronous resume healing.
>
> ## Add `_loadLyricsForTrack`
>
> ```dart
> Future<void> _loadLyricsForTrack(
>   Track track, {
>   required int generation,
> }) async {
>   final revision = DatabaseService.lyricsRevisionFor(track.id);
>
>
>   bool ownsRequest() {
>     return _ownsLyricsLoad(track, generation) &&
>         DatabaseService.lyricsRevisionFor(track.id) == revision;
>   }
>
>
>   void publishManualIfCurrent() {
>     if (!_ownsLyricsLoad(track, generation)) return;
>
>
>     final manual = DatabaseService.manualLyricsFor(track.id);
>     if (manual == null) return;
>
>
>     _lyricsNotifier.value =
>         manual.source == 'none' ? const [] : manual.lines;
>   }
>
>
>   try {
>     // The user may already have chosen lyrics in this session.
>     final manual = DatabaseService.manualLyricsFor(track.id);
>
>
>     if (manual != null) {
>       if (_ownsLyricsLoad(track, generation)) {
>         _lyricsNotifier.value =
>             manual.source == 'none' ? const [] : manual.lines;
>       }
>       return;
>     }
>
>
>     final cached =
>         await DatabaseService.getCachedLyrics(track.id);
>
>
>     if (!ownsRequest()) {
>       publishManualIfCurrent();
>       return;
>     }
>
>
>     // A deliberate provider selection should bypass automatic title
>     // validation just like pasted/current lyrics.
>     final latestManual =
>         DatabaseService.manualLyricsFor(track.id);
>
>
>     if (latestManual != null) {
>       _lyricsNotifier.value = latestManual.source == 'none'
>           ? const []
>           : latestManual.lines;
>       return;
>     }
>
>
>     final cleanSongTitle =
>         LyricsEngine.cleanTitle(track.rawTitle)['songTitle'] ?? '';
>
>
>     var cacheValid = false;
>
>
>     if (cached != null &&
>         cached.lines.isNotEmpty &&
>         cached.source != 'none') {
>       if (cached.source == 'user' ||
>           cached.source == 'current') {
>         cacheValid = true;
>       } else {
>         final cachedTitle = cached.songTitle ?? '';
>
>
>         cacheValid = cachedTitle.isNotEmpty &&
>             LyricsEngine.isTitleMatching(
>               cachedTitle,
>               cleanSongTitle,
>             );
>       }
>     }
>
>
>     if (cacheValid) {
>       if (ownsRequest()) {
>         _lyricsNotifier.value = cached!.lines;
>       }
>       return;
>     }
>
>
>     if (!ownsRequest()) {
>       publishManualIfCurrent();
>       return;
>     }
>
>
>     _lyricsNotifier.value = const [];
>
>
>     final fresh =
>         await LyricsEngine.autoFetchLyrics(track.rawTitle);
>
>
>     if (!ownsRequest()) {
>       publishManualIfCurrent();
>       return;
>     }
>
>
>     final accepted =
>         await DatabaseService.cacheAutomaticLyrics(
>       track.id,
>       fresh,
>       expectedRevision: revision,
>     );
>
>
>     if (!accepted || !ownsRequest()) {
>       publishManualIfCurrent();
>       return;
>     }
>
>
>     _lyricsNotifier.value =
>         fresh.source == 'none' ? const [] : fresh.lines;
>   } catch (error, stack) {
>     debugPrint('Lyrics load failed for ${track.id}: $error\n$stack');
>
>
>     // Do not clear a newer or manually applied value on failure.
>     publishManualIfCurrent();
>   }
> }
> ```
>
> ### Lifecycle detail
>
> At the beginning of `dispose`, invalidate outstanding loads:
>
> ```dart
> ++_lyricsLoadGeneration;
> ```
>
> The existing `mounted` guards and subscription disposal still remain necessary.
>
> **No resume-handler changes are needed for this patch.** A later authoritative current-track event starts a new generation.
>
> ---
>
> # 3. `lib/widgets/now_playing_sheet.dart`
>
> Add:
>
> ```dart
> import '../utils/snack.dart';
> ```
>
> `LyricsResult` is already available through the existing `lyric_line.dart` import.
>
> ## Add editor ownership fields
>
> ```dart
> Track? _editorTrack;
> List<LyricLine> _editorInitialLines = const [];
>
>
> int _editorSession = 0;
>
>
> /// A clock belonging to the captured editor target.
> ///
> /// It follows playback only while that exact target is active. It must
> /// never become another song's position stream.
> final ValueNotifier<Duration> _editorPosition =
>     ValueNotifier(Duration.zero);
>
>
> final Set<String> _favoriteOperations = {};
>
>
> int _favoriteStateToken = 0;
> int _downloadStateToken = 0;
> ```
>
> ## Register the editor clock listener
>
> In `initState`, add:
>
> ```dart
> widget.positionNotifier.addListener(_syncEditorPosition);
> ```
>
> Add:
>
> ```dart
> void _syncEditorPosition() {
>   final target = _editorTrack;
>   if (target == null) return;
>
>
>   if (widget.handler.currentTrack?.id != target.id) return;
>
>
>   _editorPosition.value = widget.positionNotifier.value;
> }
> ```
>
> In `dispose`, before `super.dispose()`:
>
> ```dart
> ++_editorSession;
>
>
> widget.positionNotifier.removeListener(_syncEditorPosition);
> _editorPosition.dispose();
> ```
>
> Keep the existing `_editorRelease?.call()` and stream cleanup.
>
> The editor clock freezes when its target stops being active. This prevents calibration against the next song. It does not introduce new calibration behavior or an unrelated clock.
>
> ## Replace `_openEditor`
>
> ```dart
> void _openEditor({bool lyricsTab = false}) {
>   final target = _displayTrack;
>
>
>   final active =
>       widget.handler.currentTrack?.id == target.id;
>
>
>   final manual =
>       DatabaseService.manualLyricsFor(target.id);
>
>
>   final initialLines = manual != null
>       ? manual.lines
>       : active
>           ? widget.lyricsNotifier.value
>           : const <LyricLine>[];
>
>
>   _editorRelease?.call();
>   _editorRelease = widget.handler.holdAutoAdvance();
>
>
>   ++_editorSession;
>
>
>   _editorPosition.value = active
>       ? widget.positionNotifier.value
>       : Duration.zero;
>
>
>   setState(() {
>     _editorTrack = target;
>     _editorInitialLines = List<LyricLine>.of(initialLines);
>     _showEditor = true;
>     _editorLyricsTab = lyricsTab;
>   });
> }
> ```
>
> This preserves the existing behavior for nonactive tracks without adding an asynchronous cached-lyrics loading step to opening the editor.
>
> ## Replace `_closeEditor`
>
> ```dart
> void _closeEditor() {
>   ++_editorSession;
>
>
>   _editorRelease?.call();
>   _editorRelease = null;
>
>
>   if (!mounted) return;
>
>
>   setState(() {
>     _showEditor = false;
>     _editorTrack = null;
>     _editorInitialLines = const [];
>   });
> }
> ```
>
> ## Add a guarded close helper
>
> ```dart
> void _finishEditorSession(
>   int session, {
>   bool showLyrics = false,
> }) {
>   if (!mounted ||
>       !_showEditor ||
>       session != _editorSession) {
>     return;
>   }
>
>
>   if (showLyrics) {
>     _showLyrics = true;
>   }
>
>
>   _closeEditor();
> }
> ```
>
> ## Add the captured-target lyric callback
>
> ```dart
> Future<void> _applyEditorLyrics(
>   Track target,
>   int session,
>   LyricsResult result,
> ) async {
>   if (!mounted ||
>       !_showEditor ||
>       session != _editorSession) {
>     return;
>   }
>
>
>   // Snapshot the list so later caller-side mutations cannot change the
>   // value being saved.
>   final selection = LyricsResult(
>     source: result.source,
>     songTitle: result.songTitle,
>     artistName: result.artistName,
>     lines: List<LyricLine>.of(result.lines),
>   );
>
>
>   // This invalidates automatic commits synchronously, before any await.
>   final save = DatabaseService.cacheLyrics(
>     target.id,
>     selection,
>   );
>
>
>   final revision =
>       DatabaseService.lyricsRevisionFor(target.id);
>
>
>   // Publish only into the active track's shared lyrics notifier.
>   if (widget.handler.currentTrack?.id == target.id) {
>     widget.lyricsNotifier.value =
>         selection.source == 'none'
>             ? const []
>             : selection.lines;
>   }
>
>
>   try {
>     await save;
>
>
>     // Another deliberate choice may have superseded this save.
>     if (DatabaseService.lyricsRevisionFor(target.id) != revision) {
>       return;
>     }
>
>
>     _finishEditorSession(
>       session,
>       showLyrics: widget.handler.currentTrack?.id == target.id,
>     );
>   } catch (error, stack) {
>     debugPrint('Manual lyrics save failed: $error\n$stack');
>
>
>     if (!mounted) return;
>
>
>     showAppSnackBar(
>       ScaffoldMessenger.of(context),
>       message: '歌词已在本次使用中应用，但保存失败，请重试',
>       backgroundColor: AppColors.backgroundElevated,
>       duration: const Duration(seconds: 4),
>     );
>   }
> }
> ```
>
> A failed disk save keeps the deliberate session choice rather than allowing an older automatic result to return. The editor remains open if the same editor session is still present.
>
> ## Add the captured-target metadata callback
>
> ```dart
> Future<void> _saveEditorMetadata(
>   Track target,
>   int session,
>   String newTitle,
>   String newArtist,
>   String newCoverUrl,
> ) async {
>   if (!mounted ||
>       !_showEditor ||
>       session != _editorSession) {
>     return;
>   }
>
>
>   final handler = widget.handler;
>
>
>   final updated = target.copyWith(
>     title: newTitle,
>     uploader: newArtist,
>     coverUrl: newCoverUrl,
>   );
>
>
>   try {
>     await DatabaseService.updateTrackMetadata(updated);
>
>
>     // The target remains the captured track even if playback changed
>     // while the database operation was pending.
>     handler.updateCurrentTrackMetadata(updated);
>
>
>     if (!mounted) return;
>
>
>     if (_displayTrack.id == updated.id) {
>       setState(() => _displayTrack = updated);
>     }
>
>
>     _finishEditorSession(session);
>   } catch (error, stack) {
>     debugPrint('Metadata save failed: $error\n$stack');
>
>
>     if (!mounted) return;
>
>
>     showAppSnackBar(
>       ScaffoldMessenger.of(context),
>       message: '修改未能保存，请重试',
>       backgroundColor: AppColors.backgroundElevated,
>       duration: const Duration(seconds: 4),
>     );
>   }
> }
> ```
>
> **Existing limitation:** parts of `updateTrackMetadata` still swallow persistence errors internally. This callback can only report errors that propagate. That broader persistence contract is outside this lyric-ownership patch.
>
> ## Add `_buildEditor`
>
> ```dart
> Widget _buildEditor() {
>   final target = _editorTrack;
>
>
>   if (target == null) {
>     return const SizedBox.shrink();
>   }
>
>
>   // Capture these values in this widget's callbacks. Never consult
>   // mutable _displayTrack to determine their save target.
>   final session = _editorSession;
>
>
>   return LyricEditorDialog(
>     key: ValueKey('lyric-editor-$session'),
>     songTitle: target.title,
>     rawTitle: target.rawTitle,
>     artistName: target.uploader,
>     coverUrl: target.coverUrl,
>     positionNotifier: _editorPosition,
>     initialTabIndex: _editorLyricsTab ? 1 : 0,
>     currentLines: _editorInitialLines,
>     currentTrackId: target.id,
>     onClose: () {
>       if (session == _editorSession) {
>         _closeEditor();
>       }
>     },
>     onApplyLyrics: (result) {
>       return _applyEditorLyrics(
>         target,
>         session,
>         result,
>       );
>     },
>     onUpdateMetadata: (title, artist, cover) {
>       return _saveEditorMetadata(
>         target,
>         session,
>         title,
>         artist,
>         cover,
>       );
>     },
>   );
> }
> ```
>
> In `build`, replace the entire existing inline `LyricEditorDialog(...)` instance with:
>
> ```dart
> _buildEditor()
> ```
>
> Keep its surrounding keyed subtree and `AnimatedSwitcher`.
>
> ### About the existing “Save all” behavior
>
> `LyricEditorDialog._saveAll()` currently invokes metadata and lyric callbacks without awaiting them. This patch **does not make those saves transactional**.
>
> Both callbacks capture their target/session before their first await, so the current combined-save path cannot retarget either operation to another song. Each completion only closes the editor if it still owns that session.
>
> A later cleanup should make “Save all” one explicitly awaited operation with one close and a single error outcome. Do not describe this ownership patch as fixing that separate UX issue.
>
> ---

> # 4. Protect Favorite and download-state refreshes
>
> These changes preserve the dumped behavior—including its existing favorite-triggered download—but ensure the operation targets the captured track. The separately agreed **favorite-only default** can remove that download branch in its own product patch.
>
> ## Replace `_refreshTrackState`
>
> ```dart
> Future<void> _refreshTrackState() async {
>   final track = _displayTrack;
>
>
>   final favoriteToken = ++_favoriteStateToken;
>   final downloadToken = ++_downloadStateToken;
>
>
>   try {
>     final results = await Future.wait<bool>([
>       AudioDownloadService.isDownloaded(track),
>       DatabaseService.isFavorite(track.id),
>     ]);
>
>
>     if (!mounted || _displayTrack.id != track.id) return;
>
>
>     setState(() {
>       if (downloadToken == _downloadStateToken) {
>         _isDownloaded = results[0] &&
>             !DownloadManager.instance.isDownloading(track.id);
>       }
>
>
>       if (favoriteToken == _favoriteStateToken &&
>           !_favoriteOperations.contains(track.id)) {
>         _isFavorite = results[1];
>       }
>     });
>   } catch (error, stack) {
>     debugPrint('Track state refresh failed: $error\n$stack');
>   }
> }
> ```
>
> ## Replace `_refreshDownloaded`
>
> ```dart
> Future<void> _refreshDownloaded() async {
>   final track = _displayTrack;
>   final token = ++_downloadStateToken;
>
>
>   try {
>     final downloaded =
>         await AudioDownloadService.isDownloaded(track);
>
>
>     if (!mounted ||
>         token != _downloadStateToken ||
>         _displayTrack.id != track.id) {
>       return;
>     }
>
>
>     setState(() => _isDownloaded = downloaded);
>   } catch (error, stack) {
>     debugPrint('Download state refresh failed: $error\n$stack');
>   }
> }
> ```
>
> ## Replace `_handleFavorite`
>
> ```dart
> Future<void> _handleFavorite() async {
>   final target = _displayTrack;
>
>
>   if (!_favoriteOperations.add(target.id)) return;
>
>
>   ++_favoriteStateToken;
>   Haptics.light();
>
>
>   try {
>     final nowFavorite =
>         await DatabaseService.toggleFavorite(target);
>
>
>     if (mounted && _displayTrack.id == target.id) {
>       // Invalidate refreshes that began before this mutation completed.
>       ++_favoriteStateToken;
>       setState(() => _isFavorite = nowFavorite);
>     }
>
>
>     // Preserve the dumped behavior for this guard-only patch.
>     // Remove this branch in the favorite-only product change.
>     if (nowFavorite) {
>       final downloaded =
>           await AudioDownloadService.isDownloaded(target);
>
>
>       if (!downloaded) {
>         await DownloadManager.instance.startDownload(target);
>       }
>     }
>   } catch (error, stack) {
>     debugPrint('Favorite operation failed: $error\n$stack');
>
>
>     if (mounted) {
>       showAppSnackBar(
>         ScaffoldMessenger.of(context),
>         message: '操作未完成，请重试',
>         backgroundColor: AppColors.backgroundElevated,
>       );
>     }
>   } finally {
>     _favoriteOperations.remove(target.id);
>
>
>     if (mounted && _displayTrack.id == target.id) {
>       _refreshTrackState();
>     }
>   }
> }
> ```
>
> For the agreed favorite-only product contract, remove the marked download branch. That also prevents the busy guard from spanning a download’s lifetime.
>
> ---
>
> # 5. Audit the remaining lyric-cache callers
>
> Search the project for:
>
> ```text
> cacheLyrics(
> cacheAutomaticLyrics(
> ```
>
> After this patch:
>
> - `MainLayout` auto-fetch → **`cacheAutomaticLyrics`**
> - User paste, selected provider result, or calibration → **`cacheLyrics`**
> - No other automatic path may call the manual method.
>
> Keep the original provider `source` value. Do not disguise every manual selection as `'user'`; provenance and user intent are different concepts.
>
> The session map records intent during the current process. **Persisting “manually selected” as a separate property across restarts would require a model/schema change**, which this focused patch does not introduce. Existing `'user'`/`'current'` cache handling across restarts remains unchanged.
>
> ---
>
> # Verification required
>
> Unlike the native playback checks, much of this ownership behavior can be tested without `just_audio` platform playback.
>
> Add targeted tests for:
>
> | Scenario | Required outcome |
> |---|---|
> | Auto A starts → manual A saves → auto A finishes | Manual A remains visible and cached. |
> | Auto A mutates cache → its persistence is pending → manual A saves | Final persisted entry is manual A. |
> | Manual A is registered before database initialization completes | Reads return manual A; old loaded cache cannot win. |
> | A→B→A, first A request finishes last | First A cannot publish to the new A generation. |
> | Manual A choice 1 → manual A choice 2 | Choice 1 cannot become the final cache value or close a newer editor session. |
> | Editor opened for A → OS Next selects B → Apply | A is saved; B’s visible lyrics remain untouched. |
> | Editor opened for A → OS Next selects B → metadata Save | A’s metadata changes, not B’s. |
> | Automatic failure after manual selection | Manual lyrics are not cleared. |
> | Lyric disk write fails | Session selection remains; failure is reported rather than silently treated as saved. |
> | Favorite A → switch to B before await completes | Neither B’s favorite flag nor B’s download is changed by A’s operation. |
>
> **Report these as new targeted test results—not merely “suite unchanged from baseline.”** Static analysis confirms type correctness, not request ownership or persistence ordering.

---

# M8 — Prompt 3: queue snapshot patch (read-only queue)

*Context: the agent relayed Astra's test report (snapshot value tests
green; handler-level tests blocked because `BiliBeatAudioHandler()`
construction needs the native player), and asked for Prompt 3. Astra
replied: keep the playback races and widget-side lyric cases marked
unverified (fake-player/widget tests later; no device needed), use one
immutable snapshot, publish the inherited queue too, and sent this patch
against the original handler plus the applied gate.*

> Good progress. **Keep the playback race checks and widget-side lyric cases marked as unverified.** They can eventually be covered with fake-player/widget tests; they do not all require manual testing on a device.
>
> For Prompt 3, use **one immutable queue snapshot published by the handler**. The snapshot contains the list, current index, shuffle, and repeat state together. Widgets must not combine independently emitted streams to reconstruct queue identity.
>
> Also publish the inherited `audio_service.queue` for system integration, but use the combined snapshot as the Flutter queue UI’s authority.
>
> Below is a focused patch against the original handler plus the previously applied queue gate.
>
> ---
>
> # 1. Add the queue snapshot type
>
> **File:** `lib/services/audio_player_handler.dart`
>
> Place this after `LoopMode`, before `BiliBeatAudioHandler`:
>
> ```dart
> /// An immutable view of the handler's logical playback queue.
> ///
> /// Tracks are already immutable. The list is copied and made unmodifiable
> /// so widgets cannot mutate the handler's queue.
> ///
> /// Order is playback order, including shuffle.
> @immutable
> class PlaybackQueueSnapshot {
>   final List<Track> tracks;
>   final int currentIndex;
>   final bool isShuffle;
>   final LoopMode loopMode;
>
>
>   PlaybackQueueSnapshot({
>     required List<Track> tracks,
>     required this.currentIndex,
>     required this.isShuffle,
>     required this.loopMode,
>   }) : tracks = List<Track>.unmodifiable(tracks);
>
>
>   Track? get currentTrack {
>     if (currentIndex < 0 || currentIndex >= tracks.length) {
>       return null;
>     }
>
>
>     return tracks[currentIndex];
>   }
>
>
>   /// Queue positions following the current item.
>   ///
>   /// This deliberately does not synthesize loop wrapping or repeat-one
>   /// entries. Loop behavior is described separately by [loopMode].
>   int get upcomingCount {
>     if (tracks.isEmpty) return 0;
>     if (currentIndex < 0) return tracks.length;
>
>
>     final remaining = tracks.length - currentIndex - 1;
>     return remaining > 0 ? remaining : 0;
>   }
> }
> ```
>
> ---
>
> # 2. Add snapshot storage to the handler
>
> Inside `BiliBeatAudioHandler`:
>
> ```dart
> final StreamController<PlaybackQueueSnapshot>
>     _queueSnapshotController =
>     StreamController<PlaybackQueueSnapshot>.broadcast();
>
>
> PlaybackQueueSnapshot _queueSnapshot = PlaybackQueueSnapshot(
>   tracks: const [],
>   currentIndex: -1,
>   isShuffle: false,
>   loopMode: LoopMode.all,
> );
>
>
> /// Read immediately when attaching a UI.
> PlaybackQueueSnapshot get queueSnapshot => _queueSnapshot;
>
>
> /// Subsequent authoritative snapshots.
> ///
> /// Consumers should subscribe and use [queueSnapshot] as initial data.
> Stream<PlaybackQueueSnapshot> get queueSnapshotStream =>
>     _queueSnapshotController.stream;
> ```
>
> This controller follows the handler’s existing process-lifetime stream ownership.
>
> **Do not close it in `stop()`.** Stopping playback does not dispose the handler. If a real handler-disposal path is introduced, close this controller alongside the existing ones there.
>
> ---
>
> # 3. Add one shared `MediaItem` mapper
>
> The existing `_updateMediaItem` constructs `MediaItem` directly. Extract that construction so current-item and queue publication cannot drift apart.
>
> Add:
>
> ```dart
> MediaItem _mediaItemForTrack(Track track) {
>   return MediaItem(
>     id: track.id,
>     album: 'BiliBeat',
>     title: track.title,
>     artist: track.uploader,
>
>
>     // Preserve the existing handler behavior in this focused patch.
>     duration: Duration(
>       seconds: track.duration > 0 ? track.duration : 180,
>     ),
>
>
>     artUri: track.coverUrl.isEmpty
>         ? null
>         : Uri.tryParse(track.coverUrl),
>   );
> }
> ```
>
> Replace `_updateMediaItem` with:
>
> ```dart
> void _updateMediaItem(Track track) {
>   mediaItem.add(_mediaItemForTrack(track));
> }
> ```
>
> The existing guessed 180-second duration and local-art URI handling are separate concerns; this patch does not change them.
>
> ---
>
> # 4. Add snapshot publication
>
> Inside the handler:
>
> ```dart
> bool _sameTrackInstances(
>   List<Track> previous,
>   List<Track> next,
> ) {
>   if (previous.length != next.length) return false;
>
>
>   for (var i = 0; i < previous.length; i++) {
>     // Track.operator == compares only id.
>     //
>     // Identity comparison also detects edited metadata represented by
>     // a new Track instance with the same id.
>     if (!identical(previous[i], next[i])) return false;
>   }
>
>
>   return true;
> }
>
>
> /// Publish only from the queue gate's finalizer, after reconciliation.
> ///
> /// This describes the logical queue and logical selection. It does not
> /// claim that a selected track has finished preparing or is audible.
> void _publishQueueSnapshot() {
>   final previous = _queueSnapshot;
>
>
>   final tracksChanged =
>       !_sameTrackInstances(previous.tracks, _playlist);
>
>
>   final selectionChanged =
>       previous.currentIndex != _currentIndex;
>
>
>   final modeChanged =
>       previous.isShuffle != _isShuffle ||
>       previous.loopMode != _loopMode;
>
>
>   if (!tracksChanged && !selectionChanged && !modeChanged) {
>     return;
>   }
>
>
>   final next = PlaybackQueueSnapshot(
>     tracks: _playlist,
>     currentIndex: _currentIndex,
>     isShuffle: _isShuffle,
>     loopMode: _loopMode,
>   );
>
>
>   // Assign before emitting so synchronous reads see the newest state.
>   _queueSnapshot = next;
>
>
>   // audio_service expects the same logical order used by queueIndex and
>   // skipToQueueItem. Never publish the small native prefetch window here.
>   if (tracksChanged) {
>     queue.add(
>       List<MediaItem>.unmodifiable(
>         next.tracks.map(_mediaItemForTrack),
>       ),
>     );
>   }
>
>
>   _queueSnapshotController.add(next);
> }
> ```
>
> ### Why instance comparison matters
>
> `Track` equality is ID-only. Using `listEquals` directly would miss a title or cover edit for an existing queue item.
>
> The handler’s metadata update method replaces `Track` instances, so identity comparison matches the interfaces you already use.
>
> ---

> # 5. Publish from the queue gate
>
> Replace the current `_withQueueGate` with this version. The only functional addition is publication after reconciliation.
>
> ```dart
> Future<T> _withQueueGate<T>(Future<T> Function() action) {
>   final result = _queueGate.then<T>((_) async {
>     _isRebuilding = true;
>
>
>     try {
>       return await action();
>     } finally {
>       _isRebuilding = false;
>
>
>       try {
>         if (_pendingStartToken == null) {
>           _reconcileActiveTrack();
>         }
>       } finally {
>         _publishQueueSnapshot();
>       }
>     }
>   });
>
>
>   // A failed operation must not poison the serialization chain.
>   _queueGate = result.then<void>(
>     (_) {},
>     onError: (Object error, StackTrace stack) {},
>   );
>
>
>   return result;
> }
> ```
>
> Do not sprinkle `_publishQueueSnapshot()` calls throughout the handler.
>
> With the earlier patch’s invariant, this one publication point covers:
>
> - replacement of the logical queue,
> - track selection,
> - native automatic advance and reconciliation,
> - shuffle order changes,
> - repeat changes,
> - metadata replacement,
> - failed operations that nevertheless changed logical state.
>
> Native prefetch append/trim operations do not emit a new snapshot unless reconciliation also changes the logical selection.
>
> **Audit requirement:** the agent’s concurrent local-only queue changes must continue to mutate `_playlist`, `_naturalOrder`, and `_currentIndex` through this gate.
>
> ---
>
> # 6. Add ID-based selection for the Flutter UI
>
> Keep the existing `skipToQueueItem(int)` override for `audio_service`.
>
> For Flutter, add an ID-based method. A displayed index can become stale after shuffle; the selected track ID is the actual user intent.
>
> This method:
>
> - checks membership inside the gate,
> - never inserts a removed track back into the queue,
> - ignores a click superseded by a newer track-start request,
> - performs source preparation outside the gate,
> - leaves rapid Next/Previous semantics unchanged.
>
> ```dart
> /// Selects an existing logical-queue item by stable track id.
> ///
> /// Unlike playTrack, this never inserts a missing track into the queue.
> /// Unlike an index captured by a widget, the id survives queue reordering.
> Future<void> selectQueueTrack(String trackId) async {
>   final observedStartToken = _startToken;
>
>
>   final plan = await _withQueueGate<
>       ({
>         Track track,
>         int token,
>       })?>(() async {
>     // A newer track-start intent was submitted while this click waited.
>     if (observedStartToken != _startToken) return null;
>
>
>     final index =
>         _playlist.indexWhere((track) => track.id == trackId);
>
>
>     // A stale UI row must not resurrect a removed queue item.
>     if (index < 0) return null;
>
>
>     final token = ++_startToken;
>
>
>     ++_transportToken;
>     _playRequested = true;
>     _pendingStartToken = token;
>
>
>     ++_queueRevision;
>     _prefetchingId = null;
>     _prefetchOwner = null;
>
>
>     _currentIndex = index;
>     final selected = _playlist[index];
>
>
>     _announce(selected);
>     _positionController.add(Duration.zero);
>
>
>     _broadcastState(
>       processingOverride: AudioProcessingState.loading,
>     );
>
>
>     return (
>       track: selected,
>       token: token,
>     );
>   });
>
>
>   if (plan == null || plan.token != _startToken) return;
>
>
>   await _startCurrent(
>     active: plan.track,
>     token: plan.token,
>   );
> }
> ```
>
> This duplicates the small start-intent setup from `_requestStart` deliberately, so a nonexistent/stale queue selection can be rejected **before** changing playback intent.
>
> A later internal refactor may extract that setup into a locked helper. Do not route queue selection through `playTrack`, because that method is allowed to insert tracks.
>
> ---
>
> # 7. Minimal widget-side subscription
>
> The following is a complete small queue surface using the existing components. It has no queue editing, no reorder controls, and no second queue model.
>
> **Add:** `lib/widgets/playback_queue_sheet.dart`
>
> ```dart
> import 'package:flutter/material.dart';
>
>
> import '../services/audio_player_handler.dart';
> import '../theme/app_theme.dart';
> import 'cached_cover_image.dart';
> import 'empty_state.dart';
> import 'marquee_text.dart';
> import 'track_row.dart';
>
>
> class PlaybackQueueSheet extends StatelessWidget {
>   final BiliBeatAudioHandler handler;
>
>
>   const PlaybackQueueSheet({
>     super.key,
>     required this.handler,
>   });
>
>
>   static Future<void> show(
>     BuildContext context, {
>     required BiliBeatAudioHandler handler,
>   }) {
>     return showModalBottomSheet<void>(
>       context: context,
>       isScrollControlled: true,
>       useSafeArea: true,
>       backgroundColor: AppColors.backgroundElevated,
>       shape: const RoundedRectangleBorder(
>         borderRadius: BorderRadius.vertical(
>           top: Radius.circular(AppRadius.xl),
>         ),
>       ),
>       builder: (context) {
>         return PlaybackQueueSheet(handler: handler);
>       },
>     );
>   }
>
>
>   String _modeLabel(PlaybackQueueSnapshot snapshot) {
>     final order = snapshot.isShuffle ? '随机播放' : '顺序播放';
>
>
>     final repeat = switch (snapshot.loopMode) {
>       LoopMode.off => '不循环',
>       LoopMode.all => '列表循环',
>       LoopMode.one => '单曲循环',
>     };
>
>
>     return '$order · $repeat';
>   }
>
>
>   Future<void> _select(
>     BuildContext context,
>     String trackId,
>   ) async {
>     try {
>       await handler.selectQueueTrack(trackId);
>     } catch (error, stack) {
>       debugPrint('Queue selection failed: $error\n$stack');
>
>
>       if (!context.mounted) return;
>
>
>       ScaffoldMessenger.of(context).showSnackBar(
>         const SnackBar(
>           content: Text('暂时无法切换曲目，请重试'),
>         ),
>       );
>     }
>   }
>
>
>   @override
>   Widget build(BuildContext context) {
>     return FractionallySizedBox(
>       heightFactor: 0.78,
>       child: SafeArea(
>         top: false,
>         child: StreamBuilder<PlaybackQueueSnapshot>(
>           stream: handler.queueSnapshotStream,
>           initialData: handler.queueSnapshot,
>           builder: (context, state) {
>             final snapshot = state.data ?? handler.queueSnapshot;
>
>
>             return Column(
>               children: [
>                 Padding(
>                   padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
>                   child: Row(
>                     children: [
>                       Expanded(
>                         child: Column(
>                           crossAxisAlignment: CrossAxisAlignment.start,
>                           children: [
>                             const Text(
>                               '播放队列',
>                               style: AppTypography.title,
>                             ),
>                             const SizedBox(height: 4),
>                             Text(
>                               _modeLabel(snapshot),
>                               style: AppTypography.caption,
>                             ),
>                             const SizedBox(height: 4),
>                             Text(
>                               '共 ${snapshot.tracks.length} 首'
>                               ' · 后续 ${snapshot.upcomingCount} 首',
>                               style: AppTypography.caption,
>                             ),
>                           ],
>                         ),
>                       ),
>                       SizedBox(
>                         width: 48,
>                         height: 48,
>                         child: IconButton(
>                           tooltip: '关闭',
>                           onPressed: () => Navigator.of(context).pop(),
>                           icon: const Icon(Icons.close_rounded),
>                         ),
>                       ),
>                     ],
>                   ),
>                 ),
>                 Expanded(
>                   child: snapshot.tracks.isEmpty
>                       ? const Center(
>                           child: EmptyState(
>                             icon: Icons.queue_music_rounded,
>                             title: '队列为空',
>                             subtitle: '播放歌曲后，会在这里显示',
>                           ),
>                         )
>                       : ListView.builder(
>                           padding: const EdgeInsets.fromLTRB(
>                             20, 0, 20, 24,
>                           ),
>                           itemCount: snapshot.tracks.length,
>                           itemBuilder: (context, index) {
>                             final track = snapshot.tracks[index];
>                             final current =
>                                 index == snapshot.currentIndex;
>
>
>                             return Padding(
>                               key: ValueKey(track.id),
>                               padding: const EdgeInsets.only(
>                                 bottom: TrackRow.gap,
>                               ),
>                               child: Semantics(
>                                 selected: current,
>                                 child: TrackRow(
>                                   // "Current" describes logical selection,
>                                   // not whether playback is audible.
>                                   //
>                                   // Tapping it does not restart the song.
>                                   onTap: current
>                                       ? null
>                                       : () => _select(context, track.id),
>                                   child: Row(
>                                     children: [
>                                       ClipRRect(
>                                         borderRadius:
>                                             BorderRadius.circular(
>                                           AppRadius.sm,
>                                         ),
>                                         child: CachedCoverImage(
>                                           url: track.coverUrl,
>                                           width: 48,
>                                           height: 48,
>                                         ),
>                                       ),
>                                       const SizedBox(width: 12),
>                                       Expanded(
>                                         child: Column(
>                                           crossAxisAlignment:
>                                               CrossAxisAlignment.start,
>                                           children: [
>                                             MarqueeText(
>                                               text: track.title,
>                                               phase: (index % 5) / 5,
>                                               style: AppTypography.body
>                                                   .copyWith(
>                                                 fontWeight:
>                                                     FontWeight.w600,
>                                               ),
>                                             ),
>                                             const SizedBox(height: 3),
>                                             Text(
>                                               track.uploader,
>                                               maxLines: 1,
>                                               overflow:
>                                                   TextOverflow.ellipsis,
>                                               style:
>                                                   AppTypography.caption,
>                                             ),
>                                           ],
>                                         ),
>                                       ),
>                                       const SizedBox(width: 12),
>                                       if (current)
>                                         const Text(
>                                           '当前',
>                                           style: TextStyle(
>                                             color: AppColors.accent,
>                                             fontSize: 12,
>                                             fontWeight: FontWeight.w600,
>                                           ),
>                                         )
>                                       else
>                                         Text(
>                                           '${index + 1}',
>                                           style: AppTypography.caption,
>                                         ),
>                                     ],
>                                   ),
>                                 ),
>                               ),
>                             );
>                           },
>                         ),
>                 ),
>               ],
>             );
>           },
>         ),
>       ),
>     );
>   }
> }
> ```
>
> The modes are deliberately **read-only labels** here. Do not add disabled-looking shuffle/repeat icons that appear interactive.
>
> The list shows the entire logical order so the user can select an earlier track as well as an upcoming one. “后续” means positions after the current selection; it does not promise those items will advance while repeat-one is enabled.
>
> ### Open the sheet
>
> At the chosen Queue action in Now Playing:
>
> ```dart
> onPressed: () {
>   PlaybackQueueSheet.show(
>     context,
>     handler: widget.handler,
>   );
> },
> ```
>
> Import:
>
> ```dart
> import 'playback_queue_sheet.dart';
> ```
>
> Do not remove another player action or redesign the transport row as part of this technical patch. Wire the action into the agreed UI layout separately.
>
> ---
>
> # 8. Tests for this phase
>
> Add focused assertions for:
>
> 1. **Initial snapshot:** empty queue, index `-1`, existing default modes.
> 2. **Immutable list:** attempts to modify `snapshot.tracks` fail.
> 3. **Queue replacement:** tracks and current index arrive in the same snapshot.
> 4. **Shuffle:** published order matches `_playlist`, not `_naturalOrder`.
> 5. **Metadata edit:** same ID/new `Track` instance publishes updated metadata.
> 6. **Native advance:** snapshot current index follows tag-based reconciliation.
> 7. **Prefetch-only mutation:** no redundant logical snapshot emission.
> 8. **Stale displayed index:** clicking an ID after shuffle selects that ID.
> 9. **Removed item:** stale queue click does not reinsert it or start playback.
> 10. **System queue:** `audio_service.queue` order matches the snapshot’s track order.
> 11. **Repeat/shuffle state:** mode-only changes publish a new combined snapshot.
>
> ## Integration note
>
> The agent is changing local-only queue behavior concurrently. **The queue sheet must display exactly the handler’s resulting queue.** Do not filter nonlocal tracks again inside this widget; doing so would create a second interpretation of queue order and break index correspondence.
>
> This phase makes queue state observable. It does **not** resolve rapid-skip coalescing, native playback race validation, or the seven baseline failures. Keep those tracked independently.

---

*End of Astra messages. No further messages were received in this review
cycle. Phases 3 (download management) and 4 (sleep timer) were deferred by
Astra's own Phase order (see M5 §4) and have no implementation messages.*


















