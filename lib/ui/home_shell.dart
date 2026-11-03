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
          Text(p.code, style: Theme.of(ctx).textTheme.displaySmall?.copyWith(letterSpacing: 6, fontWeight: FontWeight.bold)),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(onOpenTab: (i) => setState(() => _index = i)),
          const PrintersScreen(),
          const JobsScreen(),
          const ApiScreen(),
          const MenuScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.print_outlined), selectedIcon: Icon(Icons.print), label: 'Printers'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Jobs'),
          NavigationDestination(icon: Icon(Icons.hub_outlined), selectedIcon: Icon(Icons.hub), label: 'Connect'),
          NavigationDestination(icon: Icon(Icons.menu), selectedIcon: Icon(Icons.menu_open), label: 'Menu'),
        ],
      ),
    );
  }
}
