import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../services/android_host.dart';
import '../services/local_api_server.dart';
import '../services/support_store.dart';
import 'api_profiles_screen.dart';
import 'api_screen.dart';
import 'org_items_screen.dart';
import 'theme.dart';
import 'widgets.dart';

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
        listenable: Listenable.merge([s.clients, s.apiServer, s.host, s.printers, s.theme, s.support]),
        builder: (context, _) {
          final theme = Theme.of(context);
          final profiles = s.clients.clients.length;
          final printer = s.printers.defaultPrinter;
          final drawerPrinter = printer != null && !printer.isLabel && !printer.isDocument ? printer : null;
          return PageListView(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Image.asset('assets/logo.png', height: 52, filterQuality: FilterQuality.medium),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Universal Print', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(
                          'Version ${LocalApiServer.version}',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ]),
                    ),
                    StatusPill(
                      label: s.apiServer.isRunning ? 'Online' : 'Offline',
                      color: s.apiServer.isRunning ? successColor : theme.colorScheme.error,
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 20),
              SettingsGroup(
                title: 'Appearance',
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
                        ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
                        ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
                      ],
                      selected: {s.theme.mode},
                      onSelectionChanged: (v) => s.theme.setMode(v.first),
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                title: 'Tools',
                children: [
                  ListTile(
                    leading: const IconBadge(Icons.point_of_sale_rounded, size: 38, color: successColor),
                    title: const Text('Open cash drawer'),
                    subtitle: Text(drawerPrinter != null
                        ? 'Kick the drawer on ${drawerPrinter.name}'
                        : 'Set a receipt printer with a drawer as default'),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: drawerPrinter != null,
                    onTap: drawerPrinter == null ? null : () => runOpenCashDrawer(context, drawerPrinter),
                  ),
                ],
              ),
              SettingsGroup(
                title: 'Sharing',
                children: [
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
                ],
              ),
              if (AndroidHost.isSupported)
                SettingsGroup(
                  title: 'Background',
                  children: [
                    SwitchListTile(
                      secondary: const IconBadge(Icons.play_circle_outline, size: 38),
                      title: const Text('Run in background'),
                      subtitle: const Text('Keep the print API and queue running when the app is closed, and after a restart'),
                      value: s.host.backgroundEnabled,
                      onChanged: s.host.setBackground,
                    ),
                    if (s.host.backgroundEnabled)
                      ListTile(
                        leading: IconBadge(
                          s.host.batteryUnrestricted ? Icons.battery_charging_full : Icons.battery_alert,
                          size: 38,
                          color: s.host.batteryUnrestricted ? successColor : theme.colorScheme.error,
                        ),
                        title: const Text('Battery optimization'),
                        subtitle: Text(s.host.batteryUnrestricted
                            ? 'Unrestricted: the API answers with the screen off'
                            : 'Restricted: Android may stop the API when the screen is off. Tap to allow.'),
                        onTap: s.host.batteryUnrestricted ? null : s.host.requestBatteryUnrestricted,
                      ),
                  ],
                ),
              _contactGroup(context, s.support),
            ],
          );
        },
      ),
    );
  }

  Widget _contactGroup(BuildContext context, SupportStore support) {
    final info = support.info;
    final theme = Theme.of(context);
    Uri web(String v) => Uri.parse(v.contains('://') ? v : 'https://$v');
    Uri tel(String v) => Uri(scheme: 'tel', path: v.replaceAll(RegExp(r'[^\d+]'), ''));
    const socialIcons = {
      'facebook': Icons.facebook,
      'youtube': Icons.smart_display_outlined,
      'instagram': Icons.camera_alt_outlined,
      'linkedin': Icons.work_outline,
      'twitter': Icons.alternate_email,
    };

    return SettingsGroup(
      title: info?.name ?? 'Contact & support',
      trailing: support.loading
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : IconButton(
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: support.refresh,
            ),
      children: [
        if ((info == null || info.isEmpty) && support.products.isEmpty && support.services.isEmpty)
          ListTile(
            leading: const IconBadge(Icons.support_agent_rounded, size: 38),
            title: const Text('Contact details not available'),
            subtitle: Text(support.loading
                ? 'Loading…'
                : support.error ?? 'Check back later'),
          )
        else ...[
          if (info?.about != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(info!.about!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          if (info?.helpline != null)
            ListTile(
              leading: const IconBadge(Icons.support_agent_rounded, size: 38, color: successColor),
              title: const Text('Helpline'),
              subtitle: Text([info!.helpline!, ?info.openingTime].join(' · ')),
              trailing: const Icon(Icons.call_outlined, size: 18),
              onTap: () => openLink(context, tel(info.helpline!)),
            ),
          if (support.products.isNotEmpty)
            _MenuItem(
              icon: Icons.inventory_2_outlined,
              title: 'Products',
              subtitle: '${support.products.length} product(s) we sell',
              builder: (_) => OrgItemsScreen(title: 'Products', items: support.products, icon: Icons.inventory_2_outlined),
            ),
          if (support.services.isNotEmpty)
            _MenuItem(
              icon: Icons.handyman_outlined,
              title: 'Services',
              subtitle: '${support.services.length} service(s) we offer',
              builder: (_) => OrgItemsScreen(title: 'Services', items: support.services, icon: Icons.handyman_outlined),
            ),
          if (info != null) ...[
            if (info.whatsappUrl != null)
              ListTile(
                leading: const IconBadge(Icons.chat_rounded, size: 38, color: Color(0xFF25D366)),
                title: const Text('WhatsApp'),
                subtitle: Text(info.whatsapp == null ? 'Chat with us' : '+${info.whatsapp}'),
                trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                onTap: () => openLink(context, Uri.parse(info.whatsappUrl!)),
              ),
            if (info.phone != null)
              ListTile(
                leading: const IconBadge(Icons.call_outlined, size: 38, color: successColor),
                title: const Text('Call'),
                subtitle: Text(info.phone!),
                onTap: () => openLink(context, tel(info.phone!)),
              ),
            if (info.email != null)
              ListTile(
                leading: const IconBadge(Icons.mail_outline_rounded, size: 38),
                title: const Text('Email'),
                subtitle: Text(info.email!),
                onTap: () => openLink(context, Uri(scheme: 'mailto', path: info.email)),
              ),
            if (info.website != null)
              ListTile(
                leading: const IconBadge(Icons.language_rounded, size: 38),
                title: const Text('Website'),
                subtitle: Text(info.website!),
                trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                onTap: () => openLink(context, web(info.website!)),
              ),
            if (info.address != null)
              ListTile(
                leading: const IconBadge(Icons.location_on_outlined, size: 38, color: warningColor),
                title: const Text('Address'),
                subtitle: Text(info.address!),
                trailing: const Icon(Icons.copy_rounded, size: 18),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: info.address!));
                  showMessage(context, 'Address copied');
                },
              ),
            if (info.socials.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Wrap(spacing: 4, children: [
                  for (final MapEntry(key: name, value: url) in info.socials.entries)
                    IconButton(
                      tooltip: name[0].toUpperCase() + name.substring(1),
                      color: theme.colorScheme.primary,
                      icon: Icon(socialIcons[name] ?? Icons.link_rounded),
                      onPressed: () => openLink(context, web(url)),
                    ),
                ]),
              ),
          ],
        ],
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.icon, required this.title, required this.subtitle, required this.builder});

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: IconBadge(icon, size: 38),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: builder)),
  );
}
