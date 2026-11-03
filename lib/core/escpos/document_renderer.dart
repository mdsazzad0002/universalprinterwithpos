import 'dart:convert';
import 'dart:typed_data';

import 'esc_pos_builder.dart';
import 'rasterizer.dart';

typedef Element = Map<String, dynamic>;

const supportedDocumentTypes = {'receipt', 'elements', 'text', 'raw'};

/// Converts a print request payload into a flat list of elements.
///
/// Supported `document_type` values:
/// * `receipt`  – structured invoice in `content` (see [receiptToElements])
/// * `elements` – explicit element list in `elements` (or `content`)
/// * `text`     – plain text in `content`
/// * `raw`      – base64 printer bytes in `data`, sent untouched
///
/// Throws [FormatException] for invalid input, so it doubles as validation
/// when a job is submitted.
List<Element> payloadToElements(Map<String, dynamic> payload, int charsPerLine) {
  final type = (payload['document_type'] ?? 'receipt').toString();
  final content = payload['content'];
  switch (type) {
    case 'receipt':
      if (content is! Map) {
        throw const FormatException('"content" must be an object for receipt');
      }
      return receiptToElements(Map<String, dynamic>.from(content), charsPerLine);
    case 'elements':
      final list = payload['elements'] ?? content;
      if (list is! List) {
        throw const FormatException('"elements" must be an array');
      }
      final elements = <Element>[];
      for (var i = 0; i < list.length; i++) {
        final e = list[i];
        if (e is! Map || e['type'] is! String) {
          throw FormatException('Element $i must be an object with a "type"');
        }
        elements.add(Map<String, dynamic>.from(e));
      }
      return elements;
    case 'text':
      if (content is! String) {
        throw const FormatException('"content" must be a string for text');
      }
      return [for (final l in content.split('\n')) {'type': 'text', 'value': l}];
    case 'raw':
      if (payload['data'] is! String || (payload['data'] as String).isEmpty) {
        throw const FormatException('"data" must be a base64 string for raw');
      }
      return [
        {'type': 'raw', 'base64': payload['data']},
      ];
    default:
      throw FormatException(
        'Unsupported document_type "$type". Use one of: ${supportedDocumentTypes.join(', ')}',
      );
  }
}

/// Template for the common invoice layout. Every field is optional except
/// at least one of `items` / `total`.
///
/// ```json
/// {
///   "store_name": "My Shop", "header": ["Dhaka", "01700000000"],
///   "title": "INVOICE", "invoice_no": "INV-1001", "date": "2026-11-03 10:20",
///   "customer": "Rahim",
///   "items": [{"name": "Product A", "qty": 2, "price": 100}],
///   "subtotal": 200, "discount": 0, "vat": 0, "total": 200,
///   "paid": 500, "change": 300,
///   "footer": ["Thank you"], "qr": "https://...", "barcode": "INV-1001"
/// }
/// ```
List<Element> receiptToElements(Map<String, dynamic> c, int charsPerLine) {
  if (c['items'] == null && c['total'] == null) {
    throw const FormatException('Receipt needs "items" or "total"');
  }
  final out = <Element>[];
  void text(Object v, {String align = 'left', bool bold = false, int size = 1}) =>
      out.add({'type': 'text', 'value': '$v', 'align': align, 'bold': bold, 'size': size});
  void row(String l, Object? r, {bool bold = false}) =>
      out.add({'type': 'row', 'left': l, 'right': '${r ?? ''}', 'bold': bold});
  void sep() => out.add({'type': 'line'});

  if (c['store_name'] != null) text(c['store_name'], align: 'center', bold: true, size: 2);
  for (final l in _lines(c['header'])) {
    text(l, align: 'center');
  }
  if (c['title'] != null) text(c['title'], align: 'center', bold: true);
  sep();

  if (c['invoice_no'] != null) row('Invoice', c['invoice_no']);
  if (c['date'] != null) row('Date', c['date']);
  if (c['customer'] != null) row('Customer', c['customer']);
  for (final info in _list(c['info'])) {
    row('${info['label'] ?? ''}', info['value']);
  }

  final items = _list(c['items']);
  if (items.isNotEmpty) {
    sep();
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final qty = _num(item['qty'], 'items[$i].qty', fallback: 1);
      final price = _num(item['price'], 'items[$i].price', fallback: 0);
      final total = _num(item['total'], 'items[$i].total', fallback: qty * price);
      text(item['name'] ?? 'Item ${i + 1}');
      row('  ${_qty(qty)} x ${_money(price)}', _money(total));
    }
  }
  sep();

  const summary = [
    ('subtotal', 'Subtotal'),
    ('discount', 'Discount'),
    ('vat', 'VAT'),
    ('tax', 'Tax'),
    ('service_charge', 'Service Charge'),
  ];
  for (final (key, label) in summary) {
    if (c[key] != null) row(label, _money(_num(c[key], key)));
  }
  if (c['total'] != null) row('TOTAL', _money(_num(c['total'], 'total')), bold: true);
  if (c['paid'] != null) row('Paid', _money(_num(c['paid'], 'paid')));
  if (c['change'] != null) row('Change', _money(_num(c['change'], 'change')));

  final footer = _lines(c['footer']);
  if (footer.isNotEmpty) {
    sep();
    for (final l in footer) {
      text(l, align: 'center');
    }
  }
  if (c['barcode'] != null) out.add({'type': 'barcode', 'value': '${c['barcode']}'});
  if (c['qr'] != null) out.add({'type': 'qr', 'value': '${c['qr']}'});
  return out;
}

/// Renders elements to ESC/POS bytes for one copy.
class DocumentRenderer {
  DocumentRenderer({
    required this.paperWidthMm,
    required this.rasterizer,
    this.autoCut = true,
  });

  final int paperWidthMm;
  final Rasterizer rasterizer;
  final bool autoCut;

  static const _baseFontSize = 24.0;

  Future<Uint8List> render(List<Element> elements) async {
    final b = EscPosBuilder(paperWidthMm: paperWidthMm)..init();
    final dots = b.dotsPerLine;
    var cut = false;

    for (var i = 0; i < elements.length; i++) {
      final e = elements[i];
      final bold = e['bold'] == true;
      final align = parseAlign(e['align']);
      switch (e['type']) {
        case 'text':
          final value = '${e['value'] ?? ''}';
          final size = _int(e['size'], 1).clamp(1, 4);
          if (needsRaster(value)) {
            b.raster(await rasterizer.renderText(
              value,
              width: dots,
              fontSize: _baseFontSize * size,
              bold: bold,
              align: align,
            ));
          } else {
            b
              ..align(align)
              ..bold(bold)
              ..textSize(size, size)
              ..line(value)
              ..textSize(1, 1)
              ..bold(false)
              ..align(PosAlign.left);
          }
        case 'row':
          final left = '${e['left'] ?? ''}';
          final right = '${e['right'] ?? ''}';
          if (needsRaster(left) || needsRaster(right)) {
            b.raster(await rasterizer.renderRow(left, right, width: dots, bold: bold));
          } else {
            b.bold(bold);
            for (final l in formatRow(left, right, b.charsPerLine)) {
              b.line(l);
            }
            b.bold(false);
          }
        case 'line':
          b.separator(char: '${e['char'] ?? '-'}');
        case 'feed':
          b.feed(_int(e['lines'], 1));
        case 'barcode':
          b
            ..align(PosAlign.center)
            ..barcode128('${e['value'] ?? ''}', height: _int(e['height'], 80))
            ..align(PosAlign.left);
        case 'qr':
          b
            ..align(PosAlign.center)
            ..qr('${e['value'] ?? ''}', moduleSize: _int(e['size'], 6))
            ..align(PosAlign.left);
        case 'image':
          final bitmap = await rasterizer.decodeImage(
            _base64(e['base64'], i),
            maxWidth: _int(e['width'], dots).clamp(8, dots),
          );
          b.raster(bitmap.aligned(dots, e['align'] == null ? PosAlign.center : align));
        case 'cut':
          b.cut(partial: e['full'] != true);
          cut = true;
        case 'cash_drawer':
          b.openCashDrawer();
        case 'raw':
          b.raw(_base64(e['base64'], i));
        default:
          throw FormatException('Unknown element type "${e['type']}" at index $i');
      }
    }

    // Raw jobs carry their own cut/feed; never append to them.
    final isRawOnly = elements.isNotEmpty && elements.every((e) => e['type'] == 'raw');
    if (autoCut && !cut && !isRawOnly) {
      b
        ..feed(3)
        ..cut();
    }
    return b.build();
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

num _num(Object? v, String field, {num? fallback}) {
  if (v == null && fallback != null) return fallback;
  if (v is num) return v;
  final parsed = num.tryParse('$v');
  if (parsed == null) throw FormatException('"$field" must be a number');
  return parsed;
}

String _money(num v) => v.toStringAsFixed(2);

String _qty(num v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';

List<String> _lines(Object? v) => switch (v) {
  null => const [],
  List l => [for (final x in l) '$x'],
  _ => '$v'.split('\n'),
};

List<Map<String, dynamic>> _list(Object? v) {
  if (v == null) return const [];
  if (v is! List) throw const FormatException('Expected an array');
  return [
    for (final x in v)
      if (x is Map) Map<String, dynamic>.from(x) else throw const FormatException('Expected array of objects'),
  ];
}
