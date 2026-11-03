enum ConnectionType {
  bluetooth('Bluetooth'),
  network('Wi-Fi / LAN');

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
    this.protocol = 'escpos',
    this.autoCut = true,
    this.isDefault = false,
    required this.createdAt,
  });

  final String id;
  final String name;
  final ConnectionType connectionType;

  /// Bluetooth MAC address or network host / IP.
  final String address;
  final int? port;

  /// Paper width in mm: 58 or 80.
  final int paperWidth;
  final String protocol;
  final bool autoCut;
  final bool isDefault;
  final DateTime createdAt;

  String get target => connectionType == ConnectionType.network ? '$address:${port ?? 9100}' : address;

  Printer copyWith({
    String? name,
    ConnectionType? connectionType,
    String? address,
    int? port,
    int? paperWidth,
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
    'protocol': protocol,
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
    protocol: r['protocol'] as String? ?? 'escpos',
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
    'protocol': protocol,
    'is_default': isDefault,
  };
}
