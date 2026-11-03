import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'esc_pos_builder.dart';
import 'mono_bitmap.dart';

/// Turns text and images into printer bitmaps. Kept behind an interface so
/// the renderer can be tested without a Flutter engine.
abstract class Rasterizer {
  Future<MonoBitmap> renderText(
    String text, {
    required int width,
    double fontSize = 24,
    bool bold = false,
    PosAlign align = PosAlign.left,
  });

  Future<MonoBitmap> renderRow(
    String left,
    String right, {
    required int width,
    double fontSize = 24,
    bool bold = false,
  });

  /// Decodes a PNG/JPEG and scales it down to at most [maxWidth] dots.
  Future<MonoBitmap> decodeImage(Uint8List encoded, {required int maxWidth});
}

/// Uses Flutter's text engine, so any font installed on the device works,
/// including Android's bundled Noto Sans Bengali.
class FlutterRasterizer implements Rasterizer {
  const FlutterRasterizer();

  static const _black = Color(0xFF000000);

  @override
  Future<MonoBitmap> renderText(
    String text, {
    required int width,
    double fontSize = 24,
    bool bold = false,
    PosAlign align = PosAlign.left,
  }) async {
    final painter = _painter(text, fontSize, bold, switch (align) {
      PosAlign.left => TextAlign.left,
      PosAlign.center => TextAlign.center,
      PosAlign.right => TextAlign.right,
    })..layout(minWidth: width.toDouble(), maxWidth: width.toDouble());
    try {
      return await _draw(width, painter.height.ceil(), (canvas) {
        painter.paint(canvas, Offset.zero);
      });
    } finally {
      painter.dispose();
    }
  }

  @override
  Future<MonoBitmap> renderRow(
    String left,
    String right, {
    required int width,
    double fontSize = 24,
    bool bold = false,
  }) async {
    final rightPainter = _painter(right, fontSize, bold, TextAlign.right)
      ..layout(maxWidth: width.toDouble());
    final leftWidth = math.max(width - rightPainter.width - fontSize / 2, width / 3);
    final leftPainter = _painter(left, fontSize, bold, TextAlign.left)
      ..layout(maxWidth: leftWidth);
    try {
      final height = math.max(leftPainter.height, rightPainter.height).ceil();
      return await _draw(width, height, (canvas) {
        leftPainter.paint(canvas, Offset.zero);
        rightPainter.paint(canvas, Offset(width - rightPainter.width, 0));
      });
    } finally {
      leftPainter.dispose();
      rightPainter.dispose();
    }
  }

  @override
  Future<MonoBitmap> decodeImage(Uint8List encoded, {required int maxWidth}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final targetWidth = math.min(descriptor.width, maxWidth);
    final codec = await descriptor.instantiateCodec(targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    try {
      return await _toMono(frame.image, dither: true);
    } finally {
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  TextPainter _painter(String text, double fontSize, bool bold, TextAlign align) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: _black,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          height: 1.25,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    );
  }

  Future<MonoBitmap> _draw(int width, int height, void Function(Canvas) paint) async {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder));
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, math.max(height, 1));
    picture.dispose();
    try {
      return await _toMono(image);
    } finally {
      image.dispose();
    }
  }

  Future<MonoBitmap> _toMono(ui.Image image, {bool dither = false}) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return MonoBitmap.fromRgba(
      bytes!.buffer.asUint8List(),
      image.width,
      image.height,
      dither: dither,
    );
  }
}
