import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/connection/printer_connection.dart';
import '../core/escpos/document_renderer.dart';
import '../core/escpos/rasterizer.dart';
import '../core/tspl/tspl_renderer.dart';
import '../data/database.dart';
import '../data/models/client.dart';
import '../data/models/print_job.dart';
import '../data/models/printer.dart';
import 'client_store.dart';
import 'printer_store.dart';

/// A request the caller can fix (bad payload, unknown printer, ...).
class PrintRequestException implements Exception {
  PrintRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef SubmitResult = ({PrintJob job, bool duplicate});

/// Owns the print queue. Jobs are processed one at a time, in order, so two
/// receipts never interleave on the same printer.
class PrintService extends ChangeNotifier {
  PrintService({
    required this._jobs,
    required this._printers,
    required this._clients,
    this._rasterizer = const FlutterRasterizer(),
    this._connectionFor = PrinterConnection.forPrinter,
  });

  final JobRepository _jobs;
  final PrinterStore _printers;
  final ClientStore _clients;
  final Rasterizer _rasterizer;
  final PrinterConnection Function(Printer) _connectionFor;

  static const maxCopies = 20;
  static const _sendAttempts = 2;

  Future<void> _queue = Future.value();
  List<PrintJob> _recent = const [];

  List<PrintJob> get recentJobs => _recent;

  /// Completes when every queued job has been processed.
  Future<void> get idle => _queue;

  Future<void> init() async {
    await _jobs.failInterrupted();
    await _reload();
  }

  Future<PrintJob?> find(String id) => _jobs.find(id);

  /// Validates and queues a job. Returns the existing job instead when a job
  /// with the same `reference` was already submitted.
  ///
  /// Printer: `printer_id`, else the client's `route`, else the default
  /// printer. A route with no printer assigned yet falls back to the default
  /// printer so nothing is lost while setup is unfinished.
  Future<SubmitResult> submit(
    Map<String, dynamic> payload, {
    String source = 'app',
    String clientId = ApiClient.manualId,
  }) async {
    try {
      return await _submit(payload, source, clientId);
    } on FormatException catch (e) {
      throw PrintRequestException(e.message);
    }
  }

  Future<SubmitResult> _submit(Map<String, dynamic> payload, String source, String clientId) async {
    final printerId = _string(payload['printer_id']);
    final routeKey = _string(payload['route']);

    final route = routeKey == null || printerId != null ? null : await _clients.ensureRoute(clientId, routeKey);
    final Printer? printer;
    if (printerId != null) {
      printer = _printers.byId(printerId);
      if (printer == null) throw PrintRequestException('Printer "$printerId" not found');
    } else {
      printer = (route?.printerId == null ? null : _printers.byId(route!.printerId!)) ?? _printers.defaultPrinter;
      if (printer == null) {
        throw PrintRequestException(route == null
            ? 'No default printer is set'
            : 'Route "$routeKey" has no printer assigned and there is no default printer');
      }
    }

    final reference = _string(payload['reference']);
    if (reference != null) {
      final existing = await _jobs.findByReference(reference);
      if (existing != null) return (job: existing, duplicate: true);
    }

    final paper = payload['paper'];
    if (paper != null && paper is! Map) throw const FormatException('"paper" must be an object');
    final requestedWidth = parsePaperWidth((paper as Map?)?['width_mm'], 'paper.width_mm') ?? route?.paperWidth;
    if (requestedWidth != null && requestedWidth > printer.paperWidth) {
      throw PrintRequestException(
        'paper.width_mm $requestedWidth is wider than printer "${printer.name}" (${printer.paperWidth} mm)',
      );
    }
    final paperWidth = requestedWidth ?? printer.paperWidth;
    final height = paper?['height_mm'];
    if (height != null && (height is! num || height < 5 || height > 1000)) {
      throw const FormatException('"paper.height_mm" must be a number of mm between 5 and 1000');
    }

    payloadToElements(payload, printer.geometry(widthMm: paperWidth).charsPerLine);

    final copies = switch (payload['copies']) {
      null => route?.copies ?? 1,
      num n => n.toInt(),
      _ => throw const FormatException('"copies" must be a number'),
    };
    if (copies < 1 || copies > maxCopies) {
      throw PrintRequestException('"copies" must be between 1 and $maxCopies');
    }

    final now = DateTime.now();
    final job = PrintJob(
      id: newId('JOB'),
      printerId: printer.id,
      printerName: printer.name,
      source: source,
      documentType: (payload['document_type'] ?? 'receipt').toString(),
      payload: payload,
      copies: copies,
      reference: reference,
      clientId: clientId,
      route: routeKey,
      paperWidth: paperWidth,
      createdAt: now,
      updatedAt: now,
    );
    await _jobs.save(job);
    await _reload();
    _enqueue(job.id);
    return (job: job, duplicate: false);
  }

  Future<SubmitResult> testPrint(Printer printer) => submit({
    'printer_id': printer.id,
    'document_type': 'elements',
    'elements': printer.isLabel ? _labelTest(printer) : _receiptTest(printer),
  }, source: 'test');

  static List<Map<String, Object>> _receiptTest(Printer printer) => [
    {'type': 'text', 'value': 'TEST PRINT', 'align': 'center', 'bold': true, 'size': 2},
    {'type': 'line'},
    {'type': 'row', 'left': 'Printer', 'right': printer.name},
    {'type': 'row', 'left': 'Connection', 'right': printer.connectionType.label},
    {'type': 'row', 'left': 'Paper', 'right': printer.paperLabel},
    {'type': 'row', 'left': 'Time', 'right': DateTime.now().toString().substring(0, 19)},
    {'type': 'line'},
    {'type': 'text', 'value': 'বাংলা লেখা প্রিন্ট পরীক্ষা', 'align': 'center'},
    {'type': 'row', 'left': 'চাল ২ কেজি', 'right': '১৪০.০০'},
    {'type': 'line'},
    {'type': 'qr', 'value': 'universal-print:test:${printer.id}', 'size': 5},
    {'type': 'text', 'value': 'Universal Print', 'align': 'center'},
  ];

  /// Small enough for a 40×30 mm label.
  static List<Map<String, Object>> _labelTest(Printer printer) => [
    {'type': 'text', 'value': 'TEST LABEL', 'align': 'center', 'bold': true, 'size': 2},
    {'type': 'text', 'value': printer.paperLabel, 'align': 'center'},
    {'type': 'text', 'value': 'বাংলা লেবেল ✓', 'align': 'center'},
    {'type': 'barcode', 'value': 'UP-TEST-01', 'height': 40},
  ];

  Future<void> retry(String id) async {
    final job = await _jobs.find(id);
    if (job == null || job.status.isActive) return;
    await _save(job.copyWith(status: JobStatus.pending, clearError: true));
    _enqueue(id);
  }

  /// Only jobs still waiting in the queue can be cancelled.
  Future<bool> cancel(String id) async {
    final job = await _jobs.find(id);
    if (job == null || job.status != JobStatus.pending) return false;
    await _save(job.copyWith(status: JobStatus.cancelled));
    return true;
  }

  /// Clears the job history; jobs still in the queue are kept.
  Future<int> clearFinished() async {
    final removed = await _jobs.deleteFinished();
    await _reload();
    return removed;
  }

  void _enqueue(String id) {
    _queue = _queue.then((_) => _process(id));
  }

  Future<void> _process(String id) async {
    var job = await _jobs.find(id);
    if (job == null || job.status != JobStatus.pending) return;

    try {
      final printer = _printers.byId(job.printerId);
      if (printer == null) throw PrintRequestException('Printer was deleted');

      job = job.copyWith(status: JobStatus.processing);
      await _save(job);
      final bytes = await _render(printer, job);
      await _dump(job, bytes);

      job = job.copyWith(status: JobStatus.printing);
      await _save(job);
      final connection = _connectionFor(printer);
      for (var attempt = 1; ; attempt++) {
        job = job!.copyWith(attempts: job.attempts + 1);
        try {
          await connection.send(bytes);
          break;
        } catch (_) {
          if (attempt >= _sendAttempts) rethrow;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      await _save(job.copyWith(status: JobStatus.completed, clearError: true));
    } catch (e) {
      final message = e is FormatException ? e.message : e.toString();
      await _save(job!.copyWith(status: JobStatus.failed, error: message));
    }
  }

  Future<Uint8List> _render(Printer printer, PrintJob job) async {
    final paper = job.payload['paper'];
    final geometry = printer.geometry(
      widthMm: job.paperWidth,
      heightMm: paper is Map && paper['height_mm'] is num ? (paper['height_mm'] as num).round() : null,
    );
    final elements = payloadToElements(job.payload, geometry.charsPerLine);
    final one = printer.isLabel
        ? await TsplRenderer(geometry: geometry, gapMm: printer.labelGap, rasterizer: _rasterizer).render(elements)
        : await DocumentRenderer(
            paperWidthMm: geometry.widthMm,
            rasterizer: _rasterizer,
            autoCut: printer.autoCut,
          ).render(elements);
    if (job.copies == 1) return one;
    final all = BytesBuilder(copy: false);
    for (var i = 0; i < job.copies; i++) {
      all.add(one);
    }
    return all.toBytes();
  }

  /// Diagnostics: with UNIVERSAL_PRINT_DUMP_DIR set, every job's printer
  /// bytes are also written to `<dir>/<job id>.bin`.
  static Future<void> _dump(PrintJob job, Uint8List bytes) async {
    final dir = Platform.environment['UNIVERSAL_PRINT_DUMP_DIR'];
    if (dir == null || dir.isEmpty) return;
    try {
      await File('$dir/${job.id}.bin').writeAsBytes(bytes);
    } on FileSystemException {
      // Diagnostics must never break printing.
    }
  }

  Future<void> _save(PrintJob job) async {
    await _jobs.save(job);
    await _reload();
  }

  Future<void> _reload() async {
    _recent = await _jobs.recent();
    notifyListeners();
  }
}

String? _string(Object? v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}
