import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'backgrounds.dart';
import 'log.dart';

/// Changes touch up at once, while the picker is open: on or off, and how
/// much. Returns false if it couldn't be done.
typedef TouchUpChange = Future<bool> Function(bool on, double amount);

/// Lets the user pick what goes behind them in a call. Returns the choice,
/// or null if they closed it without one. With [onTouchUp], it also has
/// touch up, which takes effect as it's changed.
Future<CallBackground?> showBackgroundPicker(
  BuildContext context,
  CallBackground current, {
  Directory? dir,
  Future<Uint8List?> Function()? choosePicture,
  bool touchUpOn = false,
  double touchUp = 0.5,
  TouchUpChange? onTouchUp,
}) {
  return showDialog<CallBackground>(
    context: context,
    builder: (_) => BackgroundPicker(
      current: current,
      dir: dir,
      choosePicture: choosePicture ?? _pickPictureFile,
      touchUpOn: touchUpOn,
      touchUp: touchUp,
      onTouchUp: onTouchUp,
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
    this.touchUpOn = false,
    this.touchUp = 0.5,
    this.onTouchUp,
  });

  final CallBackground current;
  final Future<Uint8List?> Function() choosePicture;
  final Directory? dir;
  final bool touchUpOn;
  final double touchUp;
  final TouchUpChange? onTouchUp;

  @override
  State<BackgroundPicker> createState() => _BackgroundPickerState();
}

class _BackgroundPickerState extends State<BackgroundPicker> {
  /// The user's saved picture, read once rather than through an image cache
  /// that wouldn't notice it being replaced.
  Uint8List? _own;
  bool _busy = false;
  String? _error;
  late bool _touchUpOn = widget.touchUpOn;
  late double _touchUp = widget.touchUp.clamp(0.1, 1.0);

  Future<void> _changeTouchUp(bool on, double amount) async {
    final before = (_touchUpOn, _touchUp);
    setState(() {
      _touchUpOn = on;
      _touchUp = amount;
      _error = null;
    });
    final ok = await widget.onTouchUp!(on, amount);
    if (!ok && mounted) {
      setState(() {
        _touchUpOn = before.$1;
        _touchUp = before.$2;
        _error = 'Couldn\'t touch up your video.';
      });
    }
  }

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
              if (widget.onTouchUp != null) ...[
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Touch up appearance'),
                  subtitle: const Text('Softens fine detail on your skin.'),
                  value: _touchUpOn,
                  onChanged: (on) => _changeTouchUp(on, _touchUp),
                ),
                Slider(
                  value: _touchUp,
                  min: 0.1,
                  label: '${(_touchUp * 100).round()}%',
                  divisions: 9,
                  semanticFormatterCallback: (v) =>
                      'Touch up ${(v * 100).round()}%',
                  // Taken up on release rather than at every step of a drag.
                  onChanged: _touchUpOn
                      ? (v) => setState(() => _touchUp = v)
                      : null,
                  onChangeEnd: _touchUpOn
                      ? (v) => _changeTouchUp(true, v)
                      : null,
                ),
              ],
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
