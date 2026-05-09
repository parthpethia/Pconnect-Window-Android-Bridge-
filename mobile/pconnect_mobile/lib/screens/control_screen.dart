import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/connection.dart';

class ControlScreen extends StatelessWidget {
  final PcConnection? conn;
  final ConnectionStatus status;
  const ControlScreen({super.key, required this.conn, required this.status});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Control'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.touch_app_rounded), text: 'Trackpad'),
              Tab(icon: Icon(Icons.keyboard_rounded), text: 'Keyboard'),
              Tab(icon: Icon(Icons.bolt_rounded), text: 'Macros'),
              Tab(icon: Icon(Icons.slideshow_rounded), text: 'Present'),
            ],
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _TrackpadTab(conn: conn, enabled: status.connected),
            _KeyboardTab(conn: conn, enabled: status.connected),
            _MacrosTab(conn: conn, status: status),
            _PresentTab(conn: conn, enabled: status.connected),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════
// TRACKPAD TAB (with gyroscope mode)
// ═══════════════════════════════════════

class _TrackpadTab extends StatefulWidget {
  final PcConnection? conn;
  final bool enabled;
  const _TrackpadTab({required this.conn, required this.enabled});
  @override
  State<_TrackpadTab> createState() => _TrackpadTabState();
}

class _TrackpadTabState extends State<_TrackpadTab> {
  double _sensitivity = 1.4;
  bool _invertScroll = false;
  bool _gyroMode = false;

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

  // Gyroscope
  StreamSubscription? _gyroSub;
  static const double _gyroScale = 8.0;

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
    _gyroSub?.cancel();
    if (_dragging) widget.conn?.mouseButton(button: 'left', action: 'up');
    super.dispose();
  }

  void _toggleGyro() {
    setState(() => _gyroMode = !_gyroMode);
    if (_gyroMode) {
      _gyroSub = gyroscopeEventStream(
        samplingPeriod: const Duration(milliseconds: 16),
      ).listen((event) {
        // event.y = rotation around Y axis (phone tilting left/right) → horizontal mouse
        // event.x = rotation around X axis (phone tilting forward/back) → vertical mouse
        final dx = (event.y * _gyroScale * _sensitivity).round();
        final dy = (-event.x * _gyroScale * _sensitivity).round();
        if (dx != 0 || dy != 0) {
          widget.conn?.mouseMove(dx: dx, dy: dy);
        }
      });
    } else {
      _gyroSub?.cancel();
      _gyroSub = null;
    }
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

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return const Center(child: Text('Connect to a PC first'));
    }
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Gyroscope toggle bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Icon(
                _gyroMode ? Icons.screen_rotation_rounded : Icons.touch_app_rounded,
                size: 18,
                color: cs.primary,
              ),
              const SizedBox(width: 8),
              Text(
                _gyroMode ? 'Gyroscope Mode' : 'Touch Mode',
                style: TextStyle(fontSize: 13, color: cs.onSurface),
              ),
              const Spacer(),
              Switch(
                value: _gyroMode,
                onChanged: (_) => _toggleGyro(),
              ),
            ],
          ),
        ),
        // Touch surface
        Expanded(
          child: Listener(
            onPointerDown: (e) {
              if (_gyroMode) return; // Gyro mode ignores touch for movement
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
            onPointerMove: (e) {
              if (_gyroMode) return;
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
            onPointerUp: (e) {
              if (_gyroMode) {
                // In gyro mode, taps still register as clicks
                _pointers.remove(e.pointer);
                return;
              }
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
                  // Two-finger tap = right click
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
            onPointerCancel: (e) {
              _pointers.remove(e.pointer);
              _longPress?.cancel();
              if (_dragging && _dragPointer == e.pointer) {
                widget.conn?.mouseButton(button: 'left', action: 'up');
                _dragging = false;
              }
            },
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                border: _gyroMode
                    ? Border.all(color: cs.primary.withOpacity(0.5), width: 2)
                    : null,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _gyroMode ? Icons.screen_rotation_rounded : Icons.touch_app,
                      size: 48,
                      color: Colors.white24,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _gyroMode ? 'Tilt phone to move cursor' : 'Touch surface',
                      style: const TextStyle(color: Colors.white38),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _gyroMode
                          ? 'Use buttons below for clicks'
                          : 'Tap: left click • 2-finger tap: right click\nLong press: drag • 2 fingers: scroll',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: Colors.white24),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Bottom buttons
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => widget.conn?.mouseButton(button: 'left', action: 'click'),
                  child: const Text('Left Click'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => widget.conn?.mouseButton(button: 'middle', action: 'click'),
                  child: const Text('Middle'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => widget.conn?.mouseButton(button: 'right', action: 'click'),
                  child: const Text('Right Click'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Offset _centroid() {
    var sum = Offset.zero;
    for (final p in _pointers.values) sum += p;
    return sum / _pointers.length.toDouble();
  }
}

// ═══════════════════════════════════════
// KEYBOARD TAB
// ═══════════════════════════════════════

class _KeyboardTab extends StatefulWidget {
  final PcConnection? conn;
  final bool enabled;
  const _KeyboardTab({required this.conn, required this.enabled});
  @override
  State<_KeyboardTab> createState() => _KeyboardTabState();
}

class _KeyboardTabState extends State<_KeyboardTab> {
  final _textController = TextEditingController();
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!widget.enabled) return;
    final current = _textController.text;
    final diff = TextDiff.compute(_lastText, current);
    _lastText = current;
    if (diff.backspaces == 0 && diff.inserted.isEmpty) return;
    widget.conn?.sendInput(backspaces: diff.backspaces, text: diff.inserted);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const Center(child: Text('Connect to a PC first'));

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _textController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Type here → PC',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          // Shortcuts grid
          Text('Shortcuts', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _shortcut('Ctrl+C', ['ctrl', 'c']),
              _shortcut('Ctrl+V', ['ctrl', 'v']),
              _shortcut('Ctrl+X', ['ctrl', 'x']),
              _shortcut('Ctrl+Z', ['ctrl', 'z']),
              _shortcut('Ctrl+A', ['ctrl', 'a']),
              _shortcut('Ctrl+S', ['ctrl', 's']),
              _shortcut('Alt+Tab', ['alt', 'tab']),
              _shortcut('Alt+F4', ['alt', 'f4']),
              _shortcut('Win+D', ['win', 'd']),
              _shortcut('Win+L', ['win', 'l']),
              _shortcut('Win+E', ['win', 'e']),
              _shortcut('Ctrl+Shift+Esc', ['ctrl', 'shift', 'esc']),
              _shortcut('Enter', ['enter']),
              _shortcut('Esc', ['esc']),
              _shortcut('Tab', ['tab']),
              _shortcut('Del', ['delete']),
              _shortcut('PrtSc', ['printscreen']),
            ],
          ),
          const SizedBox(height: 12),
          // Arrow keys
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(width: 48),
              _arrowBtn(Icons.arrow_upward, ['up']),
              const SizedBox(width: 48),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _arrowBtn(Icons.arrow_back, ['left']),
              _arrowBtn(Icons.arrow_downward, ['down']),
              _arrowBtn(Icons.arrow_forward, ['right']),
            ],
          ),
        ],
      ),
    );
  }

  Widget _shortcut(String label, List<String> keys) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: () => widget.conn?.keyCombo(keys),
    );
  }

  Widget _arrowBtn(IconData icon, List<String> keys) {
    return Padding(
      padding: const EdgeInsets.all(2),
      child: IconButton.filledTonal(
        onPressed: () => widget.conn?.keyCombo(keys),
        icon: Icon(icon),
      ),
    );
  }
}

// ═══════════════════════════════════════
// MACROS TAB
// ═══════════════════════════════════════

class _MacrosTab extends StatelessWidget {
  final PcConnection? conn;
  final ConnectionStatus status;
  const _MacrosTab({required this.conn, required this.status});

  @override
  Widget build(BuildContext context) {
    if (!status.connected || conn == null) {
      return const Center(child: Text('Connect to a PC first'));
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // ── Custom Commands from PC ──
        Text('Custom Commands', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Edit commands.json on PC to add more',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 8),
        ValueListenableBuilder<List<CustomCommand>>(
          valueListenable: conn!.commandListNotifier,
          builder: (context, cmds, _) {
            if (cmds.isEmpty) {
              return FilledButton.tonal(
                onPressed: () => conn!.requestCommands(),
                child: const Text('Load Commands'),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < cmds.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonal(
                        onPressed: () => conn!.runCommand(i),
                        child: Text(cmds[i].label),
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: () => conn!.requestCommands(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                ),
              ],
            );
          },
        ),
        const Divider(height: 32),

        // ── Built-in shortcuts ──
        Text('Built-in Shortcuts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _macro(context, 'Copy', ['ctrl', 'c']),
            _macro(context, 'Paste', ['ctrl', 'v']),
            _macro(context, 'Cut', ['ctrl', 'x']),
            _macro(context, 'Undo', ['ctrl', 'z']),
            _macro(context, 'Redo', ['ctrl', 'shift', 'z']),
            _macro(context, 'Select All', ['ctrl', 'a']),
            _macro(context, 'Save', ['ctrl', 's']),
            _macro(context, 'Find', ['ctrl', 'f']),
            _macro(context, 'Close', ['alt', 'f4']),
            _macro(context, 'Desktop', ['win', 'd']),
            _macro(context, 'Lock', ['win', 'l']),
            _macro(context, 'Explorer', ['win', 'e']),
            _macro(context, 'Run', ['win', 'r']),
            _macro(context, 'Task Mgr', ['ctrl', 'shift', 'esc']),
            _macro(context, 'New Tab', ['ctrl', 't']),
            _macro(context, 'Close Tab', ['ctrl', 'w']),
            _macro(context, 'Switch App', ['alt', 'tab']),
          ],
        ),
      ],
    );
  }

  Widget _macro(BuildContext context, String label, List<String> keys) {
    return ActionChip(
      label: Text(label),
      avatar: const Icon(Icons.keyboard_command_key, size: 16),
      onPressed: () => conn?.keyCombo(keys),
    );
  }
}

// ═══════════════════════════════════════
// PRESENT TAB
// ═══════════════════════════════════════

class _PresentTab extends StatefulWidget {
  final PcConnection? conn;
  final bool enabled;
  const _PresentTab({required this.conn, required this.enabled});
  @override
  State<_PresentTab> createState() => _PresentTabState();
}

class _PresentTabState extends State<_PresentTab> {
  int _timerSeconds = 0;
  Timer? _timer;
  bool _timerRunning = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggleTimer() {
    if (_timerRunning) {
      _timer?.cancel();
      setState(() => _timerRunning = false);
    } else {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _timerSeconds++);
      });
      setState(() => _timerRunning = true);
    }
  }

  void _resetTimer() {
    _timer?.cancel();
    setState(() { _timerSeconds = 0; _timerRunning = false; });
  }

  String get _timerDisplay {
    final m = _timerSeconds ~/ 60;
    final s = _timerSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const Center(child: Text('Connect to a PC first'));

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Timer
          Text(_timerDisplay, style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w200, fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.tonal(
                onPressed: _toggleTimer,
                child: Text(_timerRunning ? 'Pause' : 'Start'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _resetTimer, child: const Text('Reset')),
            ],
          ),
          const SizedBox(height: 48),
          // Prev / Next
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 100,
                  child: FilledButton.tonal(
                    onPressed: () => widget.conn?.keyCombo(['left']),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chevron_left, size: 32),
                        SizedBox(width: 4),
                        Text('PREV', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 100,
                  child: FilledButton(
                    onPressed: () => widget.conn?.keyCombo(['right']),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('NEXT', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        SizedBox(width: 4),
                        Icon(Icons.chevron_right, size: 32),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Blank Screen
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => widget.conn?.keyCombo(['b']),
              icon: const Icon(Icons.visibility_off),
              label: const Text('Blank Screen (B)'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => widget.conn?.keyCombo(['esc']),
              icon: const Icon(Icons.stop_rounded),
              label: const Text('End Show (Esc)'),
            ),
          ),
        ],
      ),
    );
  }
}
