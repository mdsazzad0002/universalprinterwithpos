import 'dart:typed_data';

import 'esc_pos_builder.dart';

/// 1-bit bitmap packed MSB-first, one row = [widthBytes] bytes, 1 = black dot.
/// This is exactly the layout ESC/POS `GS v 0` expects.
class MonoBitmap {
  MonoBitmap(this.width, this.height, this.data)
    : assert(data.length == ((width + 7) >> 3) * height);

  final int width;
  final int height;
  final Uint8List data;

  int get widthBytes => (width + 7) >> 3;

  /// Converts RGBA pixels to black/white. Transparent pixels count as paper
  /// (white). With [dither] Floyd-Steinberg error diffusion is used, which
  /// keeps photos readable; without it a plain threshold keeps text sharp.
  factory MonoBitmap.fromRgba(
    Uint8List rgba,
    int width,
    int height, {
    bool dither = false,
    int threshold = 128,
  }) {
    final gray = Float32List(width * height);
    for (var i = 0; i < width * height; i++) {
      final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
      final a = rgba[i * 4 + 3];
      final lum = 0.299 * r + 0.587 * g + 0.114 * b;
      // Composite over white paper.
      gray[i] = 255 - (a / 255) * (255 - lum);
    }

    final widthBytes = (width + 7) >> 3;
    final out = Uint8List(widthBytes * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final old = gray[i];
        final black = old < threshold;
        if (black) out[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7);
        if (!dither) continue;
        final err = old - (black ? 0 : 255);
        if (x + 1 < width) gray[i + 1] += err * 7 / 16;
        if (y + 1 < height) {
          if (x > 0) gray[i + width - 1] += err * 3 / 16;
          gray[i + width] += err * 5 / 16;
          if (x + 1 < width) gray[i + width + 1] += err * 1 / 16;
        }
      }
    }
    return MonoBitmap(width, height, out);
  }

  bool isBlack(int x, int y) =>
      data[y * widthBytes + (x >> 3)] & (0x80 >> (x & 7)) != 0;

  /// Places this bitmap on a canvas [totalWidth] dots wide. Printers do not
  /// reliably honour ESC a for raster images, so alignment is baked in here.
  MonoBitmap aligned(int totalWidth, PosAlign align) {
    if (width >= totalWidth) return this;
    final offset = switch (align) {
      PosAlign.left => 0,
      PosAlign.center => (totalWidth - width) ~/ 2,
      PosAlign.right => totalWidth - width,
    };
    final outWidthBytes = (totalWidth + 7) >> 3;
    final out = Uint8List(outWidthBytes * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!isBlack(x, y)) continue;
        final nx = x + offset;
        out[y * outWidthBytes + (nx >> 3)] |= 0x80 >> (nx & 7);
      }
    }
    return MonoBitmap(totalWidth, height, out);
  }
}
