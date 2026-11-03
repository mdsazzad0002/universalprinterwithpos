import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/core/connection/ipp_connection.dart';
import 'package:universal_print/core/connection/printer_connection.dart';
import 'package:universal_print/core/pdf/test_page.dart';

/// Minimal IPP printer: records the request and answers with [status].
Future<(HttpServer, List<Uint8List>)> _fakePrinter(int status, {String? message}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final received = <Uint8List>[];
  server.listen((req) async {
    received.add(Uint8List.fromList(await req.fold<List<int>>([], (a, c) => a..addAll(c))));
    final reply = BytesBuilder()
      ..add([0x01, 0x01, status >> 8, status & 0xFF, 0, 0, 0, 1, 0x01]);
    if (message != null) {
      final name = utf8.encode('status-message'), value = utf8.encode(message);
      reply
        ..add([0x41, 0, name.length])
        ..add(name)
        ..add([0, value.length])
        ..add(value);
    }
    reply.addByte(0x03);
    req.response.headers.contentType = ContentType('application', 'ipp');
    req.response.add(reply.toBytes());
    await req.response.close();
  });
  return (server, received);
}

void main() {
  test('printer address becomes an ipp:// URI', () {
    expect(IppConnection.uriFor('192.168.1.20').toString(), 'ipp://192.168.1.20:631/ipp/print');
    expect(IppConnection.uriFor('10.0.0.5', port: 8631).toString(), 'ipp://10.0.0.5:8631/ipp/print');
    expect(IppConnection.uriFor('ipp://localhost/printers/HP').toString(), 'ipp://localhost:631/printers/HP');
    expect(IppConnection.uriFor('https://p.local:443/ipp/print').scheme, 'ipps');
    expect(() => IppConnection.uriFor('ftp://x'), throwsFormatException);
  });

  test('sends a Print-Job with the PDF after the attributes', () async {
    final (server, received) = await _fakePrinter(0x0000);
    addTearDown(() => server.close(force: true));
    final pdf = testPagePdf(['TEST PAGE']);
    final uri = Uri.parse('ipp://127.0.0.1:${server.port}/ipp/print');
    await IppConnection(uri).send(pdf);

    final body = received.single;
    expect(body.sublist(0, 4), [0x01, 0x01, 0x00, 0x02], reason: 'IPP 1.1 Print-Job');
    final text = latin1.decode(body);
    expect(text, contains('printer-uri'));
    expect(text, contains(uri.toString()));
    expect(text, contains('application/pdf'));
    final end = text.indexOf('application/pdf') + 'application/pdf'.length;
    expect(body[end], 0x03, reason: 'end-of-attributes, then the document');
    expect(body.sublist(end + 1), pdf);
  });

  test('IPP error status becomes a readable error', () async {
    final (server, _) = await _fakePrinter(0x040A, message: 'unsupported format');
    addTearDown(() => server.close(force: true));
    final c = IppConnection(Uri.parse('ipp://127.0.0.1:${server.port}/ipp/print'));
    await expectLater(
      c.send(testPagePdf(['x'])),
      throwsA(isA<PrinterConnectionException>().having((e) => e.message, 'message', allOf(
        contains('does not accept PDF'),
        contains('unsupported format'),
      ))),
    );
  });

  test('test page is a well-formed PDF with correct xref offsets', () {
    final pdf = latin1.decode(testPagePdf(['TEST PAGE', 'Printer: (A)']));
    expect(pdf, startsWith('%PDF-1.4\n'));
    expect(pdf, endsWith('%%EOF\n'));
    expect(pdf, contains(r'(Printer: \(A\))'));
    final startxref = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(pdf)!.group(1)!);
    expect(pdf.substring(startxref), startsWith('xref\n0 6\n'));
    final offsets = RegExp(r'(\d{10}) 00000 n ').allMatches(pdf).map((m) => int.parse(m.group(1)!)).toList();
    expect(offsets, hasLength(5));
    for (var i = 0; i < offsets.length; i++) {
      expect(pdf.substring(offsets[i]), startsWith('${i + 1} 0 obj'));
    }
  });
}
