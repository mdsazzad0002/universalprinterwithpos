import '../../core/escpos/esc_pos_builder.dart';

/// Command language the printer understands.
enum PrinterProtocol {
  escpos('Receipt (ESC/POS)'),
  tspl('Label (TSPL)'),
  zpl('Label (ZPL / Zebra)'),

  /// Office printers (A4) over IPP, including CUPS queues. PDF documents only.
  ipp('A4 / PDF (IPP)');

  const PrinterProtocol(this.label);

  final String label;

  static PrinterProtocol parse(String? value) =>
      values.firstWhere((p) => p.name == value, orElse: () => escpos);
}

enum ConnectionType {
  bluetooth('Bluetooth'),
  network('Wi-Fi / LAN'),
  usb('USB');

  const ConnectionType(this.label);

  final String label;

  static ConnectionType parse(String value) =>
      values.firstWhere((t) => t.name == value, orElse: () => network);
}

class Printer {
  const Printer({
    required this.id,
    required this.name,
    required this.connectionType,
    required this.address,
    this.port,
    this.paperWidth = 58,
    this.protocol = PrinterProtocol.escpos,
    this.dpi = 203,
    this.labelHeight,
    this.labelGap = 2,
    this.autoCut = true,
    this.isDefault = false,
    required this.createdAt,
  });

  final String id;
  final String name;
  final ConnectionType connectionType;

  /// Bluetooth MAC address, network host / IP, or USB `vendorId:productId`.
  /// IPP printers: host / IP, or a full `ipp://` URL (e.g. a CUPS queue).
  final String address;
  final int? port;

  /// Paper (roll) or label width in mm.
  final int paperWidth;
  final PrinterProtocol protocol;

  /// 203 or 300. ESC/POS printers are always treated as 203.
  final int dpi;

  /// Label height in mm (TSPL). Null = continuous paper, length follows content.
  final int? labelHeight;

  /// Gap between labels in mm (TSPL).
  final double labelGap;

  bool get isLabel => protocol == PrinterProtocol.tspl || protocol == PrinterProtocol.zpl;

  bool get isDocument => protocol == PrinterProtocol.ipp;

  /// "80 mm", "50×30 mm label · 300 dpi" or "A4 · PDF".
  String get paperLabel => isDocument
      ? 'A4 · PDF'
      : isLabel
      ? '$paperWidth×${labelHeight ?? '∞'} mm label · $dpi dpi'
      : '$paperWidth mm';

  PaperGeometry geometry({int? widthMm, int? heightMm}) => PaperGeometry(
    widthMm ?? paperWidth,
    dpi: isLabel ? dpi : 203,
    heightMm: isLabel ? (heightMm ?? labelHeight) : null,
    label: isLabel,
  );
  final bool autoCut;
  final bool isDefault;
  final DateTime createdAt;

  String get target => isDocument || connectionType != ConnectionType.network ? address : '$address:${port ?? 9100}';

  Printer copyWith({
    String? name,
    ConnectionType? connectionType,
    String? address,
    int? port,
    int? paperWidth,
    int? dpi,
    bool? autoCut,
    bool? isDefault,
  }) => Printer(
    id: id,
    name: name ?? this.name,
    connectionType: connectionType ?? this.connectionType,
    address: address ?? this.address,
    port: port ?? this.port,
    paperWidth: paperWidth ?? this.paperWidth,
    protocol: protocol,
    dpi: dpi ?? this.dpi,
    labelHeight: labelHeight,
    labelGap: labelGap,
    autoCut: autoCut ?? this.autoCut,
    isDefault: isDefault ?? this.isDefault,
    createdAt: createdAt,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'connection_type': connectionType.name,
    'address': address,
    'port': port,
    'paper_width': paperWidth,
    'protocol': protocol.name,
    'dpi': dpi,
    'label_height': labelHeight,
    'label_gap': labelGap,
    'auto_cut': autoCut ? 1 : 0,
    'is_default': isDefault ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory Printer.fromRow(Map<String, Object?> r) => Printer(
    id: r['id'] as String,
    name: r['name'] as String,
    connectionType: ConnectionType.parse(r['connection_type'] as String),
    address: r['address'] as String,
    port: r['port'] as int?,
    paperWidth: r['paper_width'] as int? ?? 58,
    protocol: PrinterProtocol.parse(r['protocol'] as String?),
    dpi: r['dpi'] as int? ?? 203,
    labelHeight: r['label_height'] as int?,
    labelGap: (r['label_gap'] as num?)?.toDouble() ?? 2,
    autoCut: r['auto_cut'] == 1,
    isDefault: r['is_default'] == 1,
    createdAt: DateTime.parse(r['created_at'] as String),
  );

  /// Shape exposed through the local API.
  Map<String, Object?> toApiJson() => {
    'id': id,
    'name': name,
    'connection_type': connectionType.name,
    'paper_width': paperWidth,
    'protocol': protocol.name,
    'is_default': isDefault,
  };
}
