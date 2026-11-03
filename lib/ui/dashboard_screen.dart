import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/print_job.dart';
import 'widgets.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.onOpenTab});

  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Image.asset('assets/logo.png', height: 32, filterQuality: FilterQuality.medium),
          const SizedBox(width: 10),
          const Text('Universal Print'),
        ]),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.printers, s.printService, s.apiServer]),
        builder: (context, _) {
          final printer = s.printers.defaultPrinter;
          final jobs = s.printService.recentJobs;
          final today = DateTime.now();
          final todayJobs = jobs.where((j) =>
              j.createdAt.year == today.year && j.createdAt.month == today.month && j.createdAt.day == today.day);
          final failed = todayJobs.where((j) => j.status == JobStatus.failed).length;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(children: [
                _Stat(label: 'Printers', value: '${s.printers.printers.length}', onTap: () => onOpenTab(1)),
                const SizedBox(width: 12),
                _Stat(label: 'Jobs today', value: '${todayJobs.length}', onTap: () => onOpenTab(2)),
                const SizedBox(width: 12),
                _Stat(label: 'Failed today', value: '$failed', onTap: () => onOpenTab(2), alert: failed > 0),
              ]),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: Icon(printer == null ? Icons.print_disabled : connectionIcon(printer.connectionType)),
                  title: Text(printer?.name ?? 'No default printer'),
                  subtitle: Text(printer == null
                      ? 'Add a printer to start printing'
                      : '${printer.connectionType.label} · ${printer.target} · ${printer.paperLabel}'),
                  trailing: printer == null
                      ? FilledButton(onPressed: () => onOpenTab(1), child: const Text('Add'))
                      : FilledButton.tonal(
                          onPressed: () => runTestPrint(context, printer),
                          child: const Text('Test print'),
                        ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: Icon(
                    s.apiServer.isRunning ? Icons.cloud_done : Icons.cloud_off,
                    color: s.apiServer.isRunning ? Colors.green : Theme.of(context).colorScheme.error,
                  ),
                  title: Text(s.apiServer.isRunning ? 'Print API running' : 'Print API stopped'),
                  subtitle: Text(s.apiServer.lastError ??
                      '${s.apiServer.allowLan ? '0.0.0.0' : '127.0.0.1'}:${s.apiServer.port}'),
                  onTap: () => onOpenTab(3),
                ),
              ),
              const SizedBox(height: 8),
              Text('Recent jobs', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              if (jobs.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('No print jobs yet')),
              for (final job in jobs.take(5))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${job.documentType} → ${job.printerName}'),
                  subtitle: Text(formatTime(job.createdAt)),
                  trailing: JobStatusChip(job.status),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.onTap, this.alert = false});

  final String label;
  final String value;
  final VoidCallback onTap;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: theme.textTheme.headlineSmall?.copyWith(
                color: alert ? theme.colorScheme.error : null,
                fontWeight: FontWeight.w600,
              )),
              Text(label, style: theme.textTheme.bodySmall),
            ]),
          ),
        ),
      ),
    );
  }
}
