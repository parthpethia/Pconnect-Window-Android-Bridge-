import 'package:flutter/material.dart';
import '../services/connection.dart';

class LogsScreen extends StatefulWidget {
  final PcConnection? conn;
  final ConnectionStatus status;
  const LogsScreen({super.key, required this.conn, required this.status});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String _selectedDate = _today();
  String _searchQuery = '';
  String? _filterAction;

  static String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    if (widget.status.connected) {
      widget.conn?.requestLogs(_selectedDate);
    }
  }

  @override
  void didUpdateWidget(LogsScreen old) {
    super.didUpdateWidget(old);
    if (widget.status.connected && !old.status.connected) {
      widget.conn?.requestLogs(_selectedDate);
    }
  }

  void _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_selectedDate) ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      final date = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      setState(() => _selectedDate = date);
      widget.conn?.requestLogs(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.status.connected || widget.conn == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Logs')),
        body: const Center(child: Text('Connect to a PC to view logs')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            tooltip: 'Pick date',
            onPressed: _pickDate,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => widget.conn?.requestLogs(_selectedDate),
          ),
        ],
      ),
      body: Column(
        children: [
          // Date chip + search
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_selectedDate),
                  onPressed: _pickDate,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search...',
                      prefixIcon: Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
                  ),
                ),
              ],
            ),
          ),
          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChip(null, 'All'),
                  _filterChip('connected', 'Connected'),
                  _filterChip('disconnected', 'Disconnected'),
                  _filterChip('lock', 'Lock'),
                  _filterChip('keyCombo', 'Key Combo'),
                  _filterChip('mediaKey', 'Media'),
                  _filterChip('launch', 'Launch'),
                ],
              ),
            ),
          ),
          // Log entries
          Expanded(
            child: ValueListenableBuilder<List<LogEntry>>(
              valueListenable: widget.conn!.logEntriesNotifier,
              builder: (context, entries, _) {
                var filtered = entries;
                if (_searchQuery.isNotEmpty) {
                  filtered = filtered.where((e) =>
                    e.action.toLowerCase().contains(_searchQuery) ||
                    e.device.toLowerCase().contains(_searchQuery) ||
                    e.time.toLowerCase().contains(_searchQuery)
                  ).toList();
                }
                if (_filterAction != null) {
                  filtered = filtered.where((e) =>
                    e.action.toLowerCase().contains(_filterAction!)
                  ).toList();
                }

                if (filtered.isEmpty) {
                  return const Center(child: Text('No log entries'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = filtered[i];
                    return ListTile(
                      dense: true,
                      leading: _actionIcon(e.action),
                      title: Text(e.action),
                      subtitle: Text(e.device, style: const TextStyle(fontSize: 12)),
                      trailing: Text(
                        _formatTime(e.time),
                        style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String? action, String label) {
    final selected = _filterAction == action;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(() => _filterAction = selected ? null : action),
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso.length > 19 ? iso.substring(11, 19) : iso;
    }
  }

  Widget _actionIcon(String action) {
    final a = action.toLowerCase();
    if (a.contains('connect')) return const Icon(Icons.link, size: 20);
    if (a.contains('disconnect')) return const Icon(Icons.link_off, size: 20);
    if (a.contains('lock')) return const Icon(Icons.lock, size: 20);
    if (a.contains('launch')) return const Icon(Icons.launch, size: 20);
    if (a.contains('key')) return const Icon(Icons.keyboard, size: 20);
    if (a.contains('media')) return const Icon(Icons.music_note, size: 20);
    if (a.contains('clipboard')) return const Icon(Icons.content_paste, size: 20);
    if (a.contains('file')) return const Icon(Icons.attach_file, size: 20);
    if (a.contains('shutdown')) return const Icon(Icons.power_settings_new, size: 20);
    return const Icon(Icons.circle, size: 20);
  }
}
