import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/printer.dart';
import 'print_preview.dart';
import 'printer_form_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class PrintersScreen extends StatelessWidget {
  const PrintersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).printers;
    return Scaffold(
      appBar: AppBar(title: const Text('Printers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context),
        icon: const Icon(Icons.add),
        label: const Text('Add printer'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final printers = store.printers;
          if (printers.isEmpty) {
            return EmptyState(
              icon: Icons.print_outlined,
              title: 'No printers yet',
              message: 'Connect a Bluetooth, Wi-Fi/LAN or USB printer to start printing.',
              action: FilledButton.icon(
                onPressed: () => _openForm(context),
                icon: const Icon(Icons.add),
                label: const Text('Add printer'),
              ),
            );
          }
          final defaultId = store.defaultPrinter?.id;
          return PageListView(
            bottom: 96,
            children: [
              for (final p in printers) _PrinterCard(
                printer: p,
                isDefault: p.id == defaultId,
                onOpen: () => _openForm(context, p),
                onAction: (action) => _onAction(context, p, action),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openForm(BuildContext context, [Printer? printer]) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrinterFormScreen(printer: printer)));
  }

  Future<void> _onAction(BuildContext context, Printer p, String action) async {
    final store = AppScope.of(context).printers;
    switch (action) {
      case 'test':
        await runTestPrint(context, p);
      case 'preview':
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PrintPreviewScreen(
            payload: AppScope.of(context).printService.testPayload(p),
            payloadFor: AppScope.of(context).printService.testPayload,
            printer: p,
            printLabel: 'Test print',
            onPrint: (ctx, printer) => runTestPrint(ctx, printer ?? p),
          ),
        ));
      case 'drawer':
        await runOpenCashDrawer(context, p);
      case 'default':
        await store.setDefault(p.id);
      case 'edit':
        _openForm(context, p);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${p.name}?'),
            icon: const Icon(Icons.delete_outline),
            content: const Text('Apps using this printer ID will get an error until you point them to another printer.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) await store.delete(p.id);
    }
  }
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({required this.printer, required this.isDefault, required this.onOpen, required this.onAction});

  final Printer printer;
  final bool isDefault;
  final VoidCallback onOpen;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = printer;
    final hasDrawer = !p.isLabel && !p.isDocument;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        mouseCursor: clickCursor,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBadge(connectionIcon(p.connectionType), size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(p.name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
                    if (isDefault) ...[
                      const SizedBox(width: 8),
                      const StatusPill(label: 'Default', color: warningColor),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    p.target,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
              PopupMenuButton<String>(
                onSelected: onAction,
                itemBuilder: (_) => [
                  _item('test', Icons.print_outlined, 'Test print'),
                  if (!p.isDocument) _item('preview', Icons.preview_outlined, 'Preview test print'),
                  if (hasDrawer) _item('drawer', Icons.point_of_sale_outlined, 'Open cash drawer'),
                  if (!isDefault) _item('default', Icons.star_outline, 'Set as default'),
                  _item('edit', Icons.edit_outlined, 'Edit'),
                  _item('delete', Icons.delete_outline, 'Delete'),
                ],
              ),
            ]),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _Tag(p.connectionType.label),
                _Tag(p.protocol.label),
                _Tag(p.paperLabel),
              ]),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 12))),
                    onPressed: () => onAction('test'),
                    icon: const Icon(Icons.print_outlined, size: 18),
                    label: const Text('Test print'),
                  ),
                ),
                if (hasDrawer) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 12))),
                      onPressed: () => onAction('drawer'),
                      icon: const Icon(Icons.point_of_sale_rounded, size: 18),
                      label: const Text('Cash drawer'),
                    ),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  static PopupMenuItem<String> _item(String value, IconData icon, String label) => PopupMenuItem(
    value: value,
    child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
    );
  }
}
