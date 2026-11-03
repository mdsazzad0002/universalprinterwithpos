import 'dart:io' show ZLibCodec;
import 'dart:math' as math;
import 'dart:typed_data';

import '../escpos/mono_bitmap.dart';

/// One printed page as 8-bit gray, 0 = black, 255 = paper.
class GrayPage {
  GrayPage(this.width, this.height, this.pixels) : assert(pixels.length == width * height);

  final int width;
  final int height;
  final Uint8List pixels;

  /// RGBA (straight alpha) composited over white paper.
  factory GrayPage.fromRgba(Uint8List rgba, int width, int height) {
    final out = Uint8List(width * height);
    for (var i = 0; i < out.length; i++) {
      final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2], a = rgba[i * 4 + 3];
      final lum = (299 * r + 587 * g + 114 * b) ~/ 1000;
      out[i] = 255 - (a * (255 - lum)) ~/ 255;
    }
    return GrayPage(width, height, out);
  }

  /// Scaled (keeping the aspect ratio) to [targetWidth] pixels.
  GrayPage scaledToWidth(int targetWidth) {
    if (targetWidth == width) return this;
    final s = PageScaler(width, height, targetWidth);
    for (var y = 0; y < height; y++) {
      s.addLine(Uint8List.sublistView(pixels, y * width, (y + 1) * width));
    }
    return s.finish();
  }

  /// Black/white for a thermal head. Text and line art are thresholded so
  /// they stay sharp; pages with photos or gray fills are dithered.
  MonoBitmap toMono({bool? dither}) {
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < pixels.length; i++) {
      final v = pixels[i];
      rgba[i * 4] = v;
      rgba[i * 4 + 1] = v;
      rgba[i * 4 + 2] = v;
      rgba[i * 4 + 3] = 255;
    }
    final useDither = dither ?? hasPhotoContent;
    return MonoBitmap.fromRgba(rgba, width, height, dither: useDither, threshold: useDither ? 128 : 170);
  }

  /// True when the page has areas of gray (photos, shaded boxes) rather than
  /// only anti-aliased edges of text: runs of 6+ mid-tone pixels covering
  /// more than 1 % of the page.
  bool get hasPhotoContent {
    var inRuns = 0;
    for (var y = 0; y < height; y++) {
      var run = 0;
      final row = y * width;
      for (var x = 0; x <= width; x++) {
        final v = x < width ? pixels[row + x] : 255;
        if (v > 40 && v < 215) {
          run++;
        } else {
          if (run >= 6) inRuns += run;
          run = 0;
        }
      }
    }
    return inRuns > pixels.length / 100;
  }
}

/// Streams source lines in and resamples them to a fixed width, keeping the
/// aspect ratio: box filter when shrinking, nearest neighbour when growing.
/// A 300 dpi A4 page never has to be held in memory at full size.
class PageScaler {
  PageScaler(this.srcWidth, this.srcHeight, this.dstWidth)
    : _s = dstWidth / srcWidth,
      dstHeight = math.max(1, (srcHeight * dstWidth / srcWidth).round()) {
    _out = Uint8List(dstWidth * dstHeight)..fillRange(0, dstWidth * dstHeight, 255);
    _x0 = Int32List(dstWidth);
    _x1 = Int32List(dstWidth);
    for (var tx = 0; tx < dstWidth; tx++) {
      final a = math.min((tx / _s).floor(), srcWidth - 1);
      final b = math.min(math.max((tx + 1) / _s, a + 1.0).floor(), srcWidth);
      _x0[tx] = a;
      _x1[tx] = math.max(b, a + 1);
    }
    _acc = Int32List(dstWidth);
    _row = Int32List(dstWidth);
  }

  final int srcWidth;
  final int srcHeight;
  final int dstWidth;
  final int dstHeight;
  final double _s;
  late final Uint8List _out;
  late final Int32List _x0, _x1, _acc, _row;
  Int32List? _last;
  int _y = 0;
  int _ty = 0;
  int _count = 0;

  int _rowEnd(int ty) {
    final a = (ty / _s).floor();
    return math.max(((ty + 1) / _s).floor(), a + 1);
  }

  int _rowStart(int ty) => (ty / _s).floor();

  /// [line] holds [srcWidth] gray values.
  void addLine(Uint8List line) {
    if (_y >= srcHeight) return;
    for (var tx = 0; tx < dstWidth; tx++) {
      var sum = 0;
      final a = _x0[tx], b = _x1[tx];
      for (var x = a; x < b; x++) {
        sum += line[x];
      }
      _row[tx] = sum ~/ (b - a);
    }
    while (_ty < dstHeight && _rowEnd(_ty) <= _y) {
      _emit();
    }
    if (_ty < dstHeight && _rowStart(_ty) <= _y) {
      for (var tx = 0; tx < dstWidth; tx++) {
        _acc[tx] += _row[tx];
      }
      _count++;
    }
    (_last ??= Int32List(dstWidth)).setAll(0, _row);
    _y++;
  }

  void _emit() {
    final o = _ty * dstWidth;
    if (_count > 0) {
      for (var tx = 0; tx < dstWidth; tx++) {
        _out[o + tx] = _acc[tx] ~/ _count;
        _acc[tx] = 0;
      }
    } else if (_last != null) {
      for (var tx = 0; tx < dstWidth; tx++) {
        _out[o + tx] = _last![tx];
      }
    }
    _count = 0;
    _ty++;
  }

  GrayPage finish() {
    while (_ty < dstHeight) {
      _emit();
    }
    return GrayPage(dstWidth, dstHeight, _out);
  }
}

/// A raster document a client could not be understood.
class RasterFormatException implements Exception {
  RasterFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Decodes the two raster formats driverless clients send:
///
/// * PWG Raster (`image/pwg-raster`, "RaS2"): Windows IPP Class Driver,
///   Linux CUPS `everywhere` queues, Android Default Print Service.
/// * Apple Raster (`image/urf`, "UNIRAST"): macOS and iOS AirPrint.
///
/// Every page is scaled to [targetWidth] dots on the fly.
class RasterDecoder {
  static const _pwgHeaderSize = 1796;
  static const _urfHeaderSize = 32;

  static bool isPwg(Uint8List d) => d.length >= 4 && d[0] == 0x52 && d[1] == 0x61 && d[2] == 0x53 && d[3] == 0x32;

  static bool isUrf(Uint8List d) =>
      d.length >= 8 && String.fromCharCodes(d.sublist(0, 7)) == 'UNIRAST' && d[7] == 0;

  static bool isPdf(Uint8List d) => d.length >= 4 && d[0] == 0x25 && d[1] == 0x50 && d[2] == 0x44 && d[3] == 0x46;

  static List<GrayPage> decode(Uint8List data, {required int targetWidth}) {
    if (isPwg(data)) return _decodePwg(data, targetWidth);
    if (isUrf(data)) return _decodeUrf(data, targetWidth);
    throw RasterFormatException('Not a PWG or Apple raster document');
  }

  static List<GrayPage> _decodePwg(Uint8List data, int targetWidth) {
    final view = ByteData.sublistView(data);
    final pages = <GrayPage>[];
    var p = 4;
    while (p + _pwgHeaderSize <= data.length) {
      final h = p;
      final width = view.getUint32(h + 372);
      final height = view.getUint32(h + 376);
      final bpc = view.getUint32(h + 384);
      final bpp = view.getUint32(h + 388);
      final bytesPerLine = view.getUint32(h + 392);
      final colorOrder = view.getUint32(h + 396);
      final colorSpace = view.getUint32(h + 400);
      p += _pwgHeaderSize;
      if (width == 0 || height == 0) throw RasterFormatException('Empty raster page');
      if (colorOrder != 0) throw RasterFormatException('Only chunky PWG raster is supported');
      final format = _PixelFormat.pwg(colorSpace, bpp, bpc);
      p = _decodePage(data, p, width, height, bytesPerLine, format, targetWidth, pages);
    }
    if (pages.isEmpty) throw RasterFormatException('PWG raster has no pages');
    return pages;
  }

  static List<GrayPage> _decodeUrf(Uint8List data, int targetWidth) {
    if (data.length < 12) throw RasterFormatException('Apple raster is truncated');
    final view = ByteData.sublistView(data);
    final pages = <GrayPage>[];
    var p = 12; // "UNIRAST\0" + page count
    while (p + _urfHeaderSize <= data.length) {
      final bpp = data[p];
      final colorSpace = data[p + 1];
      final width = view.getUint32(p + 12);
      final height = view.getUint32(p + 16);
      p += _urfHeaderSize;
      if (width == 0 || height == 0) throw RasterFormatException('Empty raster page');
      final format = _PixelFormat.urf(colorSpace, bpp);
      p = _decodePage(data, p, width, height, (width * bpp + 7) ~/ 8, format, targetWidth, pages);
    }
    if (pages.isEmpty) throw RasterFormatException('Apple raster has no pages');
    return pages;
  }

  /// PackBits variant shared by PWG and Apple raster: a line-repeat byte,
  /// then runs of pixels (n < 128: next pixel n+1 times, n > 128: 257-n
  /// literal pixels, 128: rest of the line is blank).
  static int _decodePage(
    Uint8List data,
    int p,
    int width,
    int height,
    int bytesPerLine,
    _PixelFormat format,
    int targetWidth,
    List<GrayPage> pages,
  ) {
    final unit = math.max(1, format.bpp ~/ 8);
    if (bytesPerLine < (width * format.bpp + 7) ~/ 8) throw RasterFormatException('Bad raster line size');
    final scaler = PageScaler(width, height, targetWidth);
    final line = Uint8List(bytesPerLine);
    final gray = Uint8List(width);
    var y = 0;
    while (y < height) {
      if (p >= data.length) throw RasterFormatException('Raster page is truncated');
      final repeat = data[p++] + 1;
      var x = 0;
      while (x < bytesPerLine) {
        if (p >= data.length) throw RasterFormatException('Raster page is truncated');
        final n = data[p++];
        if (n == 128) {
          line.fillRange(x, bytesPerLine, format.blank);
          x = bytesPerLine;
        } else if (n < 128) {
          final count = (n + 1) * unit;
          if (p + unit > data.length) throw RasterFormatException('Raster page is truncated');
          for (var i = 0; i < count && x < bytesPerLine; i++) {
            line[x++] = data[p + i % unit];
          }
          p += unit;
        } else {
          final count = (257 - n) * unit;
          if (p + count > data.length) throw RasterFormatException('Raster page is truncated');
          final take = math.min(count, bytesPerLine - x);
          line.setRange(x, x + take, data, p);
          x += take;
          p += count;
        }
      }
      format.toGray(line, width, gray);
      for (var r = 0; r < repeat && y < height; r++, y++) {
        scaler.addLine(gray);
      }
    }
    pages.add(scaler.finish());
    return p;
  }
}

class _PixelFormat {
  _PixelFormat(this.bpp, this.kind);

  /// CUPS color spaces: 0 W, 1 RGB, 3 K, 6 CMYK, 18 sGray, 19 sRGB, 20 AdobeRGB.
  factory _PixelFormat.pwg(int colorSpace, int bpp, int bpc) {
    final kind = switch (colorSpace) {
      0 || 18 => _Kind.gray,
      3 => _Kind.black,
      1 || 19 || 20 => _Kind.rgb,
      6 => _Kind.cmyk,
      _ => throw RasterFormatException('Unsupported raster color space $colorSpace'),
    };
    return _PixelFormat._checked(bpp, kind);
  }

  /// Apple raster color spaces: 0 sGray, 1 sRGB, 3 AdobeRGB, 4 W, 5 RGB, 6 CMYK.
  factory _PixelFormat.urf(int colorSpace, int bpp) {
    final kind = switch (colorSpace) {
      0 || 4 => _Kind.gray,
      1 || 3 || 5 => _Kind.rgb,
      6 => _Kind.cmyk,
      _ => throw RasterFormatException('Unsupported Apple raster color space $colorSpace'),
    };
    return _PixelFormat._checked(bpp, kind);
  }

  factory _PixelFormat._checked(int bpp, _Kind kind) {
    final ok = switch (kind) {
      _Kind.gray || _Kind.black => bpp == 1 || bpp == 8 || bpp == 16,
      _Kind.rgb => bpp == 24 || bpp == 48,
      _Kind.cmyk => bpp == 32 || bpp == 64,
    };
    if (!ok) throw RasterFormatException('Unsupported raster depth: $bpp bits per pixel');
    return _PixelFormat(bpp, kind);
  }

  final int bpp;
  final _Kind kind;

  /// Byte value of blank paper.
  int get blank => kind == _Kind.black || kind == _Kind.cmyk ? 0x00 : 0xFF;

  void toGray(Uint8List line, int width, Uint8List out) {
    switch (kind) {
      case _Kind.gray || _Kind.black:
        final ink = kind == _Kind.black;
        if (bpp == 1) {
          for (var x = 0; x < width; x++) {
            final bit = line[x >> 3] & (0x80 >> (x & 7)) != 0;
            out[x] = bit == ink ? 0 : 255;
          }
        } else {
          final step = bpp ~/ 8; // 16-bit: high byte first
          for (var x = 0; x < width; x++) {
            final v = line[x * step];
            out[x] = ink ? 255 - v : v;
          }
        }
      case _Kind.rgb:
        final step = bpp ~/ 8, c = step ~/ 3;
        for (var x = 0; x < width; x++) {
          final o = x * step;
          out[x] = (299 * line[o] + 587 * line[o + c] + 114 * line[o + 2 * c]) ~/ 1000;
        }
      case _Kind.cmyk:
        final step = bpp ~/ 8, c = step ~/ 4;
        for (var x = 0; x < width; x++) {
          final o = x * step;
          final k = 255 - line[o + 3 * c];
          final r = (255 - line[o]) * k ~/ 255, g = (255 - line[o + c]) * k ~/ 255, b = (255 - line[o + 2 * c]) * k ~/ 255;
          out[x] = (299 * r + 587 * g + 114 * b) ~/ 1000;
        }
    }
  }
}

enum _Kind { gray, black, rgb, cmyk }

/// [bitmap] without blank rows at the bottom, keeping [keep] rows of paper
/// below the last printed dot. Never returns an empty bitmap.
MonoBitmap trimBottom(MonoBitmap bitmap, {int keep = 8}) {
  final wb = bitmap.widthBytes;
  var last = -1;
  for (var y = bitmap.height - 1; y >= 0 && last < 0; y--) {
    for (var i = y * wb; i < (y + 1) * wb; i++) {
      if (bitmap.data[i] != 0) {
        last = y;
        break;
      }
    }
  }
  final height = math.min(bitmap.height, math.max(1, last + 1 + keep));
  if (height == bitmap.height) return bitmap;
  return MonoBitmap(bitmap.width, height, Uint8List.fromList(bitmap.data.sublist(0, wb * height)));
}

/// 1-bit grayscale PNG of [bitmap], small enough to keep in a print job.
Uint8List encodeMonoPng(MonoBitmap bitmap) {
  final wb = bitmap.widthBytes;
  final raw = Uint8List((wb + 1) * bitmap.height);
  for (var y = 0; y < bitmap.height; y++) {
    final o = y * (wb + 1);
    raw[o] = 0; // filter: none
    for (var i = 0; i < wb; i++) {
      // PNG gray: 1 = white; MonoBitmap: 1 = black.
      raw[o + 1 + i] = ~bitmap.data[y * wb + i] & 0xFF;
    }
  }
  final out = BytesBuilder(copy: false)..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> body) {
    final t = type.codeUnits;
    final len = ByteData(4)..setUint32(0, body.length);
    out.add(len.buffer.asUint8List());
    final crcInput = Uint8List(4 + body.length)
      ..setAll(0, t)
      ..setAll(4, body);
    out.add(crcInput);
    final crc = ByteData(4)..setUint32(0, _crc32(crcInput));
    out.add(crc.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, bitmap.width)
    ..setUint32(4, bitmap.height)
    ..setUint8(8, 1) // bit depth
    ..setUint8(9, 0); // grayscale; compression, filter, interlace = 0
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', ZLibCodec(level: 6).encode(raw));
  chunk('IEND', const []);
  return out.toBytes();
}

final _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
