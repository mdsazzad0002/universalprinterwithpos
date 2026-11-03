import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/print_job.dart';
import 'widgets.dart';

class JobsScreen extends StatelessWidget {
  const JobsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = AppScope.of(context).printService;
    return Scaffold(
      appBar: AppBar(title: const Text('Print jobs')),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final jobs = service.recentJobs;
          if (jobs.isEmpty) return const Center(child: Text('No print jobs yet'));
          return ListView.separated(
            itemCount: jobs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final job = jobs[i];
              return ListTile(
                title: Text('${job.documentType} → ${job.printerName}'),
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
              );
            },
          );
        },
      ),
    );
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
            Text('Printer: ${job.printerName}'),
            Text('Source: ${job.source}'),
            Text('Attempts: ${job.attempts}'),
            if (job.reference != null) Text('Reference: ${job.reference}'),
            if (job.error != null) ...[
              const SizedBox(height: 8),
              Text(job.error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ],
            const SizedBox(height: 8),
            Text(
              const JsonEncoder.withIndent('  ').convert(job.payload),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              maxLines: 40,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        actions: [
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
              onPressed: () {
                service.retry(job.id);
                Navigator.pop(ctx);
              },
              child: const Text('Print again'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }
}
