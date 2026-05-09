import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/connection.dart';

/// Full-screen searchable grid of installed PC apps.
/// Replaces the old basic "launch application" feature.
class AppLauncherScreen extends StatefulWidget {
  final PcConnection conn;
  const AppLauncherScreen({super.key, required this.conn});
  @override
  State<AppLauncherScreen> createState() => _AppLauncherScreenState();
}

class _AppLauncherScreenState extends State<AppLauncherScreen> {
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Refresh the app list every time this screen opens
    widget.conn.requestAppList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('App Launcher'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => widget.conn.requestAppList(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search apps...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withOpacity(0.5),
              ),
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
            ),
          ),
          // Grid
          Expanded(
            child: ValueListenableBuilder<List<AppEntry>>(
              valueListenable: widget.conn.appListNotifier,
              builder: (context, apps, _) {
                if (apps.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Loading apps from PC...'),
                      ],
                    ),
                  );
                }

                var filtered = apps;
                if (_query.isNotEmpty) {
                  filtered = apps.where((a) => a.name.toLowerCase().contains(_query)).toList();
                }

                if (filtered.isEmpty) {
                  return Center(child: Text('No apps matching "$_query"'));
                }

                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 110,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final app = filtered[i];
                    return _AppTile(
                      app: app,
                      onTap: () {
                        widget.conn.launchAppByPath(app.exePath);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Launching ${app.name}...'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
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
}

class _AppTile extends StatelessWidget {
  final AppEntry app;
  final VoidCallback onTap;
  const _AppTile({required this.app, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withOpacity(0.4),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: app.iconBase64 != null && app.iconBase64!.isNotEmpty
                    ? Image.memory(
                        base64Decode(app.iconBase64!),
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => Icon(Icons.apps, size: 36, color: cs.primary),
                      )
                    : Icon(Icons.apps, size: 36, color: cs.primary),
              ),
              const SizedBox(height: 6),
              Text(
                app.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, height: 1.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
