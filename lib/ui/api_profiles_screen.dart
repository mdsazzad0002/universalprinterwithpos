import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../data/models/client.dart';
import 'client_routes_screen.dart';
import 'widgets.dart';

/// Access profiles for other users or software. Each profile has its own
/// token; apps on this device print without one.
class ApiProfilesScreen extends StatefulWidget {
  const ApiProfilesScreen({super.key});

  @override
  State<ApiProfilesScreen> createState() => _ApiProfilesScreenState();
}

class _ApiProfilesScreenState extends State<ApiProfilesScreen> {
  late final Future<List<String>> _addresses = _lanAddresses();

  static Future<List<String>> _lanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('API profiles')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context),
        icon: const Icon(Icons.add),
        label: const Text('New profile'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.clients, s.apiServer]),
        builder: (context, _) {
          final api = s.apiServer;
          final profiles = s.clients.clients;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.phone_android, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          api.requireToken
                              ? 'Apps on this device also need a token (turned on in Connect software).'
                              : 'Apps on this device print without a token: http://127.0.0.1:${api.port}',
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.devices_other, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(api.allowLan
                            ? 'Other devices connect with a profile token.'
                            : 'Other devices cannot connect yet: Wi-Fi access is off.'),
                      ),
                      if (!api.allowLan)
                        TextButton(onPressed: () => api.configure(allowLan: true), child: const Text('Turn on')),
                    ]),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              if (profiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No profiles yet.\nCreate one for each user or software that should print here, '
                    'then share its token.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final p in profiles) _profileCard(context, p),
            ],
          );
        },
      ),
    );
  }

  Widget _profileCard(BuildContext context, ApiClient p) {
    final routes = AppScope.of(context).clients.routesFor(p.id).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${p.id} · $routes route(s) · last used ${p.lastSeenAt == null ? 'never' : formatTime(p.lastSeenAt!)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'routes' => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => ClientRoutesScreen(clientId: p.id)),
                ),
                'regenerate' => _regenerate(context, p),
                'delete' => _delete(context, p),
                _ => null,
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'routes', child: Text('Routes & printers')),
                PopupMenuItem(value: 'regenerate', child: Text('New token')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: SelectableText(p.token, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ),
            IconButton(
              tooltip: 'Copy token',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: p.token));
                showMessage(context, 'Token copied');
              },
            ),
            IconButton(
              tooltip: 'Copy connection details',
              icon: const Icon(Icons.share_outlined),
              onPressed: () => _copyDetails(context, p),
            ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _copyDetails(BuildContext context, ApiClient p) async {
    final port = AppScope.of(context).apiServer.port;
    final hosts = await _addresses;
    final urls = hosts.isEmpty ? ['http://<this-device-ip>:$port'] : [for (final h in hosts) 'http://$h:$port'];
    final text = [
      'Universal Print — ${p.name}',
      'URL: ${urls.join('  or  ')}',
      'Header: Authorization: Bearer ${p.token}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showMessage(context, 'Connection details copied');
  }

  Future<void> _create(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New API profile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'Branch 2 POS'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final profile = await AppScope.of(context).clients.createProfile(name);
    if (context.mounted) showMessage(context, 'Profile "${profile.name}" created');
  }

  Future<void> _regenerate(BuildContext context, ApiClient p) async {
    final ok = await _confirm(context, 'New token for ${p.name}?', 'The current token stops working immediately.', 'Generate');
    if (ok && context.mounted) await AppScope.of(context).clients.register(p.id, p.name);
  }

  Future<void> _delete(BuildContext context, ApiClient p) async {
    final ok = await _confirm(context, 'Delete ${p.name}?', 'Its token stops working and its routes are removed.', 'Delete');
    if (ok && context.mounted) await AppScope.of(context).clients.revoke(p.id);
  }

  Future<bool> _confirm(BuildContext context, String title, String content, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ==
      true;
}
