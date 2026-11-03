import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/android_host.dart';
import '../services/local_api_server.dart';
import 'api_profiles_screen.dart';
import 'api_screen.dart';

/// Entry point for settings and tools. Add new features as [_MenuItem]s.
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The battery setting is changed in a system dialog.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) AppScope.of(context).host.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Menu')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.clients, s.apiServer, s.host]),
        builder: (context, _) {
          final profiles = s.clients.clients.length;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const _Section('Sharing'),
              _MenuItem(
                icon: Icons.vpn_key_outlined,
                title: 'API profiles',
                subtitle: profiles == 0
                    ? 'Give another user or software a token to print here'
                    : '$profiles profile(s) can print with a token',
                builder: (_) => const ApiProfilesScreen(),
              ),
              _MenuItem(
                icon: Icons.hub_outlined,
                title: 'Connect software',
                subtitle: 'API on/off, port, master token, routes',
                builder: (_) => const ApiScreen(),
              ),
              if (AndroidHost.isSupported) ...[
                const Divider(),
                const _Section('Background'),
                SwitchListTile(
                  secondary: const Icon(Icons.play_circle_outline),
                  title: const Text('Run in background'),
                  subtitle: const Text('Keep the print API and queue running when the app is closed, and after a restart'),
                  value: s.host.backgroundEnabled,
                  onChanged: s.host.setBackground,
                ),
                if (s.host.backgroundEnabled)
                  ListTile(
                    leading: Icon(
                      s.host.batteryUnrestricted ? Icons.battery_charging_full : Icons.battery_alert,
                      color: s.host.batteryUnrestricted ? null : Theme.of(context).colorScheme.error,
                    ),
                    title: const Text('Battery optimization'),
                    subtitle: Text(s.host.batteryUnrestricted
                        ? 'Unrestricted: the API answers with the screen off'
                        : 'Restricted: Android may stop the API when the screen is off. Tap to allow.'),
                    onTap: s.host.batteryUnrestricted ? null : s.host.requestBatteryUnrestricted,
                  ),
              ],
              const Divider(),
              const _Section('About'),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Universal Print'),
                subtitle: Text('Version ${LocalApiServer.version}'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
  );
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.icon, required this.title, required this.subtitle, required this.builder});

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: builder)),
  );
}
