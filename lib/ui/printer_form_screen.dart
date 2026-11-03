import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../core/connection/bluetooth_bridge.dart';
import '../core/connection/ipp_connection.dart';
import '../core/connection/printer_connection.dart';
import '../core/connection/usb_printers.dart';
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
  late var _type = widget.printer?.connectionType ?? _types.first;

  /// Bluetooth: Android native bridge, BlueZ on Linux, COM port on Windows.
  static final _types = [
    if (BluetoothBridge.isSupported) ConnectionType.bluetooth,
    ConnectionType.network,
    if (UsbPrinters.isSupported) ConnectionType.usb,
  ];
  late var _paperWidth = widget.printer?.paperWidth ?? 58;
  late var _autoCut = widget.printer?.autoCut ?? true;
  late var _cashDrawer = widget.printer?.cashDrawer ?? CashDrawerMode.none;
  late var _protocol = widget.printer?.protocol ?? PrinterProtocol.escpos;
  late var _dpi = widget.printer?.dpi ?? 203;
  late final _labelWidth = TextEditingController(
    text: widget.printer?.isLabel == true ? '${widget.printer!.paperWidth}' : '50',
  );
  late final _labelHeight = TextEditingController(
    text: widget.printer?.isLabel == true ? (widget.printer!.labelHeight?.toString() ?? '') : '30',
  );
  late final _labelGap = TextEditingController(text: _mm(widget.printer?.labelGap ?? 2));

  static String _mm(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _port.dispose();
    _labelWidth.dispose();
    _labelHeight.dispose();
    _labelGap.dispose();
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
                for (final t in {..._types, _type})
                  ButtonSegment(value: t, label: Text(t.label), icon: Icon(connectionIcon(t))),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _address.clear();
                // A4 printers are reached over the network only.
                if (_type != ConnectionType.network && _protocol == PrinterProtocol.ipp) {
                  _protocol = PrinterProtocol.escpos;
                }
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
            ] else if (_type == ConnectionType.usb) ...[
              TextFormField(
                controller: _address,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'USB printer',
                  hintText: 'Plug in the printer, then tap to choose',
                  border: OutlineInputBorder(),
                ),
                onTap: _pickUsb,
                validator: (v) => (v == null || v.isEmpty) ? 'Choose a USB printer' : null,
              ),
            ] else ...[
              TextFormField(
                controller: _address,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: _protocol == PrinterProtocol.ipp ? 'IP address or IPP URL' : 'IP address / host',
                  hintText: '192.168.1.100',
                  helperText: _protocol == PrinterProtocol.ipp
                      ? 'CUPS queue: ipp://localhost:631/printers/<name>'
                      : null,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Enter the printer IP';
                  if (_protocol != PrinterProtocol.ipp) return null;
                  try {
                    IppConnection.uriFor(v);
                    return null;
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Port',
                  helperText: _protocol == PrinterProtocol.ipp
                      ? 'IPP uses 631 (ignored when the URL has a port)'
                      : 'Most POS printers use 9100',
                  border: const OutlineInputBorder(),
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
            Text('Printer type', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<PrinterProtocol>(
              initialValue: _protocol,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: [
                for (final p in PrinterProtocol.values)
                  DropdownMenuItem(
                    value: p,
                    child: Row(children: [
                      Icon(switch (p) {
                        PrinterProtocol.escpos => Icons.receipt_long,
                        PrinterProtocol.ipp => Icons.description_outlined,
                        _ => Icons.label_outline,
                      }),
                      const SizedBox(width: 12),
                      Text(p.label),
                    ]),
                  ),
              ],
              onChanged: (p) => setState(() {
                final wasIpp = _protocol == PrinterProtocol.ipp;
                _protocol = p ?? _protocol;
                if (_protocol == PrinterProtocol.ipp) {
                  if (_type != ConnectionType.network) _address.clear();
                  _type = ConnectionType.network;
                  _port.text = '631';
                } else if (wasIpp) {
                  _port.text = '9100';
                }
              }),
            ),
            const SizedBox(height: 16),
            if (_protocol == PrinterProtocol.ipp)
              const Text('Prints PDF documents (document_type "pdf") on A4 office printers and CUPS queues.')
            else if (_protocol == PrinterProtocol.escpos) ...[
              Text('Paper width', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 58, label: Text('58 mm')),
                  ButtonSegment(value: 80, label: Text('80 mm')),
                ],
                selected: {_paperWidth == 80 ? 80 : 58},
                onSelectionChanged: (s) => setState(() => _paperWidth = s.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto cut'),
                subtitle: const Text('Cut paper after each receipt (if the printer has a cutter)'),
                value: _autoCut,
                onChanged: (v) => setState(() => _autoCut = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<CashDrawerMode>(
                initialValue: _cashDrawer,
                decoration: const InputDecoration(
                  labelText: 'Cash drawer',
                  prefixIcon: Icon(Icons.point_of_sale_rounded),
                  helperText: 'Software can still open it any time (open_drawer, POST /api/drawer)',
                  helperMaxLines: 2,
                ),
                items: [
                  for (final m in CashDrawerMode.values) DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (v) => setState(() => _cashDrawer = v!),
              ),
            ] else ...[
              Text('Resolution', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 203, label: Text('203 dpi')),
                  ButtonSegment(value: 300, label: Text('300 dpi')),
                ],
                selected: {_dpi == 300 ? 300 : 203},
                onSelectionChanged: (s) => setState(() => _dpi = s.first),
              ),
              const SizedBox(height: 6),
              Text(
                'Most label printers are 203 dpi. If the print comes out too big or cut off on one side, choose 203.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: _mmField(_labelWidth, 'Label width', required: true)),
                const SizedBox(width: 12),
                Expanded(child: _mmField(_labelHeight, 'Label height', helper: 'Empty = continuous')),
                const SizedBox(width: 12),
                Expanded(child: _mmField(_labelGap, 'Gap', decimal: true)),
              ]),
            ],
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
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(Platform.isWindows
                      ? 'No COM port found. Pair the printer in Windows Bluetooth settings, '
                            'then under "More Bluetooth settings → COM Ports" add an outgoing port.'
                      : 'No paired devices. Pair your printer in Bluetooth settings first.'),
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
    } on PrinterConnectionException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? e.code, error: true);
    }
  }

  Widget _mmField(TextEditingController c, String label, {bool required = false, bool decimal = false, String? helper}) {
    return TextFormField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      decoration: InputDecoration(labelText: label, suffixText: 'mm', helperText: helper, border: const OutlineInputBorder()),
      validator: (v) {
        final text = v?.trim() ?? '';
        if (text.isEmpty) return required ? 'Required' : null;
        final n = num.tryParse(text);
        if (n == null || n < 0 || (!decimal && n != n.roundToDouble())) return 'Invalid';
        if (identical(c, _labelWidth) && (n < 20 || n > 112)) return '20–112';
        if (identical(c, _labelHeight) && (n < 5 || n > 1000)) return '5–1000';
        return null;
      },
    );
  }

  /// Fills protocol and resolution from what the printer reports about itself.
  void _applyHints(UsbDevice d) {
    final protocol = switch (d.protocolHint) {
      'tspl' => PrinterProtocol.tspl,
      'zpl' => PrinterProtocol.zpl,
      'escpos' => PrinterProtocol.escpos,
      _ => null,
    };
    if (protocol != null) _protocol = protocol;
    if (d.dpiHint != null) _dpi = d.dpiHint!;
    if (protocol != null || d.dpiHint != null) {
      showMessage(context, 'Detected: ${_protocol.label}${_protocol != PrinterProtocol.escpos ? ', $_dpi dpi' : ''}');
    }
  }

  Future<void> _pickUsb() async {
    try {
      final devices = await UsbPrinters.list();
      if (!mounted) return;
      final picked = await showModalBottomSheet<UsbDevice>(
        context: context,
        builder: (ctx) => SafeArea(
          child: devices.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(Platform.isAndroid
                      ? 'No USB device found. Connect the printer with an OTG cable and switch it on.'
                      : Platform.isWindows
                      ? 'No printer installed in Windows. Install the printer driver '
                            '(or "Generic / Text Only" on its USB port), then try again.'
                      : 'No USB printer found under /dev/usb/lp*. Connect the printer and switch it on.'),
                )
              : ListView(shrinkWrap: true, children: [
                  for (final d in devices)
                    ListTile(
                      leading: Icon(d.isPrinter ? Icons.print : Icons.usb),
                      title: Text(d.name),
                      subtitle: Text(d.address),
                      onTap: () => Navigator.pop(ctx, d),
                    ),
                ]),
        ),
      );
      if (picked == null) return;
      if (!await UsbPrinters.requestPermission(picked.address)) {
        if (mounted) showMessage(context, 'USB permission denied', error: true);
        return;
      }
      setState(() {
        _address.text = picked.address;
        if (_name.text.trim().isEmpty) _name.text = picked.name;
        _applyHints(picked);
      });
    } on PrinterConnectionException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? e.code, error: true);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final network = _type == ConnectionType.network;
    final label = _protocol == PrinterProtocol.tspl || _protocol == PrinterProtocol.zpl;
    final ipp = _protocol == PrinterProtocol.ipp;
    final base = widget.printer;
    final printer = Printer(
      id: base?.id ?? newId('PRN'),
      name: _name.text.trim(),
      connectionType: _type,
      address: _address.text.trim(),
      port: network ? int.parse(_port.text) : null,
      paperWidth: ipp ? 210 : (label ? int.parse(_labelWidth.text.trim()) : _paperWidth),
      autoCut: _autoCut,
      cashDrawer: _protocol == PrinterProtocol.escpos ? _cashDrawer : CashDrawerMode.none,
      protocol: _protocol,
      dpi: label ? _dpi : 203,
      labelHeight: label ? int.tryParse(_labelHeight.text.trim()) : null,
      labelGap: double.tryParse(_labelGap.text.trim()) ?? 2,
      isDefault: base?.isDefault ?? false,
      createdAt: base?.createdAt ?? DateTime.now(),
    );
    await AppScope.of(context).printers.save(printer);
    if (mounted) Navigator.pop(context);
  }
}
