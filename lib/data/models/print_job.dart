import 'dart:convert';

enum JobStatus {
  pending,
  processing,
  printing,

  /// All bytes were delivered to the printer. Most printers cannot confirm
  /// that paper actually came out.
  completed,
  failed,
  cancelled;

  bool get isActive => this == pending || this == processing || this == printing;

  static JobStatus parse(String value) =>
      values.firstWhere((s) => s.name == value, orElse: () => failed);
}

class PrintJob {
  const PrintJob({
    required this.id,
    required this.printerId,
    required this.printerName,
    required this.source,
    required this.documentType,
    required this.payload,
    this.copies = 1,
    this.reference,
    this.clientId,
    this.route,
    this.paperWidth,
    this.status = JobStatus.pending,
    this.error,
    this.attempts = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String printerId;
  final String printerName;

  /// Where the job came from: `app`, `api`, `test`.
  final String source;
  final String documentType;
  final Map<String, dynamic> payload;
  final int copies;

  /// Caller-supplied id used to reject duplicate submissions.
  final String? reference;

  /// Paired software that sent the job, and the route it used.
  final String? clientId;
  final String? route;

  /// Paper width the job is laid out for (mm). Null = printer's width.
  final int? paperWidth;
  final JobStatus status;
  final String? error;
  final int attempts;
  final DateTime createdAt;
  final DateTime updatedAt;

  PrintJob copyWith({JobStatus? status, String? error, bool clearError = false, int? attempts}) => PrintJob(
    id: id,
    printerId: printerId,
    printerName: printerName,
    source: source,
    documentType: documentType,
    payload: payload,
    copies: copies,
    reference: reference,
    clientId: clientId,
    route: route,
    paperWidth: paperWidth,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    attempts: attempts ?? this.attempts,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'printer_id': printerId,
    'printer_name': printerName,
    'source': source,
    'document_type': documentType,
    'payload': jsonEncode(payload),
    'copies': copies,
    'reference': reference,
    'client_id': clientId,
    'route': route,
    'paper_width': paperWidth,
    'status': status.name,
    'error': error,
    'attempts': attempts,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory PrintJob.fromRow(Map<String, Object?> r) => PrintJob(
    id: r['id'] as String,
    printerId: r['printer_id'] as String,
    printerName: r['printer_name'] as String,
    source: r['source'] as String,
    documentType: r['document_type'] as String,
    payload: Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map),
    copies: r['copies'] as int? ?? 1,
    reference: r['reference'] as String?,
    clientId: r['client_id'] as String?,
    route: r['route'] as String?,
    paperWidth: r['paper_width'] as int?,
    status: JobStatus.parse(r['status'] as String),
    error: r['error'] as String?,
    attempts: r['attempts'] as int? ?? 0,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );

  Map<String, Object?> toApiJson() => {
    'job_id': id,
    'status': status.name,
    'printer_id': printerId,
    'printer_name': printerName,
    'route': route,
    'paper_width_mm': paperWidth,
    'document_type': documentType,
    'copies': copies,
    'reference': reference,
    'error': error,
    'attempts': attempts,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };
}
