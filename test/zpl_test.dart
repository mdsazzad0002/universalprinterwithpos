import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/core/connection/usb_printers.dart';
import 'package:universal_print/core/escpos/esc_pos_builder.dart';
import 'package:universal_print/core/escpos/mono_bitmap.dart';
import 'package:universal_print/core/escpos/rasterizer.dart';
import 'package:universal_print/core/zpl/zpl_renderer.dart';
import 'package:universal_print/data/models/printer.dart';

class _Rasterizer implements Rasterizer {
  // 16 dots wide, 2 rows: first row black on the left half.
  MonoBitmap get _bmp => MonoBitmap(16, 2, Uint8List.fromList([0xFF, 0x00, 0x00, 0x00]));
  @override
  Future<MonoBitmap> renderText(String text, {required int width, double fontSize = 24, bool bold = false, PosAlign align = PosAlign.left}) async => _bmp;
  @override
  Future<MonoBitmap> renderRow(String left, String right, {required int width, double fontSize = 24, bool bold = false}) async => _bmp;
  @override
  Future<MonoBitmap> decodeImage(Uint8List encoded, {required int maxWidth}) async => _bmp;
}

Printer _zebra({int? height = 30}) => Printer(
  id: 'z', name: 'ZD220', connectionType: ConnectionType.network, address: '10.0.0.9', port: 9100,
  paperWidth: 50, protocol: PrinterProtocol.zpl, dpi: 203, labelHeight: height, createdAt: DateTime(2026),
);

void main() {
  test('ZPL printers are label printers with label geometry', () {
    expect(_zebra().isLabel, isTrue);
    expect(_zebra().geometry().toJson()['type'], 'label');
    expect(_zebra().paperLabel, '50×30 mm label · 203 dpi');
  });

  test('renders a ZPL label with graphic, barcode, QR and escaped data', () async {
    final zpl = utf8.decode(await ZplRenderer(geometry: _zebra().geometry(), rasterizer: _Rasterizer()).render([
      {'type': 'text', 'value': 'বাংলা'},
      {'type': 'line'},
      {'type': 'barcode', 'value': 'A^1_2'},
      {'type': 'qr', 'value': 'hi'},
      {'type': 'cut'},
    ]));
    expect(zpl, startsWith('^XA\n^CI28\n^PW392\n^LL240\n^LH0,0\n'), reason: '30 mm at 8 dots/mm');
    // 2 bytes per row, 2 rows, 1 = black (not inverted like TSPL).
    expect(zpl, contains('^FO8,8^GFA,4,4,2,FF000000^FS'));
    expect(zpl, contains('^GB376,2,2^FS'));
    expect(zpl, contains('^BCN,80,Y,N,N^FH^FDA_5E1_5F2^FS'), reason: '^ and _ are hex escaped');
    expect(zpl, contains('^BQN,2,5^FDMA,hi^FS'));
    expect(zpl, endsWith('^PQ1\n^XZ\n'));
  });

  test('continuous paper sizes the label to the content', () async {
    final zpl = utf8.decode(await ZplRenderer(geometry: _zebra(height: null).geometry(), rasterizer: _Rasterizer())
        .render([{'type': 'text', 'value': 'x'}]));
    expect(zpl, contains('^LL80\n'), reason: 'minimum 10 mm');
  });

  test('raw-only documents pass through untouched', () async {
    final raw = '^XA^FO10,10^FDhi^FS^XZ';
    final out = await ZplRenderer(geometry: _zebra().geometry(), rasterizer: _Rasterizer()).render([
      {'type': 'raw', 'base64': base64.encode(utf8.encode(raw))},
    ]);
    expect(utf8.decode(out), raw);
  });

  test('USB device id with ZPL is detected', () {
    const d = UsbDevice(name: 'Zebra', address: '0a5f:0001', isPrinter: true, deviceId: 'MFG:Zebra;CMD:ZPL;MDL:ZD220;');
    expect(d.protocolHint, 'zpl');
  });
}
