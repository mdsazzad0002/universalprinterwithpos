import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/client.dart';
import '../services/client_store.dart';
import 'widgets.dart';

/// Route → printer assignment for one paired software.
class ClientRoutesScreen extends StatelessWidget {
  const ClientRoutesScreen({super.key, required this.clientId});

  final String clientId;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.clients, s.printers]),
      builder: (context, _) {
        final client = s.clients.byId(clientId);
        final isManual = clientId == ApiClient.manualId;
        final routes = s.clients.routesFor(clientId);
        return Scaffold(
          appBar: AppBar(
            title: Text(client?.name ?? (isManual ? 'Manual (master token)' : clientId)),
            actions: [
              if (client != null)
                IconButton(
                  tooltip: 'Disconnect software',
                  icon: const Icon(Icons.link_off),
                  onPressed: () => _revoke(context, client),
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _addRoute(context),
            icon: const Icon(Icons.add),
            label: const Text('Add route'),
          ),
          body: routes.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No routes yet.\nThe software creates them with PUT /api/routes, '
                      'or the first time it prints with a "route".',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                  children: [
                    if (client != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'ID: ${client.id} · last seen ${client.lastSeenAt == null ? 'never' : formatTime(client.lastSeenAt!)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    for (final r in routes) _RouteCard(route: r),
                  ],
                ),
        );
      },
    );
  }

  Future<void> _revoke(BuildContext context, ApiClient client) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disconnect ${client.name}?'),
        content: const Text('Its token stops working and its routes are removed. It must pair again to print.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await AppScope.of(context).clients.revoke(client.id);
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _addRoute(BuildContext context) async {
    final key = TextEditingController();
    final name = TextEditingController();
    final input = await showDialog<RouteInput>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add route'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: key, decoration: const InputDecoration(labelText: 'Key (used by software)', hintText: 'kitchen')),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'Kitchen order')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              try {
                Navigator.pop(ctx, RouteInput.fromJson({'key': key.text.trim(), 'name': name.text.trim().isEmpty ? null : name.text.trim()}, 0));
              } on FormatException catch (e) {
                showMessage(ctx, e.message.replaceFirst('routes[0].', ''), error: true);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    key.dispose();
    name.dispose();
    if (input != null && context.mounted) await AppScope.of(context).clients.sync(clientId, [input]);
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.route});

  final PrintRoute route;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final printers = s.printers.printers;
    final printer = route.printerId == null ? null : s.printers.byId(route.printerId!);
    final widths = {58, 80, ?printer?.paperWidth, ?route.paperWidth}.toList()..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(route.name, style: Theme.of(context).textTheme.titleMedium),
                Text('route: "${route.key}"', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ]),
            ),
            if (printer == null)
              Chip(
                label: const Text('Not assigned'),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                side: BorderSide.none,
              ),
            IconButton(
              tooltip: 'Remove route',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => s.clients.deleteRoute(route),
            ),
          ]),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            key: ValueKey('printer-${route.key}-${route.printerId}'),
            initialValue: printer?.id,
            decoration: const InputDecoration(labelText: 'Printer', border: OutlineInputBorder(), isDense: true),
            items: [
              const DropdownMenuItem(value: null, child: Text('— Default printer —')),
              for (final p in printers) DropdownMenuItem(value: p.id, child: Text('${p.name} (${p.paperWidth} mm)')),
            ],
            onChanged: (id) => s.clients.updateRoute(route.copyWith(printerId: id, clearPrinter: id == null)),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int?>(
                key: ValueKey('width-${route.key}-${route.paperWidth}'),
                initialValue: route.paperWidth,
                decoration: const InputDecoration(labelText: 'Paper width', border: OutlineInputBorder(), isDense: true),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Printer default')),
                  for (final w in widths)
                    if (printer == null || w <= printer.paperWidth) DropdownMenuItem(value: w, child: Text('$w mm')),
                ],
                onChanged: (w) => s.clients.updateRoute(route.copyWith(paperWidth: w, clearPaperWidth: w == null)),
              ),
            ),
            const SizedBox(width: 12),
            Text('Copies', style: Theme.of(context).textTheme.labelLarge),
            IconButton(
              icon: const Icon(Icons.remove),
              onPressed: route.copies > 1 ? () => s.clients.updateRoute(route.copyWith(copies: route.copies - 1)) : null,
            ),
            Text('${route.copies}'),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: route.copies < 20 ? () => s.clients.updateRoute(route.copyWith(copies: route.copies + 1)) : null,
            ),
          ]),
        ]),
      ),
    );
  }
}
