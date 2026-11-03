import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../escpos/document_renderer.dart';
import '../escpos/esc_pos_builder.dart';
import '../escpos/mono_bitmap.dart';
import '../escpos/rasterizer.dart';

/// Renders the same element list as [DocumentRenderer] into a ZPL II label
/// (Zebra and ZPL-compatible printers).
///
/// Like the TSPL renderer, text is rasterised (Bangla, identical layout) and
/// barcodes / QR codes use the printer's generators.
class ZplRenderer {
  ZplRenderer({required this.geometry, required this.rasterizer}) : assert(geometry.label);

  final PaperGeometry geometry;
  final Rasterizer rasterizer;

  double get _scale => geometry.dpi / 203;
  int _d(num dotsAt203) => (dotsAt203 * _scale).round();

  Future<Uint8List> render(List<Element> elements) async {
    // Raw-only documents are complete ZPL programs from the caller.
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

    void cmd(String fields) => body.add(utf8.encode('$fields\n'));
    void bitmap(MonoBitmap bmp, int x) {
      final total = bmp.widthBytes * bmp.height;
      final hex = StringBuffer();
      for (final b in bmp.data) {
        hex.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
      // ZPL graphics use 1 for a printed dot, like MonoBitmap.
      cmd('^FO$x,$y^GFA,$total,$total,${bmp.widthBytes},$hex^FS');
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
          cmd('^FO$margin,${y + _d(6)}^GB$width,$thickness,$thickness^FS');
          y += _d(14);
        case 'feed':
          y += _int(e['lines'], 1) * _d(30);
        case 'barcode':
          final value = '${e['value'] ?? ''}';
          final narrow = math.max(2, _d(2));
          final height = _d(_int(e['height'], 80));
          // CODE128-B: (data + start + checksum) * 11 modules + 13 stop modules.
          final w = ((value.length + 2) * 11 + 13) * narrow;
          final x = alignX(w, e['align'] == null ? PosAlign.center : align);
          cmd('^FO$x,$y^BY$narrow^BCN,$height,Y,N,N${_field(value)}^FS');
          y += height + _d(30);
        case 'qr':
          final value = '${e['value'] ?? ''}';
          final cell = math.max(1, _d(_int(e['size'], 6) * 0.8)).clamp(1, 10);
          final w = _qrModules(utf8.encode(value).length) * cell;
          final x = alignX(w, e['align'] == null ? PosAlign.center : align);
          // ^BQ prints a quiet zone of ~10 dots above the symbol.
          cmd('^FO$x,$y^BQN,2,$cell${_field('MA,$value')}^FS');
          y += w + _d(18);
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
    final heightDots = geometry.heightMm == null
        ? math.max(y + margin, (10 * geometry.dotsPerMm).round())
        : (geometry.heightMm! * geometry.dotsPerMm).round();

    final out = BytesBuilder(copy: false)
      ..add(ascii.encode('^XA\n^CI28\n^PW${geometry.dotsPerLine}\n^LL$heightDots\n^LH0,0\n'))
      ..add(body.toBytes())
      ..add(ascii.encode('^PQ1\n^XZ\n'));
    return out.toBytes();
  }

  /// `^FD` data; `^`, `~` and `_` would end or alter the field, so they are
  /// sent hex-escaped through `^FH`.
  static String _field(String v) {
    if (!v.contains(RegExp(r'[\^~_]'))) return '^FD$v';
    return '^FH^FD${v.replaceAll('_', '_5F').replaceAll('^', '_5E').replaceAll('~', '_7E')}';
  }

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
