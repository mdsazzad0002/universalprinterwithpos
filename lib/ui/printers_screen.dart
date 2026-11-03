import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/printer.dart';
import 'printer_form_screen.dart';
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
            return const Center(child: Text('No printers yet.\nTap "Add printer" to connect one.', textAlign: TextAlign.center));
          }
          final defaultId = store.defaultPrinter?.id;
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: printers.length,
            itemBuilder: (context, i) {
              final p = printers[i];
              return ListTile(
                leading: Icon(connectionIcon(p.connectionType)),
                title: Row(children: [
                  Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                  if (p.id == defaultId) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.star, size: 16, color: Colors.amber),
                  ],
                ]),
                subtitle: Text('${p.target} · ${p.paperWidth} mm · ${p.id}'),
                onTap: () => _openForm(context, p),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) => _onAction(context, p, action),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'test', child: Text('Test print')),
                    if (p.id != defaultId) const PopupMenuItem(value: 'default', child: Text('Set as default')),
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              );
            },
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
      case 'default':
        await store.setDefault(p.id);
      case 'edit':
        _openForm(context, p);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${p.name}?'),
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
