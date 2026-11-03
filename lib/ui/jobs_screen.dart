import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/print_job.dart';
import 'print_preview.dart';
import 'theme.dart';
import 'widgets.dart';

class JobsScreen extends StatelessWidget {
  const JobsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = AppScope.of(context).printService;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Print jobs'),
        actions: [
          ListenableBuilder(
            listenable: service,
            builder: (context, _) => IconButton(
              tooltip: 'Clear jobs',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: service.recentJobs.any((j) => !j.status.isActive) ? () => _clear(context) : null,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final jobs = service.recentJobs;
          if (jobs.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'No print jobs yet',
              message: 'Every job sent to a printer is listed here with its status.',
            );
          }
          final scheme = Theme.of(context).colorScheme;
          return PageListView(
            children: [
              Card(
                child: Column(children: [
                  for (final (i, job) in jobs.indexed) ...[
                    if (i > 0) const Divider(indent: 16, endIndent: 16),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: IconBadge(
                        switch (job.status) {
                          JobStatus.completed => Icons.check_rounded,
                          JobStatus.failed => Icons.priority_high_rounded,
                          JobStatus.cancelled => Icons.block_rounded,
                          _ => Icons.hourglass_top_rounded,
                        },
                        size: 38,
                        color: switch (job.status) {
                          JobStatus.completed => successColor,
                          JobStatus.failed => scheme.error,
                          JobStatus.cancelled => scheme.outline,
                          _ => warningColor,
                        },
                      ),
                      title: Text('${job.documentType} → ${job.printerName}', overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          formatTime(job.createdAt),
                          job.source,
                          if (job.route != null) 'route: ${job.route}',
                          if (job.copies > 1) '${job.copies} copies',
                          if (job.error != null) job.error!,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: JobStatusChip(job.status),
                      onTap: () => _showDetails(context, job),
                    ),
                  ],
                ]),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _clear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear print jobs?'),
        content: const Text('Completed, failed and cancelled jobs are removed. Jobs still printing are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final removed = await AppScope.of(context).printService.clearFinished();
    if (context.mounted) showMessage(context, '$removed job(s) cleared');
  }

  void _showDetails(BuildContext context, PrintJob job) {
    final service = AppScope.of(context).printService;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(job.id),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            JobStatusChip(job.status),
            const SizedBox(height: 8),
            const SizedBox(height: 4),
            _detail(ctx, 'Printer', job.printerName),
            _detail(ctx, 'Source', job.source),
            _detail(ctx, 'Attempts', '${job.attempts}'),
            if (job.reference != null) _detail(ctx, 'Reference', job.reference!),
            if (job.error != null) ...[
              const SizedBox(height: 8),
              Text(job.error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                const JsonEncoder.withIndent('  ').convert(job.payload),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                maxLines: 40,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _preview(context, job);
            },
            icon: const Icon(Icons.preview_outlined, size: 18),
            label: const Text('Preview'),
          ),
          if (job.status == JobStatus.pending)
            TextButton(
              onPressed: () {
                service.cancel(job.id);
                Navigator.pop(ctx);
              },
              child: const Text('Cancel job'),
            ),
          if (!job.status.isActive)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await service.retry(job.id);
                if (context.mounted) await watchJob(context, job.id);
              },
              child: const Text('Print again'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _preview(BuildContext context, PrintJob job) {
    final s = AppScope.of(context);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PrintPreviewScreen(
        payload: job.payload,
        printer: s.printers.byId(job.printerId),
        printerName: job.printerName,
        paperWidth: job.paperWidth,
        copies: job.copies,
        printLabel: 'Print again',
        onPrint: job.status.isActive
            ? null
            : (ctx, _) async {
                await s.printService.retry(job.id);
                if (ctx.mounted) await watchJob(ctx, job.id);
              },
      ),
    ));
  }

  Widget _detail(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 84,
          child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
      ]),
    );
  }
}
