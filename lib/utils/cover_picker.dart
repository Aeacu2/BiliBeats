import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Lets the user pick an image and copies it into the app's cover folder.
/// Returns the saved path, or null when nothing was picked.
Future<String?> pickCoverImage(String prefix) async {
  try {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null) return null;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/bilibeat_covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = image.path.split('.').last;
    final saved = File(
        '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await File(image.path).copy(saved.path);
    return saved.path;
  } catch (e) {
    debugPrint('Cover pick failed: $e');
    return null;
  }
}
