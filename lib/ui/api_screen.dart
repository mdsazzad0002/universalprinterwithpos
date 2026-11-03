import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../data/models/client.dart';
import 'client_routes_screen.dart';
import 'theme.dart';
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
          final scheme = Theme.of(context).colorScheme;
          return PageListView(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    IconBadge(
                      api.isRunning ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                      size: 48,
                      color: api.isRunning ? successColor : scheme.error,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          api.isRunning ? 'Print API running' : 'Print API stopped',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          api.lastError ?? base,
                          style: TextStyle(
                            fontFamily: api.lastError == null ? 'monospace' : null,
                            fontSize: 13,
                            color: api.lastError == null ? scheme.onSurfaceVariant : scheme.error,
                          ),
                        ),
                      ]),
                    ),
                    Switch(value: api.enabled, onChanged: (v) => api.configure(enabled: v)),
                  ]),
                ),
              ),
              const SizedBox(height: 20),
              SettingsGroup(
                title: 'Connected software',
                children: [
                  if (clientIds.isEmpty)
                    const ListTile(
                      leading: IconBadge(Icons.link_off_rounded, size: 38),
                      title: Text('None yet'),
                      subtitle: Text('Software connects itself with POST /api/pair; you approve it here once.'),
                    ),
                  for (final id in clientIds) _clientTile(context, id),
                ],
              ),
              SettingsGroup(
                title: 'Access',
                children: [
                  SwitchListTile(
                    secondary: const IconBadge(Icons.lock_outline_rounded, size: 38),
                    title: const Text('Require API token on this device'),
                    subtitle: const Text(
                      'Off: software on this device prints without any key. '
                      'Other devices on Wi-Fi always need a token.',
                    ),
                    value: api.requireToken,
                    onChanged: (v) => api.configure(requireToken: v),
                  ),
                  SwitchListTile(
                    secondary: const IconBadge(Icons.wifi_rounded, size: 38),
                    title: const Text('Allow other devices on Wi-Fi'),
                    subtitle: const Text('Off: only apps and browsers on this phone can print'),
                    value: api.allowLan,
                    onChanged: (v) => api.configure(allowLan: v),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.settings_ethernet_rounded, size: 38),
                    title: const Text('Port'),
                    subtitle: Text('${api.port}'),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => _editPort(context),
                  ),
                ],
              ),
              SettingsGroup(
                title: 'Master token (manual setup)',
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                    child: Row(children: [
                      const IconBadge(Icons.key_rounded, size: 38),
                      const SizedBox(width: 16),
                      Expanded(
                        child: SelectableText(api.token, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                      ),
                      IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: api.token));
                          showMessage(context, 'Token copied');
                        },
                      ),
                      IconButton(
                        tooltip: 'Generate new token',
                        icon: const Icon(Icons.refresh_rounded),
                        onPressed: () => _regenerate(context),
                      ),
                    ]),
                  ),
                ],
              ),
              SectionHeader(
                'Example',
                trailing: IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: example));
                    showMessage(context, 'Example copied');
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SelectableText(
                  example,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFE2E8F0), height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Full API reference: docs/API.md',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
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
      leading: IconBadge(clientId == ApiClient.manualId ? Icons.key_rounded : Icons.point_of_sale_rounded, size: 38),
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
