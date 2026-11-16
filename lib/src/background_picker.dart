import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'backgrounds.dart';
import 'log.dart';

/// Lets the user pick what goes behind them in a call. Returns the choice,
/// or null if they closed it without one.
Future<CallBackground?> showBackgroundPicker(
  BuildContext context,
  CallBackground current, {
  Directory? dir,
  Future<Uint8List?> Function()? choosePicture,
}) {
  return showDialog<CallBackground>(
    context: context,
    builder: (_) => BackgroundPicker(
      current: current,
      dir: dir,
      choosePicture: choosePicture ?? _pickPictureFile,
    ),
  );
}

Future<Uint8List?> _pickPictureFile() async {
  final file = await openFile(acceptedTypeGroups: const [
    XTypeGroup(
      label: 'Pictures',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
      mimeTypes: [
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/gif',
        'image/bmp',
      ],
    ),
  ]);
  return file?.readAsBytes();
}

class BackgroundPicker extends StatefulWidget {
  const BackgroundPicker({
    super.key,
    required this.current,
    required this.choosePicture,
    this.dir,
  });

  final CallBackground current;
  final Future<Uint8List?> Function() choosePicture;
  final Directory? dir;

  @override
  State<BackgroundPicker> createState() => _BackgroundPickerState();
}

class _BackgroundPickerState extends State<BackgroundPicker> {
  /// The user's saved picture, read once rather than through an image cache
  /// that wouldn't notice it being replaced.
  Uint8List? _own;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Small and local, so read at once rather than flashing the tile in.
    try {
      final f = ownBackgroundFile(dir: widget.dir);
      if (f.existsSync()) _own = f.readAsBytesSync();
    } on FileSystemException catch (e) {
      log('background: could not be read: ${e.osError?.message}');
    }
  }

  Future<void> _choose() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await widget.choosePicture();
      if (bytes == null) return;
      if (await saveOwnBackground(bytes, dir: widget.dir)) {
        if (mounted) Navigator.of(context).pop(CallBackground.own);
      } else if (mounted) {
        setState(() => _error = 'Tala couldn\'t read that picture.');
      }
    } catch (e) {
      log('background: choosing failed: ${e.runtimeType}');
      if (mounted) setState(() => _error = 'Tala couldn\'t open that file.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget icon(IconData i) => ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Center(child: Icon(i, size: 28, color: scheme.onSurface)),
        );
    final tiles = <Widget>[
      _Tile(
        label: CallBackground.none.label,
        selected: widget.current == CallBackground.none,
        onTap: () => Navigator.of(context).pop(CallBackground.none),
        child: icon(Icons.block),
      ),
      _Tile(
        label: CallBackground.blur.label,
        selected: widget.current == CallBackground.blur,
        onTap: () => Navigator.of(context).pop(CallBackground.blur),
        child: icon(Icons.blur_on),
      ),
      for (final b in CallBackground.builtIn)
        _Tile(
          label: b.label,
          selected: widget.current == b,
          onTap: () => Navigator.of(context).pop(b),
          child: Image.asset(b.thumbnail!, fit: BoxFit.cover),
        ),
      if (_own != null)
        _Tile(
          label: CallBackground.own.label,
          selected: widget.current == CallBackground.own,
          onTap: () => Navigator.of(context).pop(CallBackground.own),
          child: Image.memory(
            _own!,
            fit: BoxFit.cover,
            cacheWidth: 240,
            errorBuilder: (_, _, _) => icon(Icons.broken_image_outlined),
          ),
        ),
      _Tile(
        label: _own == null ? 'Add a picture…' : 'Change picture…',
        selected: false,
        onTap: _busy ? null : _choose,
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : icon(Icons.add_photo_alternate_outlined),
      ),
    ];
    return AlertDialog(
      title: const Text('Background'),
      content: SizedBox(
        width: 3 * _Tile.width + 2 * 12,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Others see this behind you. It\'s done on this computer.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 12, runSpacing: 12, children: tiles),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  static const double width = 128;

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: width,
            child: Column(
              children: [
                Container(
                  width: width,
                  height: width * 9 / 16,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? scheme.primary : scheme.outlineVariant,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: child,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? scheme.primary : null,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
