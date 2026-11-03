import 'package:flutter/material.dart';

import '../app_services.dart';
import '../services/local_api_server.dart';
import 'api_screen.dart';
import 'dashboard_screen.dart';
import 'jobs_screen.dart';
import 'menu_screen.dart';
import 'printers_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _index = 0;
  LocalApiServer? _api;
  final _shownPairings = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _api ??= AppScope.of(context).apiServer..addListener(_onApiChanged);
  }

  @override
  void dispose() {
    _api?.removeListener(_onApiChanged);
    super.dispose();
  }

  /// A software asked to pair: let the user approve it.
  void _onApiChanged() {
    for (final p in _api!.pendingPairings) {
      if (_shownPairings.add(p.id)) _showPairingDialog(p);
    }
  }

  Future<void> _showPairingDialog(PairingRequest p) async {
    final approve = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.link),
        title: const Text('Connect software?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(p.clientName, style: Theme.of(ctx).textTheme.titleLarge, textAlign: TextAlign.center),
          Text(p.clientId, style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 16),
          const Text('Check that the software shows the same code:'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              p.code,
              style: Theme.of(ctx).textTheme.displaySmall?.copyWith(
                letterSpacing: 6,
                fontWeight: FontWeight.bold,
                color: Theme.of(ctx).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Reject')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    );
    if (approve == true) {
      await _api!.approvePairing(p.id);
      if (mounted) setState(() => _index = 3);
    } else {
      _api!.rejectPairing(p.id);
    }
  }

  static const _destinations = [
    (Icons.space_dashboard_outlined, Icons.space_dashboard, 'Dashboard'),
    (Icons.print_outlined, Icons.print, 'Printers'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'Jobs'),
    (Icons.hub_outlined, Icons.hub, 'Connect'),
    (Icons.grid_view_outlined, Icons.grid_view_rounded, 'Menu'),
  ];

  /// Navigation destinations have no cursor setting; a region inside their
  /// ink well (sized like the selection pill) shows the hand.
  static Widget _pointer(Widget child) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: child is Icon ? SizedBox(width: 56, height: 32, child: child) : child,
  );

  @override
  Widget build(BuildContext context) {
    final body = IndexedStack(
      index: _index,
      children: [
        DashboardScreen(onOpenTab: (i) => setState(() => _index = i)),
        const PrintersScreen(),
        const JobsScreen(),
        const ApiScreen(),
        const MenuScreen(),
      ],
    );
    void select(int i) => setState(() => _index = i);

    if (MediaQuery.sizeOf(context).width >= 840) {
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: select,
            labelType: NavigationRailLabelType.all,
            minWidth: 88,
            groupAlignment: -0.85,
            leading: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Image.asset('assets/logo.png', height: 40, filterQuality: FilterQuality.medium),
            ),
            destinations: [
              for (final (icon, selected, label) in _destinations)
                NavigationRailDestination(
                  icon: _pointer(Icon(icon)),
                  selectedIcon: _pointer(Icon(selected)),
                  label: _pointer(Text(label)),
                ),
            ],
          ),
          VerticalDivider(width: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(child: body),
        ]),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: select,
        destinations: [
          for (final (icon, selected, label) in _destinations)
            NavigationDestination(icon: _pointer(Icon(icon)), selectedIcon: _pointer(Icon(selected)), label: label),
        ],
      ),
    );
  }
}
