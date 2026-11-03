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
    await services.printService.testPrint(printer);
    if (context.mounted) showMessage(context, 'Test print sent to ${printer.name}');
  } catch (e) {
    if (context.mounted) showMessage(context, '$e', error: true);
  }
}

String formatTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
