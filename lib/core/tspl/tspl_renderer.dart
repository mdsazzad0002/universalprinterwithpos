import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../escpos/document_renderer.dart';
import '../escpos/esc_pos_builder.dart';
import '../escpos/mono_bitmap.dart';
import '../escpos/rasterizer.dart';

/// Renders the same element list as [DocumentRenderer] into a TSPL label
/// program (TSC, Xprinter label mode, HPRT, TD-series, ...).
///
/// Text is always rasterised (so Bangla works and the layout is identical on
/// every printer); barcodes and QR codes use the printer's own generators so
/// they stay sharp and scannable.
class TsplRenderer {
  TsplRenderer({required this.geometry, this.gapMm = 2, required this.rasterizer})
    : assert(geometry.label);

  final PaperGeometry geometry;
  final double gapMm;
  final Rasterizer rasterizer;

  double get _scale => geometry.dpi / 203;
  int _d(num dotsAt203) => (dotsAt203 * _scale).round();

  Future<Uint8List> render(List<Element> elements) async {
    // Raw-only documents are complete TSPL programs from the caller.
    if (elements.isNotEmpty && elements.every((e) => e['type'] == 'raw')) {
      final out = BytesBuilder(copy: false);
      for (var i = 0; i < elements.length; i++) {
        out.add(_base64(elements[i]['base64'], i));
      }
      return out.toBytes();
    }

    final margin = _d(8); // ~1 mm: label edges do not print reliably.
    final width = (geometry.dotsPerLine - 2 * margin) & ~7;
    final body = BytesBuilder(copy: false);
    var y = margin;

    void cmd(String line) => body.add(utf8.encode('$line\r\n'));
    void bitmap(MonoBitmap bmp, int x) {
      body.add(ascii.encode('BITMAP $x,$y,${bmp.widthBytes},${bmp.height},0,'));
      // TSPL bitmaps use 0 for a printed dot.
      body.add(Uint8List.fromList([for (final b in bmp.data) ~b & 0xFF]));
      body.add(const [0x0D, 0x0A]);
      y += bmp.height;
    }

    int alignX(int w, PosAlign align) => switch (align) {
      PosAlign.left => margin,
      PosAlign.center => margin + math.max(0, (width - w) ~/ 2),
      PosAlign.right => margin + math.max(0, width - w),
    };

    for (var i = 0; i < elements.length; i++) {
      final e = elements[i];
      final bold = e['bold'] == true;
      final align = parseAlign(e['align']);
      switch (e['type']) {
        case 'text':
          final size = _int(e['size'], 1).clamp(1, 4);
          bitmap(
            await rasterizer.renderText('${e['value'] ?? ''}',
                width: width, fontSize: 24 * _scale * size, bold: bold, align: align),
            margin,
          );
        case 'row':
          bitmap(
            await rasterizer.renderRow('${e['left'] ?? ''}', '${e['right'] ?? ''}',
                width: width, fontSize: 24 * _scale, bold: bold),
            margin,
          );
        case 'line':
          final thickness = math.max(2, _d(2));
          cmd('BAR $margin,${y + _d(6)},$width,$thickness');
          y += _d(14);
        case 'feed':
          y += _int(e['lines'], 1) * _d(30);
        case 'barcode':
          final value = '${e['value'] ?? ''}';
          final narrow = math.max(2, _d(2));
          final height = _d(_int(e['height'], 80));
          // CODE128-B: (data + start + checksum) * 11 modules + 13 stop modules.
          final w = ((value.length + 2) * 11 + 13) * narrow;
          cmd('BARCODE ${alignX(w, e['align'] == null ? PosAlign.center : align)},$y,"128",$height,1,0,$narrow,$narrow,"${_quote(value)}"');
          y += height + _d(30);
        case 'qr':
          final value = '${e['value'] ?? ''}';
          final cell = math.max(1, _d(_int(e['size'], 6) * 0.8));
          final w = _qrModules(utf8.encode(value).length) * cell;
          cmd('QRCODE ${alignX(w, e['align'] == null ? PosAlign.center : align)},$y,M,$cell,A,0,"${_quote(value)}"');
          y += w + _d(8);
        case 'image':
          final bmp = await rasterizer.decodeImage(
            _base64(e['base64'], i),
            maxWidth: _int(e['width'], width).clamp(8, width),
          );
          bitmap(bmp.aligned(width, e['align'] == null ? PosAlign.center : align), margin);
        case 'raw':
          body.add(_base64(e['base64'], i));
        case 'cut' || 'cash_drawer':
          break; // Receipt-only; the label printer feeds to the next gap itself.
        default:
          throw FormatException('Unknown element type "${e['type']}" at index $i');
      }
    }

    // Fixed labels use the configured size; continuous paper fits the content.
    final contentMm = ((y + margin) / geometry.dotsPerMm).ceil();
    final heightMm = geometry.heightMm ?? math.max(contentMm, 10);
    final gap = geometry.heightMm == null ? 0.0 : gapMm;

    final out = BytesBuilder(copy: false)
      ..add(ascii.encode(
        'SIZE ${geometry.widthMm} mm,$heightMm mm\r\n'
        'GAP ${_mm(gap)} mm,0 mm\r\n'
        'DIRECTION 1,0\r\n'
        'REFERENCE 0,0\r\n'
        'CLS\r\n',
      ))
      ..add(body.toBytes())
      ..add(ascii.encode('PRINT 1,1\r\n'));
    return out.toBytes();
  }

  /// TSPL escapes a double quote inside a string as \["].
  static String _quote(String v) => v.replaceAll('"', r'\["]');

  static String _mm(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);

  /// QR side length in modules for byte mode, error level M.
  static int _qrModules(int bytes) {
    const capacity = [14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412, 450, 504, 560, 624, 666];
    var version = capacity.indexWhere((c) => bytes <= c) + 1;
    if (version == 0) version = 20;
    return 17 + 4 * version;
  }
}

Uint8List _base64(Object? value, int index) {
  if (value is! String || value.isEmpty) {
    throw FormatException('Element $index needs a base64 string');
  }
  try {
    return base64.decode(value.replaceFirst(RegExp(r'^data:[^,]*,'), ''));
  } on FormatException {
    throw FormatException('Element $index has invalid base64 data');
  }
}

int _int(Object? v, int fallback) => switch (v) {
  num n => n.toInt(),
  String s => int.tryParse(s) ?? fallback,
  _ => fallback,
};
