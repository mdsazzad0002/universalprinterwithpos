import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../core/connection/bluetooth_bridge.dart';
import '../data/database.dart';
import '../data/models/printer.dart';
import 'widgets.dart';

class PrinterFormScreen extends StatefulWidget {
  const PrinterFormScreen({super.key, this.printer});

  final Printer? printer;

  @override
  State<PrinterFormScreen> createState() => _PrinterFormScreenState();
}

class _PrinterFormScreenState extends State<PrinterFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.printer?.name);
  late final _address = TextEditingController(text: widget.printer?.address);
  late final _port = TextEditingController(text: '${widget.printer?.port ?? 9100}');
  late var _type = widget.printer?.connectionType ?? ConnectionType.bluetooth;
  late var _paperWidth = widget.printer?.paperWidth ?? 58;
  late var _autoCut = widget.printer?.autoCut ?? true;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.printer != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit printer' : 'Add printer')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<ConnectionType>(
              segments: [
                for (final t in ConnectionType.values)
                  ButtonSegment(value: t, label: Text(t.label), icon: Icon(connectionIcon(t))),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _address.clear();
              }),
            ),
            const SizedBox(height: 16),
            if (_type == ConnectionType.bluetooth) ...[
              TextFormField(
                controller: _address,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Bluetooth device',
                  hintText: 'Choose a paired printer',
                  border: OutlineInputBorder(),
                ),
                onTap: _pickBluetooth,
                validator: (v) => (v == null || v.isEmpty) ? 'Choose a paired printer' : null,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: BluetoothBridge.openSettings,
                  icon: const Icon(Icons.settings_bluetooth),
                  label: const Text('Printer not listed? Pair it in Bluetooth settings'),
                ),
              ),
            ] else ...[
              TextFormField(
                controller: _address,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'IP address / host',
                  hintText: '192.168.1.100',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the printer IP' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Port',
                  helperText: 'Most POS printers use 9100',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final port = int.tryParse(v ?? '');
                  return port == null || port < 1 || port > 65535 ? 'Invalid port' : null;
                },
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Printer name',
                hintText: 'e.g. Cashier, Kitchen',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 16),
            Text('Paper width', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 58, label: Text('58 mm')),
                ButtonSegment(value: 80, label: Text('80 mm')),
              ],
              selected: {_paperWidth},
              onSelectionChanged: (s) => setState(() => _paperWidth = s.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto cut'),
              subtitle: const Text('Cut paper after each receipt (if the printer has a cutter)'),
              value: _autoCut,
              onChanged: (v) => setState(() => _autoCut = v),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: Text(editing ? 'Save' : 'Add printer')),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBluetooth() async {
    try {
      if (!await BluetoothBridge.requestPermission()) {
        if (mounted) showMessage(context, 'Bluetooth permission is required', error: true);
        return;
      }
      if (!await BluetoothBridge.isEnabled()) {
        if (mounted) showMessage(context, 'Turn on Bluetooth first', error: true);
        return;
      }
      final devices = await BluetoothBridge.bondedDevices();
      if (!mounted) return;
      final picked = await showModalBottomSheet<BluetoothDevice>(
        context: context,
        builder: (ctx) => SafeArea(
          child: devices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No paired devices. Pair your printer in Bluetooth settings first.'),
                )
              : ListView(shrinkWrap: true, children: [
                  for (final d in devices)
                    ListTile(
                      leading: Icon(d.isPrinter ? Icons.print : Icons.bluetooth),
                      title: Text(d.name),
                      subtitle: Text(d.address),
                      onTap: () => Navigator.pop(ctx, d),
                    ),
                ]),
        ),
      );
      if (picked == null) return;
      setState(() {
        _address.text = picked.address;
        if (_name.text.trim().isEmpty) _name.text = picked.name;
      });
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? e.code, error: true);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final network = _type == ConnectionType.network;
    final base = widget.printer;
    final printer = Printer(
      id: base?.id ?? newId('PRN'),
      name: _name.text.trim(),
      connectionType: _type,
      address: _address.text.trim(),
      port: network ? int.parse(_port.text) : null,
      paperWidth: _paperWidth,
      autoCut: _autoCut,
      isDefault: base?.isDefault ?? false,
      createdAt: base?.createdAt ?? DateTime.now(),
    );
    await AppScope.of(context).printers.save(printer);
    if (mounted) Navigator.pop(context);
  }
}
