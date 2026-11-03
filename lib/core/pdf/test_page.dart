import 'dart:convert';
import 'dart:typed_data';

/// One A4 page of Helvetica text, for the test print of A4 / PDF printers.
/// Only Latin-1 text: the standard PDF fonts have no Bangla.
Uint8List testPagePdf(List<String> lines) {
  String escape(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)').replaceAll(RegExp(r'[^\x20-\xFF]'), '?');

  final content = StringBuffer('BT /F1 28 Tf 72 760 Td (${escape(lines.first)}) Tj /F1 12 Tf');
  for (final l in lines.skip(1)) {
    content.write(' 0 -22 Td (${escape(l)}) Tj');
  }
  content.write(' ET');
  final stream = latin1.encode(content.toString());

  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    '<< /Length ${stream.length} >>\nstream\n${latin1.decode(stream)}\nendstream',
  ];

  final out = BytesBuilder(copy: false);
  void write(String s) => out.add(latin1.encode(s));
  write('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  // Each xref entry is exactly 20 bytes, including the two-byte line end.
  write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.toBytes();
}
