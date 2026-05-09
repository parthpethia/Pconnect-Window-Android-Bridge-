import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/connection.dart';
import '../main.dart';
import 'discovery_screen.dart';

class SettingsScreen extends StatefulWidget {
  final PcConnection? conn;
  final ConnectionStatus status;
  final VoidCallback onDisconnect;

  const SettingsScreen({
    super.key,
    required this.conn,
    required this.status,
    required this.onDisconnect,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autoLock = false;
  double _sensitivity = 1.4;
  bool _invertScroll = false;
  bool _autoClipboardSync = true;
  List<ConnectionProfile> _profiles = [];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadProfiles();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoLock = prefs.getBool('auto_lock_on_disconnect') ?? false;
      _sensitivity = prefs.getDouble('trackpad_sensitivity') ?? 1.4;
      _invertScroll = prefs.getBool('invert_scroll') ?? false;
      _autoClipboardSync = prefs.getBool('auto_clipboard_sync') ?? true;
    });
  }

  Future<void> _loadProfiles() async {
    final profiles = await ProfileStore.load();
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _saveAutoLock(bool v) async {
    setState(() => _autoLock = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_lock_on_disconnect', v);
    widget.conn?.settingsSync(autoLockOnDisconnect: v);
  }

  Future<void> _saveSensitivity(double v) async {
    setState(() => _sensitivity = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('trackpad_sensitivity', v);
  }

  Future<void> _saveInvertScroll(bool v) async {
    setState(() => _invertScroll = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('invert_scroll', v);
  }

  Future<void> _saveAutoClipboardSync(bool v) async {
    setState(() => _autoClipboardSync = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_clipboard_sync', v);
  }

  Future<void> _deleteProfile(int index) async {
    final p = _profiles[index];
    await ProfileStore.remove(p.ip, p.port);
    await _loadProfiles();
  }

  Future<void> _renameProfile(int index) async {
    final p = _profiles[index];
    final controller = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Profile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Profile name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      p.name = name;
      final all = await ProfileStore.load();
      final idx = all.indexWhere((x) => x.ip == p.ip && x.port == p.port);
      if (idx >= 0) {
        all[idx].name = name;
        await ProfileStore.save(all);
        await _loadProfiles();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = widget.status.connected;
    final themeCtrl = ThemeControllerScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // ── Connection ──
          _SectionHeader('Connection'),
          ListTile(
            leading: Icon(connected ? Icons.link : Icons.link_off,
                color: connected ? Colors.green : cs.error),
            title: Text(connected ? 'Connected to ${widget.status.pcName ?? "PC"}' : 'Disconnected'),
            subtitle: widget.status.role != null ? Text('Role: ${widget.status.role}') : null,
            trailing: connected
                ? TextButton(onPressed: widget.onDisconnect, child: const Text('Disconnect'))
                : null,
          ),
          const Divider(),

          // ── Security ──
          _SectionHeader('Security'),
          SwitchListTile(
            title: const Text('Auto-lock on disconnect'),
            subtitle: const Text('Lock PC 10s after connection drops'),
            value: _autoLock,
            onChanged: connected ? _saveAutoLock : null,
          ),
          const Divider(),

          // ── Trackpad ──
          _SectionHeader('Trackpad'),
          ListTile(
            title: Row(
              children: [
                const Text('Sensitivity'),
                const Spacer(),
                Text(
                  _sensitivity.toStringAsFixed(1),
                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            subtitle: Slider(
              value: _sensitivity,
              min: 0.5, max: 3.0,
              divisions: 25,
              label: _sensitivity.toStringAsFixed(1),
              onChanged: (v) => _saveSensitivity(v),
            ),
          ),
          SwitchListTile(
            title: const Text('Invert scroll direction'),
            value: _invertScroll,
            onChanged: (v) => _saveInvertScroll(v),
          ),
          const Divider(),

          // ── Clipboard Sync ──
          _SectionHeader('Clipboard Sync'),
          SwitchListTile(
            title: const Text('Auto-sync clipboard'),
            subtitle: const Text('Automatically sync clipboard on connect'),
            value: _autoClipboardSync,
            onChanged: _saveAutoClipboardSync,
          ),
          ListTile(
            leading: const Icon(Icons.content_paste_go_rounded),
            title: const Text('Send phone clipboard to PC'),
            onTap: connected ? () async {
              final data = await Clipboard.getData('text/plain');
              if (data?.text != null && data!.text!.isNotEmpty) {
                widget.conn?.setClipboard(text: data.text!);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Clipboard sent to PC')),
                  );
                }
              }
            } : null,
          ),
          if (connected && widget.conn != null)
            ValueListenableBuilder<List<String>>(
              valueListenable: widget.conn!.clipboardHistoryNotifier,
              builder: (context, history, _) {
                if (history.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('Recent Clipboard',
                          style: TextStyle(fontSize: 12, color: cs.outline)),
                    ),
                    ...history.take(5).map((text) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.content_copy, size: 16),
                      title: Text(
                        text.length > 80 ? '${text.substring(0, 80)}...' : text,
                        style: const TextStyle(fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Copied to phone clipboard')),
                          );
                        }
                      },
                    )),
                  ],
                );
              },
            ),
          const Divider(),

          // ── Saved Profiles ──
          _SectionHeader('Saved PCs'),
          if (_profiles.isEmpty)
            const ListTile(
              title: Text('No saved profiles'),
              subtitle: Text('Connect to a PC to save it here'),
            ),
          ...List.generate(_profiles.length, (i) {
            final p = _profiles[i];
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: cs.secondaryContainer,
                radius: 18,
                child: Icon(Icons.computer_rounded, size: 18, color: cs.onSecondaryContainer),
              ),
              title: Text(p.name.isEmpty ? p.ip : p.name),
              subtitle: Text('${p.ip}:${p.port}'),
              trailing: PopupMenuButton<String>(
                onSelected: (val) {
                  if (val == 'rename') _renameProfile(i);
                  if (val == 'delete') _deleteProfile(i);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(value: 'delete', child: Text('Forget')),
                ],
              ),
            );
          }),
          const Divider(),

          // ── Appearance ──
          _SectionHeader('Appearance'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeCtrl,
            builder: (context, mode, _) {
              return Column(
                children: [
                  RadioListTile<ThemeMode>(
                    title: const Text('Dark'),
                    value: ThemeMode.dark,
                    groupValue: mode,
                    onChanged: (v) => themeCtrl.setMode(v!),
                  ),
                  RadioListTile<ThemeMode>(
                    title: const Text('Light'),
                    value: ThemeMode.light,
                    groupValue: mode,
                    onChanged: (v) => themeCtrl.setMode(v!),
                  ),
                  RadioListTile<ThemeMode>(
                    title: const Text('System'),
                    value: ThemeMode.system,
                    groupValue: mode,
                    onChanged: (v) => themeCtrl.setMode(v!),
                  ),
                ],
              );
            },
          ),
          const Divider(),

          // ── About ──
          _SectionHeader('About'),
          const ListTile(
            title: Text('Pconnect'),
            subtitle: Text('v0.2.0 • LAN Remote Control'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: TextStyle(
        fontSize: 13, fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
      )),
    );
  }
}
