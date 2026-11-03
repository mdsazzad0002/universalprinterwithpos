/// A piece of software paired with this app (a POS, ERP, web app ...).
class ApiClient {
  const ApiClient({
    required this.id,
    required this.name,
    required this.token,
    required this.createdAt,
    this.lastSeenAt,
  });

  /// Chosen by the software itself, e.g. `my-pos-branch-1`.
  final String id;
  final String name;
  final String token;
  final DateTime createdAt;
  final DateTime? lastSeenAt;

  /// Jobs sent with the master token from the API screen belong here.
  static const manualId = 'default';

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'token': token,
    'created_at': createdAt.toIso8601String(),
    'last_seen_at': lastSeenAt?.toIso8601String(),
  };

  factory ApiClient.fromRow(Map<String, Object?> r) => ApiClient(
    id: r['id'] as String,
    name: r['name'] as String,
    token: r['token'] as String,
    createdAt: DateTime.parse(r['created_at'] as String),
    lastSeenAt: r['last_seen_at'] == null ? null : DateTime.parse(r['last_seen_at'] as String),
  );

  Map<String, Object?> toApiJson() => {
    'client_id': id,
    'client_name': name,
    'paired_at': createdAt.toIso8601String(),
  };
}

/// Maps a print type of a client ("invoice", "kitchen") to a printer.
/// The software declares routes; the user (or the software) assigns printers.
class PrintRoute {
  const PrintRoute({
    required this.clientId,
    required this.key,
    required this.name,
    this.printerId,
    this.paperWidth,
    this.copies = 1,
    required this.updatedAt,
  });

  final String clientId;
  final String key;
  final String name;
  final String? printerId;

  /// Overrides the printer's paper width for this route (mm).
  final int? paperWidth;
  final int copies;
  final DateTime updatedAt;

  PrintRoute copyWith({
    String? name,
    String? printerId,
    bool clearPrinter = false,
    int? paperWidth,
    bool clearPaperWidth = false,
    int? copies,
  }) => PrintRoute(
    clientId: clientId,
    key: key,
    name: name ?? this.name,
    printerId: clearPrinter ? null : (printerId ?? this.printerId),
    paperWidth: clearPaperWidth ? null : (paperWidth ?? this.paperWidth),
    copies: copies ?? this.copies,
    updatedAt: DateTime.now(),
  );

  Map<String, Object?> toRow() => {
    'client_id': clientId,
    'key': key,
    'name': name,
    'printer_id': printerId,
    'paper_width': paperWidth,
    'copies': copies,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory PrintRoute.fromRow(Map<String, Object?> r) => PrintRoute(
    clientId: r['client_id'] as String,
    key: r['key'] as String,
    name: r['name'] as String,
    printerId: r['printer_id'] as String?,
    paperWidth: r['paper_width'] as int?,
    copies: r['copies'] as int? ?? 1,
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}
