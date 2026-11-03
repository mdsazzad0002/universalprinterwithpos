import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'printer_connection.dart';

/// Prints a PDF with an IPP `Print-Job` request (RFC 8011). Works with
/// network office printers (IPP Everywhere / AirPrint) and CUPS queues, e.g.
/// `ipp://localhost:631/printers/HP_LaserJet` on Linux.
class IppConnection implements PrinterConnection {
  IppConnection(this.printerUri, {this.jobName = 'Universal Print', this.timeout = const Duration(seconds: 60)});

  /// `ipp://host:631/ipp/print` or `ipps://...`.
  final Uri printerUri;
  final String jobName;
  final Duration timeout;

  static const defaultPort = 631;
  static const defaultPath = '/ipp/print';

  /// Accepts a host / IP (+ port) or a full `ipp://`, `ipps://`, `http://`
  /// URL. Throws [FormatException] for anything else.
  static Uri uriFor(String address, {int? port}) {
    final a = address.trim();
    if (!a.contains('://')) {
      if (a.isEmpty) throw const FormatException('Enter the printer IP or IPP URL');
      return Uri(scheme: 'ipp', host: a, port: port ?? defaultPort, path: defaultPath);
    }
    final u = Uri.parse(a);
    final scheme = switch (u.scheme) {
      'ipp' || 'http' => 'ipp',
      'ipps' || 'https' => 'ipps',
      _ => throw FormatException('Unsupported URL scheme "${u.scheme}" (use ipp://)'),
    };
    return u.replace(
      scheme: scheme,
      port: u.hasPort ? u.port : defaultPort,
      path: u.path.isEmpty || u.path == '/' ? defaultPath : u.path,
    );
  }

  @override
  Future<void> send(Uint8List data) async {
    final http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      // Printers ship self-signed certificates; this only matters for ipps://.
      ..badCertificateCallback = (_, _, _) => true;
    final target = printerUri.replace(scheme: printerUri.scheme == 'ipps' ? 'https' : 'http');
    try {
      final req = await http.postUrl(target);
      final body = encodePrintJob(printerUri.toString(), jobName, data);
      req.headers.contentType = ContentType('application', 'ipp');
      // Many printers do not accept chunked uploads.
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close().timeout(timeout);
      final reply = await res.fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c)).timeout(timeout);
      if (res.statusCode != HttpStatus.ok) {
        throw PrinterConnectionException('Printer answered HTTP ${res.statusCode} at $target');
      }
      final status = decodeStatus(reply.takeBytes());
      if (status.code >= 0x0100) {
        throw PrinterConnectionException(_describe(status));
      }
    } on SocketException catch (e) {
      throw PrinterConnectionException('Cannot reach ${printerUri.host}:${printerUri.port} (${e.osError?.message ?? e.message})');
    } on TimeoutException {
      throw PrinterConnectionException('Printer ${printerUri.host} did not answer');
    } on HandshakeException catch (e) {
      throw PrinterConnectionException('Secure connection to ${printerUri.host} failed (${e.message})');
    } finally {
      http.close(force: true);
    }
  }

  static String _describe(({int code, String? message}) s) {
    final reason = switch (s.code) {
      0x0400 => 'bad request',
      0x0401 || 0x0402 || 0x0403 => 'not allowed (printer needs a login?)',
      0x0406 => 'printer queue not found, check the URL path',
      0x040A => 'printer does not accept PDF',
      0x0500 || 0x0504 => 'printer error',
      0x0506 || 0x0507 => 'printer is busy or not accepting jobs',
      _ => 'error 0x${s.code.toRadixString(16).padLeft(4, '0')}',
    };
    return 'Printer refused the job: $reason${s.message == null ? '' : ' (${s.message})'}';
  }

  /// IPP/1.1 Print-Job request: operation attributes, then the document.
  static Uint8List encodePrintJob(String printerUri, String jobName, Uint8List document) {
    final b = BytesBuilder(copy: false);
    void u16(int v) => b.add([v >> 8 & 0xFF, v & 0xFF]);
    void attr(int tag, String name, String value) {
      final n = utf8.encode(name), v = utf8.encode(value);
      b.addByte(tag);
      u16(n.length);
      b.add(n);
      u16(v.length);
      b.add(v);
    }

    b.add(const [0x01, 0x01]); // version 1.1
    u16(0x0002); // Print-Job
    b.add(const [0, 0, 0, 1]); // request-id
    b.addByte(0x01); // operation-attributes-tag
    attr(0x47, 'attributes-charset', 'utf-8');
    attr(0x48, 'attributes-natural-language', 'en');
    attr(0x45, 'printer-uri', printerUri);
    attr(0x42, 'requesting-user-name', 'universal-print');
    attr(0x42, 'job-name', jobName);
    attr(0x49, 'document-format', 'application/pdf');
    b.addByte(0x03); // end-of-attributes-tag
    b.add(document);
    return b.toBytes();
  }

  /// Status code and `status-message`, if the printer sent one.
  static ({int code, String? message}) decodeStatus(Uint8List reply) {
    if (reply.length < 8) throw PrinterConnectionException('Printer sent an invalid IPP response');
    final code = reply[2] << 8 | reply[3];
    String? message;
    var i = 8;
    var name = '';
    while (i < reply.length) {
      final tag = reply[i++];
      if (tag == 0x03) break; // end-of-attributes
      if (tag < 0x10) continue; // group delimiter
      if (i + 2 > reply.length) break;
      final nameLen = reply[i] << 8 | reply[i + 1];
      i += 2;
      if (i + nameLen + 2 > reply.length) break;
      if (nameLen > 0) name = utf8.decode(reply.sublist(i, i + nameLen), allowMalformed: true);
      i += nameLen;
      final valueLen = reply[i] << 8 | reply[i + 1];
      i += 2;
      if (i + valueLen > reply.length) break;
      if (name == 'status-message') {
        message = utf8.decode(reply.sublist(i, i + valueLen), allowMalformed: true);
      }
      i += valueLen;
    }
    return (code: code, message: message);
  }
}
