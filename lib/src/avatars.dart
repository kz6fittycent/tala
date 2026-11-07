import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'nc_api.dart';

/// An avatar that's arrived or is on its way. [bytes] stays null when there's
/// nothing to show, and the letter is shown instead.
class AvatarImage {
  AvatarImage._(this.expires);
  Uint8List? bytes;
  late final Future<void> ready;
  DateTime expires;
}

/// Keeps avatars for the session. Only pictures people chose are fetched as
/// bytes: the server's generated letters and SVG defaults come back as null.
class AvatarStore {
  AvatarStore({
    required this.fetchUser,
    required this.fetchRoom,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<Uint8List?> Function(String userId) fetchUser;
  final Future<Uint8List?> Function(String token) fetchRoom;
  final DateTime Function() _now;

  /// A user's avatar has no version to notice a change by, so it's rechecked.
  static const _keep = Duration(hours: 1);
  static const _keepAfterError = Duration(minutes: 1);

  final Map<String, AvatarImage> _images = {};

  AvatarImage? forUser(String userId) =>
      userId.isEmpty ? null : _get('user:$userId', () => fetchUser(userId));

  /// One-to-ones show the other person, whom the server doesn't count as a
  /// custom avatar for the conversation. Other conversations show one only if a
  /// moderator set it, and its version changes when they change it.
  AvatarImage? forRoom(Room room) {
    if (room.type == 1) return forUser(room.otherUserId);
    if (!room.customAvatar) return null;
    return _get(
      'room:${room.token}:${room.avatarVersion}',
      () => fetchRoom(room.token),
    );
  }

  AvatarImage _get(String key, Future<Uint8List?> Function() fetch) {
    final known = _images[key];
    if (known != null && known.expires.isAfter(_now())) return known;
    final image = AvatarImage._(_now().add(_keep));
    image.ready = () async {
      try {
        image.bytes = await fetch();
      } catch (_) {
        // Not logged: the address holds a user id. The letter stays for now.
        image.expires = _now().add(_keepAfterError);
      }
    }();
    _images[key] = image;
    return image;
  }
}

/// A person or conversation's picture in a circle, or the first letter of their
/// name in the accent color until one arrives or if there's none.
class Avatar extends StatefulWidget {
  const Avatar({super.key, required this.name, this.image, this.radius = 20});
  final String name;
  final AvatarImage? image;
  final double radius;

  @override
  State<Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<Avatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(Avatar old) {
    super.didUpdateWidget(old);
    if (!identical(old.image, widget.image)) _follow();
  }

  void _follow() {
    final image = widget.image;
    _bytes = image?.bytes;
    if (image == null || _bytes != null) return;
    image.ready.then((_) {
      if (mounted && identical(widget.image, image) && image.bytes != null) {
        setState(() => _bytes = image.bytes);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: widget.radius,
        backgroundColor:
            Theme.of(context).extension<AvatarColors>()?.background ?? talaBlue,
        foregroundColor: Colors.white,
        foregroundImage: bytes == null ? null : MemoryImage(bytes),
        // A picture that won't decode just leaves the letter showing.
        onForegroundImageError: bytes == null ? null : (_, _) {},
        // White on the icon's blue is 4.17:1, which needs large, bold text, so
        // this size doesn't shrink with the circle.
        child: Text(
          widget.name.isEmpty
              ? '?'
              : widget.name.characters.first.toUpperCase(),
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
