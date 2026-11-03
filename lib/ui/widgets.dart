import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/print_job.dart';
import '../data/models/printer.dart';

class JobStatusChip extends StatelessWidget {
  const JobStatusChip(this.status, {super.key});

  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      JobStatus.completed => (scheme.primaryContainer, scheme.onPrimaryContainer),
      JobStatus.failed => (scheme.errorContainer, scheme.onErrorContainer),
      JobStatus.cancelled => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      _ => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(status.name, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

IconData connectionIcon(ConnectionType type) => switch (type) {
  ConnectionType.bluetooth => Icons.bluetooth,
  ConnectionType.network => Icons.wifi,
  ConnectionType.usb => Icons.usb,
};

void showMessage(BuildContext context, String message, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? scheme.error : null,
    ));
}

Future<void> runTestPrint(BuildContext context, Printer printer) async {
  final services = AppScope.of(context);
  try {
    final result = await services.printService.testPrint(printer);
    if (context.mounted) await watchJob(context, result.job.id);
  } catch (e) {
    if (context.mounted) showMessage(context, '$e', error: true);
  }
}

/// Shows live progress of a job: "Printing…" then success or the reason it
/// failed, with a Retry action.
Future<void> watchJob(BuildContext context, String jobId) async {
  final service = AppScope.of(context).printService;
  final messenger = ScaffoldMessenger.of(context);
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
      duration: Duration(minutes: 1),
      content: Row(children: [
        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 16),
        Text('Printing…'),
      ]),
    ));

  PrintJob? job;
  for (var i = 0; i < 600; i++) {
    job = await service.find(jobId);
    if (job == null || !job.status.isActive) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  messenger.hideCurrentSnackBar();
  if (job == null) return;
  final done = job;
  final ok = done.status == JobStatus.completed;
  messenger.showSnackBar(SnackBar(
    duration: Duration(seconds: ok ? 3 : 10),
    backgroundColor: ok ? null : scheme.error,
    content: Row(children: [
      Icon(ok ? Icons.check_circle : Icons.error, color: ok ? Colors.lightGreenAccent : scheme.onError),
      const SizedBox(width: 12),
      Expanded(child: Text(ok ? 'Printed on ${done.printerName}' : done.error ?? 'Print failed')),
    ]),
    action: ok
        ? null
        : SnackBarAction(
            label: 'Retry',
            textColor: scheme.onError,
            onPressed: () async {
              await service.retry(jobId);
              if (context.mounted) await watchJob(context, jobId);
            },
          ),
  ));
}

String formatTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
