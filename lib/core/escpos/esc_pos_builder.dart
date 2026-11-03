import 'dart:convert';
import 'dart:typed_data';

import 'mono_bitmap.dart';

enum PosAlign { left, center, right }

/// Printable area of a thermal roll at 203 dpi (8 dots/mm).
class PaperGeometry {
  const PaperGeometry(this.widthMm);

  final int widthMm;

  static const dpi = 203;
  static const minWidthMm = 40;
  static const maxWidthMm = 112;

  /// Standard rolls have fixed printable widths; others use ~90 % of the roll.
  static const _knownDots = {58: 384, 76: 512, 80: 576, 112: 832};

  int get dotsPerLine => _knownDots[widthMm] ?? ((widthMm * 7.2).floor() & ~7);

  /// Characters per line in Font A (12 dots wide).
  int get charsPerLine => dotsPerLine ~/ 12;

  double get printableWidthMm => dotsPerLine / 8;

  Map<String, Object> toJson() => {
    'width_mm': widthMm,
    'printable_width_mm': printableWidthMm,
    'dots_per_line': dotsPerLine,
    'chars_per_line': charsPerLine,
    'dpi': dpi,
  };
}

PosAlign parseAlign(Object? value) => switch (value) {
  'center' => PosAlign.center,
  'right' => PosAlign.right,
  _ => PosAlign.left,
};

/// Low level ESC/POS command builder.
///
/// Only ASCII is sent as text. Anything else (Bangla, symbols) must be
/// rasterised by the caller, because most cheap thermal printers have no
/// Unicode font.
class EscPosBuilder {
  EscPosBuilder({required this.paperWidthMm});

  final int paperWidthMm;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  int get dotsPerLine => PaperGeometry(paperWidthMm).dotsPerLine;

  int get charsPerLine => PaperGeometry(paperWidthMm).charsPerLine;

  /// Max rows per GS v 0 command; keeps cheap printers' buffers happy.
  static const rasterBandHeight = 256;

  void init() {
    _add([0x1B, 0x40]); // ESC @  reset
    _add([0x1B, 0x74, 0x00]); // ESC t 0  code page PC437
  }

  void align(PosAlign value) => _add([0x1B, 0x61, value.index]);

  void bold(bool on) => _add([0x1B, 0x45, on ? 1 : 0]);

  /// Character magnification, 1..8 in each direction.
  void textSize(int width, int height) {
    final w = width.clamp(1, 8) - 1;
    final h = height.clamp(1, 8) - 1;
    _add([0x1D, 0x21, (w << 4) | h]);
  }

  void text(String value) =>
      _add(value.codeUnits.map((c) => c >= 0x20 && c < 0x7F ? c : 0x3F));

  void line([String value = '']) {
    text(value);
    newline();
  }

  void newline() => _add([0x0A]);

  void feed(int lines) => _add([0x1B, 0x64, lines.clamp(0, 255)]);

  void separator({String char = '-'}) =>
      line((char.isEmpty ? '-' : char[0]) * charsPerLine);

  /// CODE128 barcode with human readable text below.
  void barcode128(String value, {int height = 80, int moduleWidth = 2}) {
    final data = ascii.encode('{B$value');
    if (data.length > 255) {
      throw const FormatException('Barcode value is too long');
    }
    _add([0x1D, 0x68, height.clamp(1, 255)]); // GS h
    _add([0x1D, 0x77, moduleWidth.clamp(2, 6)]); // GS w
    _add([0x1D, 0x48, 0x02]); // GS H  HRI below
    _add([0x1D, 0x6B, 0x49, data.length, ...data]); // GS k 73
    newline();
  }

  /// QR code (model 2) using the printer's native QR generator.
  void qr(String value, {int moduleSize = 6}) {
    final data = utf8.encode(value);
    final storeLen = data.length + 3;
    _add([0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]); // model 2
    _add([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, moduleSize.clamp(1, 16)]);
    _add([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31]); // error level M
    _add([0x1D, 0x28, 0x6B, storeLen & 0xFF, storeLen >> 8, 0x31, 0x50, 0x30]);
    _add(data);
    _add([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]); // print
    newline();
  }

  /// Prints a bitmap with GS v 0, split into bands.
  void raster(MonoBitmap bitmap) {
    final wb = bitmap.widthBytes;
    for (var y = 0; y < bitmap.height; y += rasterBandHeight) {
      final rows = (bitmap.height - y).clamp(0, rasterBandHeight);
      _add([0x1D, 0x76, 0x30, 0x00, wb & 0xFF, wb >> 8, rows & 0xFF, rows >> 8]);
      _bytes.add(
        Uint8List.sublistView(bitmap.data, y * wb, (y + rows) * wb),
      );
    }
  }

  /// Feeds to the cutter and cuts (GS V 66).
  void cut({bool partial = true}) => _add([0x1D, 0x56, partial ? 0x42 : 0x41, 0x00]);

  /// Kicks the cash drawer on pin 2 (ESC p).
  void openCashDrawer() => _add([0x1B, 0x70, 0x00, 0x19, 0xFA]);

  void raw(List<int> bytes) => _add(bytes);

  Uint8List build() => _bytes.toBytes();

  void _add(Iterable<int> bytes) => _bytes.add(bytes is List<int> ? bytes : bytes.toList());
}

/// Lays out a left/right pair on [width] characters. When both do not fit on
/// one line, the left text gets its own line(s) and the right is pushed to the
/// next line right-aligned.
List<String> formatRow(String left, String right, int width) {
  if (left.length + right.length + 1 <= width) {
    return [left + ' ' * (width - left.length - right.length) + right];
  }
  final lines = <String>[];
  for (var i = 0; i < left.length; i += width) {
    lines.add(left.substring(i, (i + width).clamp(0, left.length)));
  }
  if (right.isNotEmpty) lines.add(right.padLeft(width));
  return lines;
}

/// True when the text cannot be printed with the printer's built-in font.
bool needsRaster(String value) => value.codeUnits.any((c) => c > 0x7E);
