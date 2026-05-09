import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/connection.dart';

/// A dedicated remote-control page:
///  • Top half  – live PC screen preview
///  • Bottom half – toggle between Trackpad / Keyboard
///  • Fullscreen button at the bottom to go immersive
class RemoteControlScreen extends StatefulWidget {
  final PcConnection? conn;
  final bool connected;

  const RemoteControlScreen({
    super.key,
    required this.conn,
    required this.connected,
  });

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  bool _screenOn = false;
  int _modeIndex = 0; // 0 = trackpad, 1 = keyboard

  @override
  void dispose() {
    if (_screenOn) widget.conn?.stopScreenCapture();
    super.dispose();
  }

  void _togglePreview(bool v) {
    setState(() => _screenOn = v);
    if (v) {
      widget.conn?.startScreenCapture(intervalMs: 800, width: 720, quality: 65);
    } else {
      widget.conn?.stopScreenCapture();
    }
  }

  void _openFullscreen() {
    if (!widget.connected) return;
    // Ensure preview is on
    if (!_screenOn) _togglePreview(true);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _FullscreenRemote(
        conn: widget.conn,
        initialMode: _modeIndex,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final conn = widget.conn;
    final enabled = widget.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote Control'),
        actions: [
          // Preview toggle
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Preview', style: TextStyle(fontSize: 12, color: cs.onSurface)),
              Switch(
                value: _screenOn,
                onChanged: enabled ? _togglePreview : null,
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── TOP: Screen Preview ──
          Expanded(
            flex: 5,
            child: _PreviewPanel(
              conn: conn,
              screenOn: _screenOn && enabled,
              cs: cs,
            ),
          ),

          // ── Mode toggle chips ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                _ModeChip(
                  icon: Icons.touch_app_rounded,
                  label: 'Trackpad',
                  selected: _modeIndex == 0,
                  onTap: () => setState(() => _modeIndex = 0),
                  cs: cs,
                ),
                const SizedBox(width: 8),
                _ModeChip(
                  icon: Icons.keyboard_rounded,
                  label: 'Keyboard',
                  selected: _modeIndex == 1,
                  onTap: () => setState(() => _modeIndex = 1),
                  cs: cs,
                ),
              ],
            ),
          ),

          // ── BOTTOM: Trackpad or Keyboard ──
          Expanded(
            flex: 5,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _modeIndex == 0
                  ? _EmbeddedTrackpad(key: const ValueKey('tp'), conn: conn, enabled: enabled)
                  : _EmbeddedKeyboard(key: const ValueKey('kb'), conn: conn, enabled: enabled),
            ),
          ),

          // ── Fullscreen button ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: enabled ? _openFullscreen : null,
                icon: const Icon(Icons.fullscreen_rounded, size: 24),
                label: const Text('Fullscreen', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// Mode toggle chip
// ─────────────────────────────────────────
class _ModeChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme cs;

  const _ModeChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: selected ? Border.all(color: cs.primary, width: 1.5) : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Preview panel
// ─────────────────────────────────────────
class _PreviewPanel extends StatelessWidget {
  final PcConnection? conn;
  final bool screenOn;
  final ColorScheme cs;

  const _PreviewPanel({required this.conn, required this.screenOn, required this.cs});

  @override
  Widget build(BuildContext context) {
    if (!screenOn || conn == null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.desktop_windows_rounded, size: 48, color: cs.onSurface.withValues(alpha: 0.2)),
              const SizedBox(height: 8),
              Text('Turn on Preview', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.3))),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ValueListenableBuilder<Uint8List?>(
        valueListenable: conn!.screenFrameNotifier,
        builder: (context, frame, _) {
          if (frame == null) {
            return Center(child: CircularProgressIndicator(color: cs.primary));
          }
          return Image.memory(
            frame,
            gaplessPlayback: true,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────
// Embedded Trackpad
// ─────────────────────────────────────────
class _EmbeddedTrackpad extends StatefulWidget {
  final PcConnection? conn;
  final bool enabled;
  const _EmbeddedTrackpad({super.key, required this.conn, required this.enabled});
  @override
  State<_EmbeddedTrackpad> createState() => _EmbeddedTrackpadState();
}

class _EmbeddedTrackpadState extends State<_EmbeddedTrackpad> {
  double _sensitivity = 1.4;
  bool _invertScroll = false;

  final Map<int, Offset> _pointers = {};
  Offset? _lastCentroid;
  double _accumDx = 0, _accumDy = 0, _accumWheel = 0;
  Timer? _flush;
  Timer? _longPress;
  bool _dragging = false;
  int? _dragPointer;
  Offset? _downPos;
  DateTime? _downTime;
  int _downPointerCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _sensitivity = prefs.getDouble('trackpad_sensitivity') ?? 1.4;
        _invertScroll = prefs.getBool('invert_scroll') ?? false;
      });
    }
  }

  @override
  void dispose() {
    _flush?.cancel();
    _longPress?.cancel();
    if (_dragging) widget.conn?.mouseButton(button: 'left', action: 'up');
    super.dispose();
  }

  void _startFlush() {
    _flush ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final dx = _accumDx.truncate(), dy = _accumDy.truncate(), w = _accumWheel.truncate();
      _accumDx -= dx; _accumDy -= dy; _accumWheel -= w;
      if (dx != 0 || dy != 0) widget.conn?.mouseMove(dx: dx, dy: dy);
      if (w != 0) widget.conn?.mouseScroll(dy: w);
      if (_pointers.isEmpty) { _flush?.cancel(); _flush = null; }
    });
  }

  Offset _centroid() {
    var sum = Offset.zero;
    for (final p in _pointers.values) sum += p;
    return sum / _pointers.length.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = widget.enabled;

    return Column(
      children: [
        Expanded(
          child: Listener(
            onPointerDown: !enabled ? null : (e) {
              _pointers[e.pointer] = e.localPosition;
              _downPos = e.localPosition;
              _downTime = DateTime.now();
              _downPointerCount = _pointers.length;
              if (_pointers.length == 1) {
                _longPress?.cancel();
                _longPress = Timer(const Duration(milliseconds: 350), () {
                  if (_pointers.length != 1) return;
                  final moved = (_pointers.values.first - _downPos!).distance;
                  if (moved > 8) return;
                  _dragging = true;
                  _dragPointer = e.pointer;
                  widget.conn?.mouseButton(button: 'left', action: 'down');
                });
              } else {
                _longPress?.cancel();
                _lastCentroid = _centroid();
              }
              _startFlush();
            },
            onPointerMove: !enabled ? null : (e) {
              final prev = _pointers[e.pointer];
              if (prev == null) return;
              _pointers[e.pointer] = e.localPosition;
              if (_pointers.length == 1) {
                final d = e.localPosition - prev;
                _accumDx += d.dx * _sensitivity;
                _accumDy += d.dy * _sensitivity;
              } else {
                final c = _centroid();
                if (_lastCentroid != null) {
                  final d = c - _lastCentroid!;
                  final scrollDir = _invertScroll ? 1.0 : -1.0;
                  _accumWheel += d.dy * scrollDir * 2.0;
                }
                _lastCentroid = c;
              }
            },
            onPointerUp: !enabled ? null : (e) {
              final pos = _pointers.remove(e.pointer);
              _longPress?.cancel();
              if (_dragging && _dragPointer == e.pointer) {
                widget.conn?.mouseButton(button: 'left', action: 'up');
                _dragging = false;
                _dragPointer = null;
                return;
              }
              if (pos != null && _pointers.isEmpty && _downTime != null) {
                final dt = DateTime.now().difference(_downTime!).inMilliseconds;
                final dist = (pos - _downPos!).distance;
                if (dt <= 220 && dist <= 10) {
                  if (_downPointerCount >= 2) {
                    widget.conn?.mouseButton(button: 'right', action: 'click');
                  } else {
                    widget.conn?.mouseButton(button: 'left', action: 'click');
                  }
                }
              }
              _lastCentroid = _pointers.length >= 2 ? _centroid() : null;
              _downPointerCount = _pointers.length;
            },
            onPointerCancel: !enabled ? null : (e) {
              _pointers.remove(e.pointer);
              _longPress?.cancel();
              if (_dragging && _dragPointer == e.pointer) {
                widget.conn?.mouseButton(button: 'left', action: 'up');
                _dragging = false;
              }
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.touch_app, size: 32, color: Colors.white24),
                    const SizedBox(height: 4),
                    const Text(
                      'Tap · 2-finger right click\nLong press drag · 2-finger scroll',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10, color: Colors.white24),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Mouse buttons
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: FilledButton.tonal(
                    onPressed: enabled ? () => widget.conn?.mouseButton(button: 'left', action: 'click') : null,
                    style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                    child: const Text('L', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: FilledButton.tonal(
                    onPressed: enabled ? () => widget.conn?.mouseButton(button: 'middle', action: 'click') : null,
                    style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                    child: const Text('M', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: FilledButton.tonal(
                    onPressed: enabled ? () => widget.conn?.mouseButton(button: 'right', action: 'click') : null,
                    style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                    child: const Text('R', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────
// Embedded Keyboard
// ─────────────────────────────────────────
class _EmbeddedKeyboard extends StatefulWidget {
  final PcConnection? conn;
  final bool enabled;
  const _EmbeddedKeyboard({super.key, required this.conn, required this.enabled});
  @override
  State<_EmbeddedKeyboard> createState() => _EmbeddedKeyboardState();
}

class _EmbeddedKeyboardState extends State<_EmbeddedKeyboard> {
  final _tc = TextEditingController();
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onText);
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _onText() {
    if (!widget.enabled) return;
    final current = _tc.text;
    final diff = TextDiff.compute(_lastText, current);
    _lastText = current;
    if (diff.backspaces == 0 && diff.inserted.isEmpty) return;
    widget.conn?.sendInput(backspaces: diff.backspaces, text: diff.inserted);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          TextField(
            controller: _tc,
            maxLines: 2,
            enabled: widget.enabled,
            decoration: InputDecoration(
              labelText: 'Type here → PC',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          // Shortcuts
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _chip('Ctrl+C', ['ctrl', 'c']),
                  _chip('Ctrl+V', ['ctrl', 'v']),
                  _chip('Ctrl+Z', ['ctrl', 'z']),
                  _chip('Ctrl+A', ['ctrl', 'a']),
                  _chip('Alt+Tab', ['alt', 'tab']),
                  _chip('Alt+F4', ['alt', 'f4']),
                  _chip('Win+D', ['win', 'd']),
                  _chip('Enter', ['enter']),
                  _chip('Esc', ['esc']),
                  _chip('Tab', ['tab']),
                  _chip('Del', ['delete']),
                ],
              ),
            ),
          ),
          // Arrow keys
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _arrowBtn(Icons.arrow_back, ['left']),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _arrowBtn(Icons.arrow_upward, ['up']),
                    _arrowBtn(Icons.arrow_downward, ['down']),
                  ],
                ),
                _arrowBtn(Icons.arrow_forward, ['right']),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, List<String> keys) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: widget.enabled ? () => widget.conn?.keyCombo(keys) : null,
    );
  }

  Widget _arrowBtn(IconData icon, List<String> keys) {
    return Padding(
      padding: const EdgeInsets.all(2),
      child: IconButton.filledTonal(
        iconSize: 20,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        onPressed: widget.enabled ? () => widget.conn?.keyCombo(keys) : null,
        icon: Icon(icon),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// FULLSCREEN REMOTE (immersive landscape)
// ═══════════════════════════════════════════
class _FullscreenRemote extends StatefulWidget {
  final PcConnection? conn;
  final int initialMode;
  const _FullscreenRemote({required this.conn, required this.initialMode});
  @override
  State<_FullscreenRemote> createState() => _FullscreenRemoteState();
}

class _FullscreenRemoteState extends State<_FullscreenRemote> {
  late int _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    // Force landscape + immersive
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    // Restore portrait + system UI
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Row(
          children: [
            // ── Left: Live preview ──
            Expanded(
              flex: 6,
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
                ),
                clipBehavior: Clip.antiAlias,
                child: widget.conn != null
                    ? ValueListenableBuilder<Uint8List?>(
                        valueListenable: widget.conn!.screenFrameNotifier,
                        builder: (_, frame, __) {
                          if (frame == null) {
                            return Center(child: CircularProgressIndicator(color: cs.primary));
                          }
                          return Image.memory(frame, gaplessPlayback: true, fit: BoxFit.contain);
                        },
                      )
                    : const Center(child: Text('No connection', style: TextStyle(color: Colors.white38))),
              ),
            ),

            // ── Right: controls ──
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  // Mode toggle + exit
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
                    child: Row(
                      children: [
                        _miniChip('Trackpad', _mode == 0, () => setState(() => _mode = 0), cs),
                        const SizedBox(width: 4),
                        _miniChip('Keyboard', _mode == 1, () => setState(() => _mode = 1), cs),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.fullscreen_exit, color: Colors.white70),
                          onPressed: () => Navigator.of(context).pop(),
                          tooltip: 'Exit Fullscreen',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _mode == 0
                        ? _EmbeddedTrackpad(conn: widget.conn, enabled: true)
                        : _EmbeddedKeyboard(conn: widget.conn, enabled: true),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniChip(String label, bool sel, VoidCallback onTap, ColorScheme cs) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: sel ? cs.primaryContainer : Colors.white10,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
            color: sel ? cs.primary : Colors.white54,
          ),
        ),
      ),
    );
  }
}
