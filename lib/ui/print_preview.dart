import 'dart:convert';
import 'dart:math' as math;

import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../core/escpos/document_renderer.dart' hide Element;
import '../core/escpos/document_renderer.dart' as doc show Element;
import '../core/escpos/esc_pos_builder.dart';
import '../data/models/printer.dart';
import 'theme.dart';
import 'widgets.dart';

/// Shows a job the way the printer lays it out: same paper width in dots,
/// same line wrapping, label size and barcode / QR geometry as the ESC/POS,
/// TSPL and ZPL renderers. Printer fonts can differ slightly.
class PrintPreviewScreen extends StatelessWidget {
  const PrintPreviewScreen({
    super.key,
    required this.payload,
    this.payloadFor,
    this.printer,
    this.printerName,
    this.paperWidth,
    this.copies = 1,
    this.printLabel = 'Print',
    this.onPrint,
  });

  final Map<String, dynamic> payload;

  /// Rebuilds the payload when the printer's settings change (test pages
  /// print the paper size).
  final Map<String, dynamic> Function(Printer printer)? payloadFor;

  /// Null when the printer was deleted; the preview then uses [paperWidth].
  final Printer? printer;
  final String? printerName;
  final int? paperWidth;
  final int copies;
  final String printLabel;
  final Future<void> Function(BuildContext context, Printer? printer)? onPrint;

  PaperGeometry _geometry(Printer? printer, Map<String, dynamic> payload) {
    final paper = payload['paper'];
    final height = paper is Map && paper['height_mm'] is num ? (paper['height_mm'] as num).round() : null;
    return printer?.geometry(widthMm: paperWidth, heightMm: height) ?? PaperGeometry(paperWidth ?? 58);
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).printers;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final current = printer == null ? null : store.byId(printer!.id) ?? printer;
        return _build(context, current, current == null ? payload : payloadFor?.call(current) ?? payload);
      },
    );
  }

  Widget _build(BuildContext context, Printer? printer, Map<String, dynamic> payload) {
    final theme = Theme.of(context);
    final geometry = _geometry(printer, payload);
    final isPdf = printer?.isDocument == true || payload['document_type'] == 'pdf';

    Widget paper;
    var count = 0;
    if (isPdf) {
      final data = payload['data'];
      paper = EmptyState(
        icon: Icons.picture_as_pdf_outlined,
        title: 'A4 PDF document',
        message: data is String ? '${(data.length * 3 / 4 / 1024).ceil()} KB · printed as sent' : 'Printed as sent',
      );
    } else {
      try {
        final elements = payloadToElements(payload, geometry.charsPerLine);
        count = elements.length;
        paper = _Paper(
          elements: elements,
          geometry: geometry,
          protocol: printer?.protocol ?? PrinterProtocol.escpos,
          autoCut: printer?.autoCut ?? true,
        );
      } on FormatException catch (e) {
        paper = EmptyState(icon: Icons.error_outline, title: 'Cannot preview this job', message: e.message);
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Print preview')),
      body: PageListView(
        bottom: 32,
        children: [
          Card(
            child: ListTile(
              mouseCursor: SystemMouseCursors.basic,
              leading: IconBadge(printer == null ? Icons.print_disabled_outlined : connectionIcon(printer.connectionType)),
              title: Text(printer?.name ?? printerName ?? 'Printer'),
              subtitle: Text([
                if (printer != null) printer.paperLabel else '${geometry.widthMm} mm',
                if (count > 0) '$count element(s)',
                if (copies > 1) '$copies copies',
              ].join(' · ')),
            ),
          ),
          if (printer != null && printer.isLabel && printer.dpi == 300) ...[
            const SizedBox(height: 12),
            _DpiTip(printer: printer),
          ],
          const SizedBox(height: 20),
          Center(child: paper),
          const SizedBox(height: 12),
          if (!isPdf)
            Text(
              'Layout matches the printer; its built-in font may look slightly different.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
      bottomNavigationBar: onPrint == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await onPrint!(context, printer);
                  },
                  icon: const Icon(Icons.print_rounded),
                  label: Text(printLabel),
                ),
              ),
            ),
    );
  }
}

/// The preview is drawn at the configured dpi, so it cannot show the most
/// common label problem: a 203 dpi printer set to 300 dpi prints everything
/// 1.5× too big and cuts off the right side.
class _DpiTip extends StatelessWidget {
  const _DpiTip({required this.printer});

  final Printer printer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: warningColor.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: warningColor.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const IconBadge(Icons.straighten_rounded, size: 36, color: warningColor),
            const SizedBox(width: 12),
            Expanded(child: Text('Label prints bigger and cut off?', style: theme.textTheme.titleSmall)),
          ]),
          const SizedBox(height: 8),
          Text(
            'This printer is set to 300 dpi, and the preview is drawn for that. Most label printers are '
            '203 dpi: they print a 300 dpi label 1.5× larger, so the right side falls off the label.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () async {
              await AppScope.of(context).printers.save(printer.copyWith(dpi: 203));
              if (context.mounted) showMessage(context, '${printer.name} now uses 203 dpi');
            },
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Use 203 dpi'),
          ),
        ]),
      ),
    );
  }
}

const _black = Color(0xFF000000);
const _note = Color(0xFF64748B);

/// The paper, drawn in printer dots and scaled to fit the screen.
class _Paper extends StatelessWidget {
  const _Paper({required this.elements, required this.geometry, required this.protocol, required this.autoCut});

  final List<doc.Element> elements;
  final PaperGeometry geometry;
  final PrinterProtocol protocol;
  final bool autoCut;

  @override
  Widget build(BuildContext context) {
    final label = geometry.label;
    final dots = geometry.dotsPerLine;
    // The roll is wider than the printable area; a label is exactly its width.
    final paperWidth = label ? dots.toDouble() : math.max(geometry.widthMm * geometry.dotsPerMm, dots + 24.0);
    final content = label ? _labelContent() : _receiptContent();

    Widget sheet;
    if (label) {
      final scale = geometry.dpi / 203;
      final minHeight = 10 * geometry.dotsPerMm;
      final height = geometry.heightMm == null ? null : geometry.heightMm! * geometry.dotsPerMm;
      sheet = Container(
        width: paperWidth,
        height: height,
        constraints: BoxConstraints(minHeight: minHeight),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16 * scale),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        // Content past the label edge is not printed, so it is cut off here too.
        child: height == null ? content : OverflowBox(alignment: Alignment.topCenter, maxHeight: double.infinity, child: content),
      );
    } else {
      sheet = PhysicalShape(
        clipper: const _TornEdge(),
        color: Colors.white,
        elevation: 6,
        shadowColor: const Color(0x66000000),
        child: SizedBox(
          width: paperWidth,
          child: Padding(
            padding: const EdgeInsets.only(top: 24, bottom: 36),
            child: Center(child: SizedBox(width: dots.toDouble(), child: content)),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: MediaQuery.withNoTextScaling(
        child: DefaultTextStyle(
          style: const TextStyle(color: _black, fontSize: 24, height: 1.25),
          child: FittedBox(fit: BoxFit.fitWidth, alignment: Alignment.topCenter, child: sheet),
        ),
      ),
    );
  }

  /// Mirrors [DocumentRenderer]: ASCII in the printer's 12×24-dot font,
  /// everything else rasterised.
  Widget _receiptContent() {
    final dots = geometry.dotsPerLine;
    final chars = geometry.charsPerLine;
    final children = <Widget>[];
    var cut = false;

    for (final e in elements) {
      final bold = e['bold'] == true;
      final align = parseAlign(e['align']);
      switch (e['type']) {
        case 'text':
          final value = '${e['value'] ?? ''}';
          final size = _int(e['size'], 1).clamp(1, 4);
          children.add(SizedBox(
            width: dots.toDouble(),
            child: Text(
              value,
              textAlign: _textAlign(align),
              style: needsRaster(value) ? _raster(24.0 * size, bold) : _mono(size, bold),
            ),
          ));
        case 'row':
          final left = '${e['left'] ?? ''}';
          final right = '${e['right'] ?? ''}';
          if (needsRaster(left) || needsRaster(right)) {
            children.add(_rasterRow(left, right, 24, bold));
          } else {
            for (final line in formatRow(left, right, chars)) {
              children.add(Text(line, style: _mono(1, bold), softWrap: false));
            }
          }
        case 'line':
          final char = '${e['char'] ?? '-'}';
          children.add(Text((char.isEmpty ? '-' : char[0]) * chars, style: _mono(1, false), softWrap: false));
        case 'feed':
          children.add(SizedBox(height: 30.0 * _int(e['lines'], 1)));
        case 'barcode':
          final value = '${e['value'] ?? ''}';
          children.add(Center(
            child: Column(children: [
              _Barcode1D(value, narrow: 2, height: _int(e['height'], 80).toDouble()),
              Text(value, style: _mono(1, false)),
            ]),
          ));
        case 'qr':
          children.add(Center(child: _QrCode('${e['value'] ?? ''}', cell: _int(e['size'], 6).toDouble())));
        case 'image':
          children.add(_image(e, dots));
        case 'cut':
          children.add(const _CutLine());
          cut = true;
        case 'cash_drawer':
          children.add(const _Note(icon: Icons.point_of_sale_rounded, text: 'Cash drawer opens'));
        case 'raw':
          children.add(_rawNote(e));
      }
    }

    final noPaper = elements.isNotEmpty && elements.every((e) => e['type'] == 'raw' || e['type'] == 'cash_drawer');
    if (autoCut && !cut && !noPaper) {
      children
        ..add(const SizedBox(height: 90))
        ..add(const _CutLine());
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  /// Mirrors [TsplRenderer] / [ZplRenderer]: everything rasterised, sizes
  /// scaled from 203 dpi.
  Widget _labelContent() {
    final scale = geometry.dpi / 203;
    int d(num v) => (v * scale).round();
    final margin = d(8).toDouble();
    final width = (geometry.dotsPerLine - 2 * margin.round()) & ~7;
    final zpl = protocol == PrinterProtocol.zpl;
    final children = <Widget>[];

    Widget aligned(Widget child, Object? align) => Align(
      alignment: switch (align == null ? PosAlign.center : parseAlign(align)) {
        PosAlign.left => Alignment.centerLeft,
        PosAlign.center => Alignment.center,
        PosAlign.right => Alignment.centerRight,
      },
      child: child,
    );

    for (final e in elements) {
      final bold = e['bold'] == true;
      switch (e['type']) {
        case 'text':
          final size = _int(e['size'], 1).clamp(1, 4);
          children.add(SizedBox(
            width: width.toDouble(),
            child: Text(
              '${e['value'] ?? ''}',
              textAlign: _textAlign(parseAlign(e['align'])),
              style: _raster(24 * scale * size, bold),
            ),
          ));
        case 'row':
          children.add(_rasterRow('${e['left'] ?? ''}', '${e['right'] ?? ''}', 24 * scale, bold, width: width));
        case 'line':
          children.add(Padding(
            padding: EdgeInsets.only(top: d(6).toDouble(), bottom: math.max(0, d(8) - math.max(2, d(2))).toDouble()),
            child: Container(height: math.max(2, d(2)).toDouble(), color: _black),
          ));
        case 'feed':
          children.add(SizedBox(height: d(30) * _int(e['lines'], 1).toDouble()));
        case 'barcode':
          final value = '${e['value'] ?? ''}';
          final height = d(_int(e['height'], 80)).toDouble();
          children.add(SizedBox(
            height: height + d(30),
            child: aligned(
              Column(mainAxisSize: MainAxisSize.min, children: [
                _Barcode1D(value, narrow: math.max(2, d(2)).toDouble(), height: height),
                Text(value, style: _mono(1, false).copyWith(fontSize: 18 * scale, height: 1.2)),
              ]),
              e['align'],
            ),
          ));
        case 'qr':
          var cell = math.max(1, d(_int(e['size'], 6) * 0.8));
          if (zpl) cell = cell.clamp(1, 10);
          children.add(aligned(_QrCode('${e['value'] ?? ''}', cell: cell.toDouble()), e['align']));
          children.add(SizedBox(height: d(zpl ? 18 : 8).toDouble()));
        case 'image':
          children.add(_image(e, width));
        case 'raw':
          children.add(_rawNote(e));
      }
    }
    return Padding(
      padding: EdgeInsets.all(margin),
      child: SizedBox(
        width: width.toDouble(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  static Widget _rasterRow(String left, String right, double fontSize, bool bold, {int? width}) => SizedBox(
    width: width?.toDouble(),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Text(left, style: _raster(fontSize, bold))),
      SizedBox(width: fontSize / 2),
      Text(right, style: _raster(fontSize, bold), textAlign: TextAlign.right),
    ]),
  );

  static Widget _image(doc.Element e, int maxWidth) {
    try {
      final data = base64.decode('${e['base64'] ?? ''}'.replaceFirst(RegExp(r'^data:[^,]*,'), ''));
      final width = _int(e['width'], maxWidth).clamp(8, maxWidth).toDouble();
      return Align(
        alignment: switch (e['align'] == null ? PosAlign.center : parseAlign(e['align'])) {
          PosAlign.left => Alignment.centerLeft,
          PosAlign.center => Alignment.center,
          PosAlign.right => Alignment.centerRight,
        },
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.3, 0.59, 0.11, 0, 0, //
            0.3, 0.59, 0.11, 0, 0,
            0.3, 0.59, 0.11, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: Image.memory(data, width: width, fit: BoxFit.scaleDown),
        ),
      );
    } catch (_) {
      return const _Note(icon: Icons.broken_image_outlined, text: 'Image cannot be decoded');
    }
  }

  static Widget _rawNote(doc.Element e) {
    final data = '${e['base64'] ?? ''}';
    return _Note(icon: Icons.memory_rounded, text: 'Raw printer data · ${(data.length * 3 / 4).floor()} bytes · not shown');
  }

  static TextAlign _textAlign(PosAlign a) => switch (a) {
    PosAlign.left => TextAlign.left,
    PosAlign.center => TextAlign.center,
    PosAlign.right => TextAlign.right,
  };

  /// Printer font A: 12×24 dots per character, ~30 dots line spacing.
  static TextStyle _mono(int size, bool bold) => TextStyle(
    color: _black,
    fontFamily: 'monospace',
    fontFamilyFallback: const ['DejaVu Sans Mono', 'Consolas', 'Courier New'],
    fontSize: 20.0 * size,
    height: 1.5,
    fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
  );

  /// Same style as [FlutterRasterizer].
  static TextStyle _raster(double fontSize, bool bold) => TextStyle(
    color: _black,
    fontSize: fontSize,
    height: 1.25,
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
  );
}

int _int(Object? v, int fallback) => switch (v) {
  num n => n.toInt(),
  String s => int.tryParse(s) ?? fallback,
  _ => fallback,
};

/// CODE128-B, the set the printers are sent.
class _Barcode1D extends StatelessWidget {
  const _Barcode1D(this.value, {required this.narrow, required this.height});

  final String value;
  final double narrow;
  final double height;

  @override
  Widget build(BuildContext context) {
    final width = ((value.length + 2) * 11 + 13) * narrow;
    try {
      final bars = Barcode.code128(useCode128A: false, useCode128C: false)
          .make(value, width: width, height: height)
          .whereType<BarcodeBar>()
          .where((b) => b.black)
          .toList();
      return CustomPaint(size: Size(width, height), painter: _BarsPainter(bars));
    } catch (_) {
      return _Note(icon: Icons.qr_code_2, text: 'Invalid barcode "$value"');
    }
  }
}

class _QrCode extends StatelessWidget {
  const _QrCode(this.value, {required this.cell});

  final String value;
  final double cell;

  @override
  Widget build(BuildContext context) {
    try {
      final qr = Barcode.qrCode(errorCorrectLevel: BarcodeQRCorrectionLevel.medium);
      // Draw once at unit size to learn the module count.
      final unit = qr.make(value, width: 1, height: 1).whereType<BarcodeBar>().where((b) => b.black);
      final modules = (1 / unit.map((b) => b.width).reduce(math.min)).round();
      final side = modules * cell;
      final bars = qr.make(value, width: side, height: side).whereType<BarcodeBar>().where((b) => b.black).toList();
      return CustomPaint(size: Size.square(side), painter: _BarsPainter(bars));
    } catch (_) {
      return const _Note(icon: Icons.qr_code_2, text: 'QR code too long');
    }
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.bars);

  final List<BarcodeBar> bars;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _black
      ..isAntiAlias = false;
    for (final b in bars) {
      // Slight overlap hides hairline seams between adjacent modules.
      canvas.drawRect(Rect.fromLTWH(b.left, b.top, b.width + 0.3, b.height + 0.3), paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.bars != bars;
}

class _CutLine extends StatelessWidget {
  const _CutLine();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(children: [
      const Icon(Icons.content_cut_rounded, color: _note, size: 26),
      const SizedBox(width: 8),
      Expanded(
        child: LayoutBuilder(
          builder: (context, c) => Row(children: [
            for (var i = 0; i < c.maxWidth ~/ 16; i++)
              Container(width: 10, height: 2, margin: const EdgeInsets.only(right: 6), color: _note),
          ]),
        ),
      ),
    ]),
  );
}

/// Something that happens at the printer but is not printed.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      border: Border.all(color: _note, width: 2),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: _note, size: 26),
      const SizedBox(width: 10),
      Flexible(child: Text(text, style: const TextStyle(color: _note, fontSize: 20, fontWeight: FontWeight.w600))),
    ]),
  );
}

/// Receipt paper with a torn zig-zag bottom edge.
class _TornEdge extends CustomClipper<Path> {
  const _TornEdge();

  @override
  Path getClip(Size size) {
    const tooth = 14.0;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height - tooth);
    var x = size.width;
    var down = true;
    while (x > 0) {
      x = math.max(0, x - tooth);
      path.lineTo(x, down ? size.height : size.height - tooth);
      down = !down;
    }
    return path..close();
  }

  @override
  bool shouldReclip(_TornEdge oldClipper) => false;
}
