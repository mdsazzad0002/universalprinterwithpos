import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../data/models/printer.dart';
import '../services/android_host.dart';
import '../services/os_driver_setup.dart';
import '../services/os_printer_setup.dart';
import '../services/os_printer_sync.dart';
import '../services/system_printer.dart';
import 'theme.dart';
import 'widgets.dart';

/// Use Universal Print as a normal printer of the operating system — the
/// Android print dialog, Windows / Linux / macOS "Add printer" — with the
/// OS's built-in driverless drivers. Regular setup (API, Intents) is
/// unaffected.
class SystemPrinterScreen extends StatefulWidget {
  const SystemPrinterScreen({super.key});

  @override
  State<SystemPrinterScreen> createState() => _SystemPrinterScreenState();
}

class _SystemPrinterScreenState extends State<SystemPrinterScreen> {
  late ClientOs _os = ClientOs.current;
  late final Future<List<String>> _addresses = _lanAddresses();
  bool _busy = false;
  Future<List<InstalledPrinter>>? _installed = OsPrinterSetup.canManageInstalled ? OsPrinterSetup.listInstalled() : null;

  Future<List<InstalledDriver>>? _drivers = OsDriverSetup.isSupported ? OsDriverSetup.list() : null;
  bool _showSystemDrivers = false;

  void _reloadInstalled() {
    if (!OsPrinterSetup.canManageInstalled) return;
    setState(() {
      _installed = OsPrinterSetup.listInstalled();
      _drivers = OsDriverSetup.list();
    });
  }

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
      appBar: AppBar(title: const Text('System printer')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.systemPrinter, s.printers, s.osPrinters]),
        builder: (context, _) => FutureBuilder<List<String>>(
          future: _addresses,
          builder: (context, snap) => _body(context, s.systemPrinter, snap.data ?? const []),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, SystemPrinter sys, List<String> ips) {
    final theme = Theme.of(context);
    final printers = sys.sharedPrinters;
    final running = sys.isRunning;
    return PageListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const IconBadge(Icons.print_rounded, size: 44),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Use as a normal printer', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Print from any program — browser, Word, PDF viewer, POS — on Android, Windows, Linux '
                        'and macOS. Uses the driver already built into the system (IPP Everywhere / AirPrint), '
                        'so no printer driver needs to be installed. Your regular setup keeps working.',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (printers.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 20),
            child: EmptyState(
              icon: Icons.print_disabled_outlined,
              title: 'No receipt or label printer yet',
              message:
                  'Add a printer in the Printers tab first. A4 / IPP printers are already driverless and '
                  'can be added to your computer directly.',
            ),
          ),
        SettingsGroup(
          title: 'Driverless printer (IPP)',
          trailing: StatusPill(
            label: running ? 'On · port ${sys.boundPort}' : 'Off',
            color: running ? successColor : theme.colorScheme.outline,
          ),
          children: [
            SwitchListTile(
              secondary: const IconBadge(Icons.power_settings_new_rounded, size: 38),
              title: const Text('Share as system printer'),
              subtitle: Text(sys.lastError ?? 'Windows, Linux, macOS and phones print here without a driver'),
              value: sys.enabled,
              onChanged: (v) => sys.configure(enabled: v),
            ),
            SwitchListTile(
              secondary: const IconBadge(Icons.wifi_rounded, size: 38),
              title: const Text('Other devices on Wi-Fi / LAN'),
              subtitle: Text(
                sys.lanAccess
                    ? (sys.discoveryError ??
                          (sys.discoveryActive
                              ? 'Announced on the network: computers find it automatically'
                              : 'Reachable from other devices'))
                    : 'Only this device can print to it',
              ),
              value: sys.lanAccess,
              onChanged: (v) => sys.configure(lanAccess: v),
            ),
            SwitchListTile(
              secondary: const IconBadge(Icons.cable_rounded, size: 38),
              title: const Text('RAW port ${SystemPrinter.rawPort}'),
              subtitle: Text(
                sys.rawError ??
                    'For POS software using the "Generic / Text Only" driver or sending ESC/POS. Prints on the default printer.',
              ),
              value: sys.rawEnabled,
              onChanged: (v) => sys.configure(rawEnabled: v),
            ),
            SwitchListTile(
              secondary: const IconBadge(Icons.point_of_sale_rounded, size: 38, color: successColor),
              title: const Text('Open cash drawer with every print'),
              subtitle: const Text(
                'Programs printing through the system driver cannot say "paid in cash". '
                'Off: each printer\'s own drawer setting applies.',
              ),
              value: sys.openDrawer,
              onChanged: (v) => sys.configure(openDrawer: v),
            ),
          ],
        ),
        if (printers.isNotEmpty)
          SettingsGroup(title: 'Printer addresses', children: [for (final p in printers) _addressTile(context, sys, p, ips)]),
        if (OsPrinterSync.isSupported) _autoAddGroup(context, sys),
        if (_installed != null) _installedGroup(context),
        if (_drivers != null) _driversGroup(context),
        SectionHeader('Set up on'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SegmentedButton<ClientOs>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ClientOs.android, icon: Icon(Icons.android), label: Text('Android')),
              ButtonSegment(value: ClientOs.windows, icon: Icon(Icons.window), label: Text('Windows')),
              ButtonSegment(value: ClientOs.linux, icon: Icon(Icons.terminal), label: Text('Linux')),
              ButtonSegment(value: ClientOs.macos, icon: Icon(Icons.laptop_mac), label: Text('macOS')),
            ],
            selected: {_os},
            onSelectionChanged: (v) => setState(() => _os = v.first),
          ),
        ),
        Card(
          child: Padding(padding: const EdgeInsets.all(16), child: _instructions(context, sys, printers, ips)),
        ),
      ],
    );
  }

  Widget _addressTile(BuildContext context, SystemPrinter sys, Printer p, List<String> ips) {
    final isDefault = p.id == sys.defaultShared?.id;
    final local = sys.localUri(p);
    final lan = sys.lanAccess && ips.isNotEmpty ? sys.uriFor(ips.first, p) : null;
    return ListTile(
      leading: IconBadge(p.isLabel ? Icons.label_outline : Icons.receipt_long_outlined, size: 38),
      title: Text('${p.name}${isDefault ? '  · default' : ''}'),
      subtitle: Text([lan ?? local, p.paperLabel].join('\n')),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: 'Copy address',
        icon: const Icon(Icons.copy_rounded, size: 20),
        onPressed: () => _copy(context, lan ?? local),
      ),
    );
  }

  Widget _autoAddGroup(BuildContext context, SystemPrinter sys) {
    final sync = AppScope.of(context).osPrinters;
    final os = ClientOs.current.label;
    return SettingsGroup(
      title: 'Automatic',
      children: [
        SwitchListTile(
          secondary: IconBadge(Icons.sync_rounded, size: 38, color: sync.lastFailed ? Theme.of(context).colorScheme.error : null),
          title: Text('Add new printers to $os'),
          subtitle: Text(
            !sys.isRunning
                ? 'Needs "Share as system printer" on'
                : sync.isSyncing
                ? 'Updating $os printers…'
                : sync.lastMessage ??
                      'Every receipt / label printer added in the app appears in $os\'s printer list; '
                          'deleting or renaming it updates the list',
          ),
          value: sync.enabled,
          onChanged: (v) async {
            await sync.configure(enabled: v);
            _reloadInstalled();
          },
        ),
      ],
    );
  }

  /// Printers the operating system already has, with a remove button.
  Widget _installedGroup(BuildContext context) => FutureBuilder<List<InstalledPrinter>>(
    future: _installed,
    builder: (context, snap) {
      final theme = Theme.of(context);
      final List<Widget> rows;
      if (snap.connectionState != ConnectionState.done) {
        rows = [
          const ListTile(
            leading: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            title: Text('Reading printers…'),
          ),
        ];
      } else if (snap.hasError) {
        rows = [
          ListTile(
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: Text('${snap.error}'),
          ),
        ];
      } else if (snap.data!.isEmpty) {
        rows = [
          ListTile(
            leading: const IconBadge(Icons.print_disabled_outlined, size: 38),
            title: Text('No printers installed in ${ClientOs.current.label}'),
          ),
        ];
      } else {
        rows = [for (final p in snap.data!) _installedTile(context, p)];
      }
      return SettingsGroup(
        title: 'Printers on this ${ClientOs.current.label}',
        trailing: IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          onPressed: _busy ? null : _reloadInstalled,
        ),
        children: rows,
      );
    },
  );

  Widget _installedTile(BuildContext context, InstalledPrinter p) {
    final theme = Theme.of(context);
    final tags = [if (p.isDefault) 'Default', if (p.isUniversalPrint) 'Universal Print', ?p.status];
    final details = [
      if (tags.isNotEmpty) tags.join(' · '),
      if (p.device != null && p.device!.isNotEmpty) p.device!,
      if (p.driver != null && p.driver!.isNotEmpty) p.driver!,
    ];
    return ListTile(
      leading: IconBadge(
        p.isUniversalPrint ? Icons.print_rounded : Icons.print_outlined,
        size: 38,
        color: p.enabled ? null : theme.colorScheme.outline,
      ),
      title: Text(p.name),
      subtitle: details.isEmpty ? null : Text(details.join('\n')),
      isThreeLine: details.length > 1,
      trailing: IconButton(
        tooltip: 'Remove from ${ClientOs.current.label}',
        icon: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
        onPressed: _busy ? null : () => _remove(context, p),
      ),
    );
  }

  Future<void> _remove(BuildContext context, InstalledPrinter p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${p.name}"?'),
        content: Text(
          'The printer is removed from ${ClientOs.current.label} for every program and user. '
          'Pending jobs in its queue are cancelled. You can add it again later.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await OsPrinterSetup.removeInstalled(p);
    if (!mounted) return;
    setState(() => _busy = false);
    _reloadInstalled();
    if (context.mounted) showMessage(context, r.message, error: !r.ok);
  }

  /// Printer drivers of the OS, with a remove button.
  Widget _driversGroup(BuildContext context) => FutureBuilder<List<InstalledDriver>>(
    future: _drivers,
    builder: (context, snap) {
      final theme = Theme.of(context);
      final List<Widget> rows;
      if (snap.connectionState != ConnectionState.done) {
        rows = [
          const ListTile(
            leading: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            title: Text('Reading drivers…'),
          ),
        ];
      } else if (snap.hasError) {
        rows = [
          ListTile(
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: Text('${snap.error}'),
          ),
        ];
      } else {
        final all = snap.data!;
        final system = all.where((d) => d.isSystem).length;
        final shown = [
          for (final d in all)
            if (_showSystemDrivers || !d.isSystem) d,
        ];
        rows = [
          if (shown.isEmpty)
            const ListTile(
              leading: IconBadge(Icons.check_circle_outline, size: 38),
              title: Text('No extra printer drivers installed'),
            ),
          for (final d in shown) _driverTile(context, d),
          if (system > 0)
            SwitchListTile(
              title: Text('Show printing system components ($system)'),
              subtitle: const Text('Needed by every printer; they cannot be removed here'),
              value: _showSystemDrivers,
              onChanged: (v) => setState(() => _showSystemDrivers = v),
            ),
        ];
      }
      return SettingsGroup(title: 'Printer drivers on this ${ClientOs.current.label}', children: rows);
    },
  );

  Widget _driverTile(BuildContext context, InstalledDriver d) {
    final theme = Theme.of(context);
    final details = [?d.detail, if (d.usedBy.isNotEmpty) 'Used by ${d.usedBy.join(', ')}'].where((s) => s.isNotEmpty).toList();
    return ListTile(
      leading: IconBadge(
        d.isSystem ? Icons.lock_outline : Icons.memory_rounded,
        size: 38,
        color: d.isSystem ? theme.colorScheme.outline : null,
      ),
      title: Text(d.name),
      subtitle: details.isEmpty ? null : Text(details.join('\n')),
      isThreeLine: details.length > 1,
      trailing: d.isSystem
          ? null
          : IconButton(
              tooltip: 'Remove driver',
              icon: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
              onPressed: _busy ? null : () => _removeDriver(context, d),
            ),
    );
  }

  Future<void> _removeDriver(BuildContext context, InstalledDriver d) async {
    setState(() => _busy = true);
    final also = await OsDriverSetup.alsoRemoved(d);
    if (!mounted || !context.mounted) return;
    setState(() => _busy = false);
    final what = d.isPackage ? 'package "${d.name}"' : '"${d.name}"';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove driver ${d.name}?'),
        content: Text(
          [
            'The $what is removed from ${ClientOs.current.label}. Printers using it stop working until a driver is installed again.',
            if (d.usedBy.isNotEmpty) 'Used by: ${d.usedBy.join(', ')}. Remove those printers first.',
            if (also.isNotEmpty) 'These packages are removed too, because they need it: ${also.join(', ')}.',
            if (d.files.isNotEmpty) 'Deleted: ${d.files.join(', ')}',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await OsDriverSetup.remove(d);
    if (!mounted) return;
    setState(() => _busy = false);
    _reloadInstalled();
    if (context.mounted) showMessage(context, r.message, error: !r.ok);
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    showMessage(context, 'Copied');
  }

  /// Is the app running on the OS the instructions are for?
  bool get _here => _os == ClientOs.current;

  /// Address another device uses, or this device's loopback.
  String _uri(SystemPrinter sys, Printer? p, List<String> ips, {String scheme = 'ipp'}) =>
      _here ? sys.localUri(p, scheme: scheme) : sys.uriFor(ips.isEmpty ? '<this-device-ip>' : ips.first, p, scheme: scheme);

  Widget _instructions(BuildContext context, SystemPrinter sys, List<Printer> printers, List<String> ips) {
    final theme = Theme.of(context);
    final needsServer = !(_os == ClientOs.android && _here);
    final warnings = <Widget>[
      if (needsServer && !sys.isRunning)
        _Note(
          icon: Icons.info_outline,
          text: 'Turn on "Share as system printer" above first.',
          action: TextButton(onPressed: () => sys.configure(enabled: true), child: const Text('Turn on')),
        ),
      if (needsServer && !_here && !sys.lanAccess)
        _Note(
          icon: Icons.wifi_off_rounded,
          text: 'Turn on "Other devices on Wi-Fi / LAN" so ${_os.label} can reach this device.',
          action: TextButton(onPressed: () => sys.configure(lanAccess: true), child: const Text('Turn on')),
        ),
    ];
    final steps = switch (_os) {
      ClientOs.android => _android(context, sys, printers, ips),
      ClientOs.windows => _windows(context, sys, printers, ips),
      ClientOs.linux => _linux(context, sys, printers, ips),
      ClientOs.macos => _mac(context, sys, printers, ips),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _here ? 'On this ${_os.label} device' : 'On a ${_os.label} device on the same network',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        ...warnings,
        ...steps,
      ],
    );
  }

  List<Widget> _android(BuildContext context, SystemPrinter sys, List<Printer> printers, List<String> ips) {
    if (_here) {
      return [
        const _Step(1, 'Open Android print settings and turn on "Universal Print".'),
        if (AndroidHost.isSupported)
          Padding(
            padding: const EdgeInsets.only(left: 34, bottom: 12),
            child: FilledButton.icon(
              onPressed: () => AppScope.of(context).host.openPrintSettings(),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Open print settings'),
            ),
          ),
        const _Step(2, 'In any app (Chrome, PDF, Gallery, Office…) tap Print / Share → Print.'),
        const _Step(
          3,
          'Choose your printer from the list. Every printer from the Printers tab appears there. '
          'Pick the roll / label size; pages are fitted to the paper width.',
        ),
        const _Step(4, 'Optional: in the print dialog, "All printers" → pin it to make it the default.'),
        const _Note(
          icon: Icons.lightbulb_outline,
          text:
              'Other phones and tablets on the same Wi-Fi can print here too: turn on "Share as system printer" '
              'and their built-in "Default Print Service" finds it automatically.',
        ),
      ];
    }
    return [
      const _Step(1, 'On the other phone: Settings → Connected devices → Printing → turn on "Default Print Service".'),
      const _Step(2, 'Make sure it is on the same Wi-Fi. Universal Print appears in its print dialog automatically.'),
      _Step(
        3,
        'If it does not appear: Default Print Service → ⋮ → Add printer → enter this device\'s IP '
        '${ips.isEmpty ? '' : '(${ips.first})'} and port ${sys.boundPort ?? sys.port}.',
      ),
    ];
  }

  List<Widget> _windows(BuildContext context, SystemPrinter sys, List<Printer> printers, List<String> ips) {
    return [
      if (_here && printers.isNotEmpty) ...[
        const _Step(1, 'Add the printer to Windows in one click (uses the built-in Microsoft IPP Class Driver):'),
        for (final p in printers) _setupButtons(context, p, sys),
        const SizedBox(height: 4),
        Text('Or add it by hand:', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
      ],
      const _Step(1, 'Settings → Bluetooth & devices → Printers & scanners → Add device.'),
      const _Step(2, 'It may show up automatically. If not: "Add manually" → "Select a shared printer by name", and enter:'),
      for (final p in printers.isEmpty ? <Printer?>[null] : printers) _CopyBox(_uri(sys, p, ips, scheme: 'http'), label: p?.name),
      const _Step(3, 'If Windows asks for a driver: Manufacturer "Microsoft" → "Microsoft IPP Class Driver".'),
      const _Step(4, 'Print a test page, then optionally "Set as default". Turn off "Let Windows manage my default printer".'),
      _Step(
        5,
        'POS software with the "Generic / Text Only" driver: turn on RAW port ${SystemPrinter.rawPort} above, then '
        'add a printer with a "Standard TCP/IP port" to ${_here ? '127.0.0.1' : (ips.isEmpty ? 'this device' : ips.first)}.',
      ),
      if (!_here) ...[
        const SizedBox(height: 8),
        Text('PowerShell:', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        for (final p in printers)
          _CopyBox(OsPrinterSetup.windowsCommand(OsPrinterSetup.windowsName(p.name), _uri(sys, p, ips, scheme: 'http'))),
      ],
    ];
  }

  List<Widget> _linux(BuildContext context, SystemPrinter sys, List<Printer> printers, List<String> ips) {
    return [
      if (_here && printers.isNotEmpty) ...[
        const _Step(1, 'Add the printer to CUPS in one click (driverless "everywhere" queue):'),
        for (final p in printers) _setupButtons(context, p, sys),
        const SizedBox(height: 4),
        Text('Or from a terminal:', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
      ] else
        const _Step(
          1,
          'Most desktops (Ubuntu, Fedora, Mint) add it automatically: open Settings → Printers. '
          'If it is not listed, run in a terminal:',
        ),
      for (final p in printers) ...[_CopyBox(OsPrinterSetup.linuxCommand(OsPrinterSetup.queueName(p.name), _uri(sys, p, ips)))],
      const _Step(2, 'Make it the default printer (optional):'),
      for (final p in printers.take(1)) _CopyBox(OsPrinterSetup.linuxDefaultCommand(OsPrinterSetup.queueName(p.name))),
      const _Step(3, 'Print from any app; choose the roll size (e.g. "80x297mm"). Needs CUPS (sudo apt install cups).'),
    ];
  }

  List<Widget> _mac(BuildContext context, SystemPrinter sys, List<Printer> printers, List<String> ips) {
    return [
      const _Step(
        1,
        'System Settings → Printers & Scanners → Add Printer. Universal Print appears under the default '
        'tab (Bonjour); select it, "Use: AirPrint", Add.',
      ),
      _Step(
        2,
        'If it is not listed: IP tab → Address ${_here ? '127.0.0.1' : (ips.isEmpty ? '<this-device-ip>' : ips.first)}:${sys.boundPort ?? sys.port}, '
        'Protocol "IPP", Queue below, Use "AirPrint":',
      ),
      for (final p in printers) _CopyBox(SystemPrinter.queuePath(p).substring(1), label: p.name),
      const _Step(3, 'Or from Terminal:'),
      for (final p in printers) _CopyBox(OsPrinterSetup.macCommand(OsPrinterSetup.queueName(p.name), _uri(sys, p, ips))),
      const _Step(4, 'iPhone / iPad on the same Wi-Fi: Share → Print → Select Printer.'),
    ];
  }

  Widget _setupButtons(BuildContext context, Printer p, SystemPrinter sys) => Padding(
    padding: const EdgeInsets.only(left: 34, bottom: 10),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: _busy || !sys.isRunning ? null : () => _add(context, sys, p, makeDefault: false),
          icon: const Icon(Icons.add),
          label: Text('Add "${p.name}"'),
        ),
        OutlinedButton(
          onPressed: _busy || !sys.isRunning ? null : () => _add(context, sys, p, makeDefault: true),
          child: const Text('Add as default'),
        ),
      ],
    ),
  );

  Future<void> _add(BuildContext context, SystemPrinter sys, Printer p, {required bool makeDefault}) async {
    setState(() => _busy = true);
    final SetupResult r;
    if (Platform.isWindows) {
      r = await OsPrinterSetup.addToWindows(
        OsPrinterSetup.windowsName(p.name),
        sys.localUri(p, scheme: 'http'),
        makeDefault: makeDefault,
      );
    } else {
      r = await OsPrinterSetup.addToLinux(OsPrinterSetup.queueName(p.name), sys.localUri(p), makeDefault: makeDefault);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) _reloadInstalled();
    if (context.mounted) showMessage(context, r.message, error: !r.ok);
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text('$n', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          ?action,
        ],
      ),
    );
  }
}

/// Monospace text with a copy button.
class _CopyBox extends StatelessWidget {
  const _CopyBox(this.text, {this.label});

  final String text;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 34, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(label!, style: theme.textTheme.labelMedium),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(text, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                ),
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: text));
                    showMessage(context, 'Copied');
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
