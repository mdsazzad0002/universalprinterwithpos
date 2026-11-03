import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/core/connection/usb_printers.dart';
import 'package:universal_print/core/escpos/esc_pos_builder.dart';
import 'package:universal_print/core/escpos/mono_bitmap.dart';
import 'package:universal_print/core/escpos/rasterizer.dart';
import 'package:universal_print/core/tspl/tspl_renderer.dart';
import 'package:universal_print/data/models/printer.dart';

class _Rasterizer implements Rasterizer {
  final fontSizes = <double>[];
  // 16 dots wide, 2 rows: first row black on the left half.
  MonoBitmap get _bmp => MonoBitmap(16, 2, Uint8List.fromList([0xFF, 0x00, 0x00, 0x00]));
  @override
  Future<MonoBitmap> renderText(String text, {required int width, double fontSize = 24, bool bold = false, PosAlign align = PosAlign.left}) async {
    fontSizes.add(fontSize);
    return _bmp;
  }
  @override
  Future<MonoBitmap> renderRow(String left, String right, {required int width, double fontSize = 24, bool bold = false}) async => _bmp;
  @override
  Future<MonoBitmap> decodeImage(Uint8List encoded, {required int maxWidth}) async => _bmp;
}

Printer _label({int? height = 30, int dpi = 300}) => Printer(
  id: 'p', name: 'TD-401H', connectionType: ConnectionType.usb, address: '36fc:1411',
  paperWidth: 50, protocol: PrinterProtocol.tspl, dpi: dpi, labelHeight: height, createdAt: DateTime(2026),
);

void main() {
  test('label geometry uses full width at the printer dpi', () {
    final g = _label().geometry();
    expect(g.dotsPerLine, 584); // 50 mm * 11.81 dots/mm = 590 -> multiple of 8
    expect(g.toJson()['type'], 'label');
    expect(g.toJson()['height_mm'], 30);
    expect(_label(dpi: 203).geometry().dotsPerLine, 392);
  });

  test('renders a TSPL program with size, gap, bitmap, barcode and print', () async {
    final r = _Rasterizer();
    final bytes = await TsplRenderer(geometry: _label().geometry(), rasterizer: r).render([
      {'type': 'text', 'value': 'বাংলা', 'size': 2},
      {'type': 'barcode', 'value': 'A"1'},
      {'type': 'qr', 'value': 'hi'},
      {'type': 'cut'},
    ]);
    final text = latin1.decode(bytes);
    expect(text, startsWith('SIZE 50 mm,30 mm\r\nGAP 2 mm,0 mm\r\nDIRECTION 1,0\r\nREFERENCE 0,0\r\nCLS\r\n'));
    expect(text, contains('BITMAP 12,12,2,2,0,'));
    expect(text, contains(r'"128"'));
    expect(text, contains(r'"A\["]1"'), reason: 'quotes are escaped');
    expect(text, contains('QRCODE '));
    expect(text, endsWith('PRINT 1,1\r\n'));
    expect(text, isNot(contains('CUT')));
    expect(r.fontSizes.single, closeTo(24 * 300 / 203 * 2, 0.01), reason: 'same physical size at 300 dpi');

    // Bitmap data is inverted: 0 = printed dot.
    final start = bytes.indexOf(0x2C, text.indexOf('BITMAP 12,12,2,2,0') + 17) + 1;
    expect(bytes.sublist(start, start + 4), [0x00, 0xFF, 0xFF, 0xFF]);
  });

  test('continuous paper: height follows content, no gap', () async {
    final bytes = await TsplRenderer(geometry: _label(height: null).geometry(), rasterizer: _Rasterizer())
        .render([{'type': 'text', 'value': 'x'}]);
    expect(latin1.decode(bytes), contains('SIZE 50 mm,10 mm\r\nGAP 0 mm,0 mm'));
  });

  test('raw TSPL is passed through untouched', () async {
    final raw = ascii.encode('SIZE 40 mm,30 mm\r\nCLS\r\nPRINT 1\r\n');
    final bytes = await TsplRenderer(geometry: _label().geometry(), rasterizer: _Rasterizer())
        .render([{'type': 'raw', 'base64': base64.encode(raw)}]);
    expect(bytes, raw);
  });

  test('protocol and dpi hints from the IEEE 1284 id', () {
    const d = UsbDevice(
      name: 'Label TD-401H(300dpi)', address: '36fc:1411', isPrinter: true,
      deviceId: 'MFG:Label ;CMD:TSPL ;MDL:TD-401H(300dpi) ;CLS:PRINTER ;',
    );
    expect(d.protocolHint, 'tspl');
    expect(d.dpiHint, 300);
    expect(const UsbDevice(name: 'x', address: 'a', isPrinter: true, deviceId: 'CMD:ESC/POS;').protocolHint, 'escpos');
  });
}
