import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_services.dart';
import '../data/models/print_job.dart';
import '../data/models/printer.dart';
import 'theme.dart';

class JobStatusChip extends StatelessWidget {
  const JobStatusChip(this.status, {super.key});

  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      JobStatus.completed => successColor,
      JobStatus.failed => scheme.error,
      JobStatus.cancelled => scheme.outline,
      _ => warningColor,
    };
    return StatusPill(label: status.name, color: color);
  }
}

/// A small rounded label with a colored dot.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    ]),
  );
}

/// An icon in a tinted rounded square, used as a list leading.
class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, this.color, this.size = 40});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(icon, color: c, size: size * 0.52),
    );
  }
}

/// A titled group of rows inside one card, separated by dividers.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, this.trailing, required this.children});

  final String? title;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (title != null) SectionHeader(title!, trailing: trailing),
    Card(
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(indent: 16, endIndent: 16),
          children[i],
        ],
      ]),
    ),
    const SizedBox(height: 20),
  ]);
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(children: [
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ),
        ?trailing,
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconBadge(icon, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      ),
    );
  }
}

/// A scrolling page whose content stays a readable width on desktop.
class PageListView extends StatelessWidget {
  const PageListView({super.key, required this.children, this.bottom = 24});

  final List<Widget> children;
  final double bottom;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = constraints.maxWidth > 880 ? (constraints.maxWidth - 840) / 2 : 16.0;
      return ListView(padding: EdgeInsets.fromLTRB(side, 8, side, bottom), children: children);
    },
  );
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

/// Opens a link in the app that handles it (WhatsApp, dialer, mail, browser).
Future<void> openLink(BuildContext context, Uri uri) async {
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && context.mounted) showMessage(context, 'Cannot open $uri', error: true);
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

Future<void> runOpenCashDrawer(BuildContext context, Printer printer) async {
  final services = AppScope.of(context);
  try {
    final result = await services.printService.openCashDrawer(printer);
    if (context.mounted) {
      await watchJob(context, result.job.id, busy: 'Opening cash drawer…', done: 'Cash drawer opened');
    }
  } catch (e) {
    if (context.mounted) showMessage(context, '$e', error: true);
  }
}

/// Shows live progress of a job: "Printing…" then success or the reason it
/// failed, with a Retry action.
Future<void> watchJob(BuildContext context, String jobId, {String busy = 'Printing…', String? done}) async {
  final service = AppScope.of(context).printService;
  final messenger = ScaffoldMessenger.of(context);
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: const Duration(minutes: 1),
      content: Row(children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 16),
        Text(busy),
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
  final finished = job;
  final ok = finished.status == JobStatus.completed;
  messenger.showSnackBar(SnackBar(
    duration: Duration(seconds: ok ? 3 : 10),
    backgroundColor: ok ? null : scheme.error,
    content: Row(children: [
      Icon(ok ? Icons.check_circle : Icons.error, color: ok ? const Color(0xFF4ADE80) : scheme.onError),
      const SizedBox(width: 12),
      Expanded(child: Text(ok ? done ?? 'Printed on ${finished.printerName}' : finished.error ?? 'Print failed')),
    ]),
    action: ok
        ? null
        : SnackBarAction(
            label: 'Retry',
            textColor: scheme.onError,
            onPressed: () async {
              await service.retry(jobId);
              if (context.mounted) await watchJob(context, jobId, busy: busy, done: done);
            },
          ),
  ));
}

String formatTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
