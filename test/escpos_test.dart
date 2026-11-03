import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/core/escpos/document_renderer.dart';
import 'package:universal_print/core/escpos/esc_pos_builder.dart';
import 'package:universal_print/core/escpos/mono_bitmap.dart';
import 'package:universal_print/core/escpos/rasterizer.dart';

/// Records what was rasterised and returns a fixed 8x2 bitmap.
class FakeRasterizer implements Rasterizer {
  final texts = <String>[];

  MonoBitmap get _bmp => MonoBitmap(8, 2, Uint8List.fromList([0xFF, 0x00]));

  @override
  Future<MonoBitmap> renderText(String text, {required int width, double fontSize = 24, bool bold = false, PosAlign align = PosAlign.left}) async {
    texts.add(text);
    return _bmp;
  }

  @override
  Future<MonoBitmap> renderRow(String left, String right, {required int width, double fontSize = 24, bool bold = false}) async {
    texts.add('$left|$right');
    return _bmp;
  }

  @override
  Future<MonoBitmap> decodeImage(Uint8List encoded, {required int maxWidth}) async => _bmp;
}

bool containsSeq(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length && ok; j++) {
      ok = haystack[i + j] == needle[j];
    }
    if (ok) return true;
  }
  return false;
}

void main() {
  group('EscPosBuilder', () {
    test('init, text and cut', () {
      final b = EscPosBuilder(paperWidthMm: 58)
        ..init()
        ..line('Hi')
        ..cut();
      expect(b.build(), [0x1B, 0x40, 0x1B, 0x74, 0x00, 0x48, 0x69, 0x0A, 0x1D, 0x56, 0x42, 0x00]);
    });

    test('non-ascii text is replaced, never sent as garbage', () {
      final b = EscPosBuilder(paperWidthMm: 58)..text('aé');
      expect(b.build(), [0x61, 0x3F]);
    });

    test('paper geometry', () {
      expect(EscPosBuilder(paperWidthMm: 58).charsPerLine, 32);
      expect(EscPosBuilder(paperWidthMm: 80).charsPerLine, 48);
      expect(EscPosBuilder(paperWidthMm: 80).dotsPerLine, 576);
    });

    test('raster is split into bands', () {
      final bmp = MonoBitmap(16, 300, Uint8List(2 * 300));
      final bytes = (EscPosBuilder(paperWidthMm: 58)..raster(bmp)).build();
      // two headers: 256 rows + 44 rows
      expect(bytes.length, 8 + 2 * 256 + 8 + 2 * 44);
      expect(bytes.sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 2, 0, 0x00, 0x01]);
      expect(bytes.sublist(8 + 512, 8 + 512 + 8), [0x1D, 0x76, 0x30, 0x00, 2, 0, 44, 0]);
    });

    test('qr store length includes header bytes', () {
      final bytes = (EscPosBuilder(paperWidthMm: 58)..qr('abc')).build();
      expect(containsSeq(bytes, [0x1D, 0x28, 0x6B, 6, 0, 0x31, 0x50, 0x30, 0x61, 0x62, 0x63]), isTrue);
    });
  });

  test('formatRow pads and wraps', () {
    expect(formatRow('Total', '200.00', 16), ['Total     200.00']);
    expect(formatRow('A very long product name', '10.00', 10), ['A very lon', 'g product ', 'name', '     10.00']);
  });

  test('MonoBitmap threshold and alignment', () {
    // 2x1: black, transparent
    final rgba = Uint8List.fromList([0, 0, 0, 255, 0, 0, 0, 0]);
    final bmp = MonoBitmap.fromRgba(rgba, 2, 1);
    expect(bmp.data, [0x80]);
    final centered = bmp.aligned(10, PosAlign.center);
    expect(centered.width, 10);
    expect(centered.isBlack(4, 0), isTrue);
    expect(centered.isBlack(0, 0), isFalse);
  });

  group('payloadToElements', () {
    test('receipt template', () {
      final els = payloadToElements({
        'document_type': 'receipt',
        'content': {
          'title': 'INVOICE',
          'invoice_no': 'INV-1001',
          'items': [{'name': 'Product A', 'qty': 2, 'price': 100}],
          'total': 200,
        },
      }, 32);
      expect(els.any((e) => e['type'] == 'row' && e['right'] == '200.00' && e['left'] == '  2 x 100.00'), isTrue);
      expect(els.any((e) => e['left'] == 'TOTAL' && e['bold'] == true), isTrue);
    });

    test('validation errors', () {
      expect(() => payloadToElements({'document_type': 'pdf'}, 32), throwsFormatException);
      expect(() => payloadToElements({'document_type': 'receipt', 'content': {}}, 32), throwsFormatException);
      expect(() => payloadToElements({'document_type': 'raw'}, 32), throwsFormatException);
      expect(
        () => payloadToElements({'document_type': 'receipt', 'content': {'items': [{'name': 'x', 'price': 'abc'}]}}, 32),
        throwsFormatException,
      );
    });
  });

  group('DocumentRenderer', () {
    test('Bangla text goes through the rasterizer, ASCII does not', () async {
      final r = FakeRasterizer();
      final bytes = await DocumentRenderer(paperWidthMm: 58, rasterizer: r).render([
        {'type': 'text', 'value': 'Hello'},
        {'type': 'text', 'value': 'বাংলা'},
        {'type': 'row', 'left': 'চাল', 'right': '১০'},
      ]);
      expect(r.texts, ['বাংলা', 'চাল|১০']);
      expect(containsSeq(bytes, ascii.encode('Hello')), isTrue);
      expect(containsSeq(bytes, [0x1D, 0x76, 0x30, 0x00]), isTrue);
      expect(containsSeq(bytes, [0x1D, 0x56, 0x42, 0x00]), isTrue, reason: 'auto cut');
    });

    test('raw jobs are passed through without auto cut', () async {
      final bytes = await DocumentRenderer(paperWidthMm: 58, rasterizer: FakeRasterizer())
          .render(payloadToElements({'document_type': 'raw', 'data': base64.encode([1, 2, 3])}, 32));
      expect(bytes, [0x1B, 0x40, 0x1B, 0x74, 0x00, 1, 2, 3]);
    });

    test('cash drawer alone kicks the drawer without feeding or cutting', () async {
      final bytes = await DocumentRenderer(paperWidthMm: 58, rasterizer: FakeRasterizer()).render([
        {'type': 'cash_drawer'},
      ]);
      expect(bytes, [0x1B, 0x40, 0x1B, 0x74, 0x00, 0x1B, 0x70, 0x00, 0x19, 0xFA]);
    });

    test('unknown element type fails', () {
      expect(
        DocumentRenderer(paperWidthMm: 58, rasterizer: FakeRasterizer()).render([{'type': 'nope'}]),
        throwsFormatException,
      );
    });
  });
}
