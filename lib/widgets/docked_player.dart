import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../screens/now_playing_page.dart';
import 'mini_player.dart';

/// The mini player as every page carries it at its bottom edge: tapping it
/// opens the full player, growing out of the card's own rectangle.
class DockedPlayer extends StatefulWidget {
  const DockedPlayer({super.key});

  @override
  State<DockedPlayer> createState() => _DockedPlayerState();
}

class _DockedPlayerState extends State<DockedPlayer> {
  final GlobalKey _key = GlobalKey();

  void _open() {
    FocusManager.instance.primaryFocus?.unfocus();
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    final rect = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    unawaited(NowPlayingPage.open(context, from: rect));
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: MiniPlayer(
        handler: AppServices.instance.handler,
        onTap: _open,
      ),
    );
  }
}
