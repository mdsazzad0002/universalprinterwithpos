import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../data/models/client.dart';
import 'client_routes_screen.dart';
import 'widgets.dart';

class ApiScreen extends StatelessWidget {
  const ApiScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final api = s.apiServer;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect software')),
      body: ListenableBuilder(
        listenable: Listenable.merge([api, s.clients]),
        builder: (context, _) {
          final host = api.allowLan ? '<this-device-ip>' : '127.0.0.1';
          final base = 'http://$host:${api.port}';
          final auth = api.requireToken ? '  -H "Authorization: Bearer ${api.token}" \\\n' : '';
          final example = '''curl -X POST $base/api/print \\
$auth  -H "Content-Type: application/json" \\
  -d '{"route":"invoice","reference":"INV-1001",
       "content":{"store_name":"My Shop","invoice_no":"INV-1001",
       "items":[{"name":"Product A","qty":2,"price":100}],
       "total":200}}\'''';
          final clientIds = s.clients.clientIdsWithRoutes;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Connected software', style: Theme.of(context).textTheme.titleMedium),
              if (clientIds.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('None yet. Software connects itself with POST /api/pair; you approve it here once.'),
                ),
              for (final id in clientIds) _clientTile(context, id),
              const Divider(height: 32),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable print API'),
                subtitle: Text(api.lastError ?? (api.isRunning ? 'Running on $base' : 'Stopped')),
                value: api.enabled,
                onChanged: (v) => api.configure(enabled: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Require API token on this device'),
                subtitle: const Text(
                  'Off: software on this device prints without any key. '
                  'Other devices on Wi-Fi always need a token.',
                ),
                value: api.requireToken,
                onChanged: (v) => api.configure(requireToken: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow other devices on Wi-Fi'),
                subtitle: const Text('Off: only apps and browsers on this phone can print'),
                value: api.allowLan,
                onChanged: (v) => api.configure(allowLan: v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Port'),
                subtitle: Text('${api.port}'),
                trailing: const Icon(Icons.edit),
                onTap: () => _editPort(context),
              ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Master token (manual setup)'),
                subtitle: SelectableText(api.token, style: const TextStyle(fontFamily: 'monospace')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: api.token));
                      showMessage(context, 'Token copied');
                    },
                  ),
                  IconButton(
                    tooltip: 'Generate new token',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => _regenerate(context),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              Text('Example', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(example, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
              const SizedBox(height: 8),
              const Text('Full API reference: docs/API.md'),
            ],
          );
        },
      ),
    );
  }

  Widget _clientTile(BuildContext context, String clientId) {
    final clients = AppScope.of(context).clients;
    final client = clients.byId(clientId);
    final routes = clients.routesFor(clientId);
    final unassigned = routes.where((r) => r.printerId == null).length;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(clientId == ApiClient.manualId ? Icons.key : Icons.point_of_sale),
      title: Text(client?.name ?? (clientId == ApiClient.manualId ? 'Manual (master token)' : clientId)),
      subtitle: Text(
        '${routes.length} route(s)${unassigned > 0 ? ' · $unassigned not assigned' : ''}',
        style: unassigned > 0 ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ClientRoutesScreen(clientId: clientId)),
      ),
    );
  }

  Future<void> _editPort(BuildContext context) async {
    final api = AppScope.of(context).apiServer;
    final controller = TextEditingController(text: '${api.port}');
    final port = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API port'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(controller.text);
              Navigator.pop(ctx, v != null && v >= 1024 && v <= 65535 ? v : null);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (port != null) await api.configure(port: port);
  }

  Future<void> _regenerate(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generate new token?'),
        content: const Text('Every app using the current token will stop printing until updated.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Generate')),
        ],
      ),
    );
    if (ok == true && context.mounted) await AppScope.of(context).apiServer.regenerateToken();
  }
}
