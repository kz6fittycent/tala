import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'log.dart';
import 'paths.dart';

/// What goes behind the user in their camera video: nothing, a blur, one of
/// Tala's pictures (assets/backgrounds, drawn by tool/make_backgrounds.py) or
/// the user's own. Stored in settings by [id], so keep the ids.
class CallBackground {
  const CallBackground._(this.id, this.label);

  final String id;
  final String label;

  static const none = CallBackground._('none', 'None');
  static const blur = CallBackground._('blur', 'Blur');
  static const own = CallBackground._('own', 'Your picture');
  static const builtIn = [
    CallBackground._('sky', 'Sky'),
    CallBackground._('wall', 'Wall'),
    CallBackground._('hills', 'Hills'),
    CallBackground._('leaves', 'Leaves'),
    CallBackground._('lights', 'Lights'),
  ];

  static CallBackground fromId(String? id) {
    for (final b in [none, blur, own, ...builtIn]) {
      if (b.id == id) return b;
    }
    return none;
  }

  bool get isPicture => this != none && this != blur;

  /// The full picture, for built-in ones.
  String? get asset => builtIn.contains(this)
      ? 'assets/backgrounds/$id.jpg'
      : null;

  /// A small copy for the picker, for built-in ones.
  String? get thumbnail => builtIn.contains(this)
      ? 'assets/backgrounds/$id-small.jpg'
      : null;
}

/// Where the user's own picture is kept: a copy, so it still works after the
/// original moves, and so the snap needn't reach outside its folder again.
File ownBackgroundFile({Directory? dir}) =>
    File('${(dir ?? configDir).path}/background-picture');

/// Copies the user's chosen picture in, after checking it decodes. Returns
/// false if it isn't a picture Tala can read.
Future<bool> saveOwnBackground(Uint8List bytes, {Directory? dir}) async {
  if (await decodeBackground(bytes) == null) return false;
  final file = ownBackgroundFile(dir: dir);
  try {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    return true;
  } on FileSystemException catch (e) {
    log('background: could not be saved: ${e.osError?.message}');
    return false;
  }
}

/// A picture decoded for the camera: RGBA, rows packed.
class BackgroundPicture {
  const BackgroundPicture(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width, height;
}

/// Pictures are shrunk to fit this before going to the camera's processor;
/// cameras send at most 1080p, and a 4000 wide photo would just cost memory.
const maxBackgroundWidth = 1920, maxBackgroundHeight = 1080;

/// The largest size within the limits with the picture's shape, never larger
/// than it was.
(int, int) backgroundSize(int width, int height) {
  if (width <= maxBackgroundWidth && height <= maxBackgroundHeight) {
    return (width, height);
  }
  final scale = [
    maxBackgroundWidth / width,
    maxBackgroundHeight / height,
  ].reduce((a, b) => a < b ? a : b);
  return (
    (width * scale).round().clamp(1, maxBackgroundWidth),
    (height * scale).round().clamp(1, maxBackgroundHeight),
  );
}

/// Decodes JPEG, PNG, WebP, GIF or BMP, shrunk to fit; null if it can't.
Future<BackgroundPicture?> decodeBackground(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        final (tw, th) = backgroundSize(w, h);
        return ui.TargetImageSize(width: tw, height: th);
      },
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = data == null
        ? null
        : BackgroundPicture(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            image.width,
            image.height,
          );
    image.dispose();
    return result;
  } catch (e) {
    log('background: could not be decoded: ${e.runtimeType}');
    return null;
  }
}

/// The picture for [background], or null for none, blur, or one that can't
/// be read.
Future<BackgroundPicture?> loadBackground(CallBackground background,
    {AssetBundle? bundle, Directory? dir}) async {
  try {
    final Uint8List bytes;
    if (background == CallBackground.own) {
      final file = ownBackgroundFile(dir: dir);
      if (!await file.exists()) return null;
      bytes = await file.readAsBytes();
    } else if (background.asset != null) {
      final data = await (bundle ?? rootBundle).load(background.asset!);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      return null;
    }
    return await decodeBackground(bytes);
  } on FileSystemException catch (e) {
    log('background: could not be read: ${e.osError?.message}');
    return null;
  }
}
