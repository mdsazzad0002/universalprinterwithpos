import 'package:flutter/foundation.dart';

import '../core/escpos/esc_pos_builder.dart';
import '../data/database.dart';
import '../data/models/client.dart';
import 'printer_store.dart';

/// Route declared by software in a sync call.
class RouteInput {
  const RouteInput({
    required this.key,
    required this.name,
    this.printerId,
    this.clearPrinter = false,
    this.paperWidth,
    this.copies,
  });

  final String key;
  final String name;
  final String? printerId;

  /// `"printer_id": null` (or `""`) was sent explicitly: unassign the route so
  /// it prints on the default printer. Leaving the field out keeps the choice.
  final bool clearPrinter;
  final int? paperWidth;
  final int? copies;

  static final _keyPattern = RegExp(r'^[a-z0-9][a-z0-9_.-]{0,49}$');

  /// Throws [FormatException] with a caller-facing message.
  factory RouteInput.fromJson(Object? json, int index) {
    if (json is! Map) throw FormatException('routes[$index] must be an object');
    final key = json['key'];
    if (key is! String || !_keyPattern.hasMatch(key)) {
      throw FormatException('routes[$index].key must be lowercase letters, digits, "_", "-" or "." (max 50)');
    }
    final rawPrinter = json['printer_id']?.toString().trim();
    return RouteInput(
      key: key,
      name: (json['name'] as Object? ?? key).toString(),
      printerId: rawPrinter == null || rawPrinter.isEmpty ? null : rawPrinter,
      clearPrinter: json.containsKey('printer_id') && (rawPrinter == null || rawPrinter.isEmpty),
      paperWidth: parsePaperWidth(json['paper_width_mm'], 'routes[$index].paper_width_mm'),
      copies: switch (json['copies']) {
        null => null,
        num n when n >= 1 && n <= 20 => n.toInt(),
        _ => throw FormatException('routes[$index].copies must be 1..20'),
      },
    );
  }
}

int? parsePaperWidth(Object? value, String field) {
  if (value == null) return null;
  if (value is num &&
      value >= PaperGeometry.minWidthMm &&
      value <= PaperGeometry.maxWidthMm &&
      value == value.roundToDouble()) {
    return value.toInt();
  }
  throw FormatException(
    '"$field" must be a whole number of mm between ${PaperGeometry.minWidthMm} and ${PaperGeometry.maxWidthMm}',
  );
}

/// Paired software and their routes.
class ClientStore extends ChangeNotifier {
  ClientStore(this._clients, this._routes, this._printers);

  final ClientRepository _clients;
  final RouteRepository _routes;
  final PrinterStore _printers;

  List<ApiClient> _clientList = const [];
  List<PrintRoute> _routeList = const [];

  List<ApiClient> get clients => _clientList;

  List<PrintRoute> routesFor(String clientId) =>
      _routeList.where((r) => r.clientId == clientId).toList();

  /// Clients that have routes, including the manual (master token) one.
  List<String> get clientIdsWithRoutes => {
    for (final c in _clientList) c.id,
    for (final r in _routeList) r.clientId,
  }.toList();

  ApiClient? byId(String id) {
    for (final c in _clientList) {
      if (c.id == id) return c;
    }
    return null;
  }

  ApiClient? byToken(String token) {
    for (final c in _clientList) {
      if (c.token == token) return c;
    }
    return null;
  }

  PrintRoute? route(String clientId, String key) {
    for (final r in _routeList) {
      if (r.clientId == clientId && r.key == key) return r;
    }
    return null;
  }

  Future<void> load() async {
    _clientList = await _clients.all();
    _routeList = await _routes.all();
    notifyListeners();
  }

  /// Creates or re-pairs a client and returns its new token. Re-pairing keeps
  /// existing routes, so printer assignments survive a reinstall of the POS.
  Future<ApiClient> register(String id, String name) async {
    final existing = byId(id);
    final client = ApiClient(
      id: id,
      name: name,
      token: newToken(),
      createdAt: existing?.createdAt ?? DateTime.now(),
      lastSeenAt: DateTime.now(),
    );
    await _clients.save(client);
    await load();
    return client;
  }

  /// Creates an access profile from the app itself (no pairing), for another
  /// user or software that will connect with the token.
  Future<ApiClient> createProfile(String name) {
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty ? 'profile' : (slug.length > 40 ? slug.substring(0, 40) : slug);
    var id = base;
    for (var i = 2; byId(id) != null || id == ApiClient.manualId; i++) {
      id = '$base-$i';
    }
    return register(id, name.trim());
  }

  Future<void> revoke(String id) async {
    await _clients.delete(id);
    await load();
  }

  Future<void> touch(String id) => _clients.touch(id);

  /// Upserts declared routes. Existing printer assignments are kept unless the
  /// software sends a `printer_id` (`null` / `""` unassigns). With [prune] routes not in the list are
  /// removed.
  Future<List<PrintRoute>> sync(String clientId, List<RouteInput> inputs, {bool prune = false}) async {
    for (final input in inputs) {
      if (input.printerId != null && _printers.byId(input.printerId!) == null) {
        throw FormatException('Route "${input.key}": printer "${input.printerId}" not found');
      }
    }
    for (final input in inputs) {
      final current = route(clientId, input.key);
      await _routes.save(PrintRoute(
        clientId: clientId,
        key: input.key,
        name: input.name,
        printerId: input.clearPrinter ? null : (input.printerId ?? current?.printerId),
        paperWidth: input.paperWidth ?? current?.paperWidth,
        copies: input.copies ?? current?.copies ?? 1,
        updatedAt: DateTime.now(),
      ));
    }
    if (prune) {
      final keep = {for (final i in inputs) i.key};
      for (final r in routesFor(clientId)) {
        if (!keep.contains(r.key)) await _routes.delete(clientId, r.key);
      }
    }
    await load();
    return routesFor(clientId);
  }

  /// Unknown route keys used in a print call are registered automatically so
  /// they show up in the app for assignment.
  Future<PrintRoute> ensureRoute(String clientId, String key) async {
    final existing = route(clientId, key);
    if (existing != null) return existing;
    if (!RouteInput._keyPattern.hasMatch(key)) {
      throw FormatException('Invalid route "$key"');
    }
    final created = PrintRoute(clientId: clientId, key: key, name: key, updatedAt: DateTime.now());
    await _routes.save(created);
    await load();
    return created;
  }

  Future<void> updateRoute(PrintRoute route) async {
    await _routes.save(route);
    await load();
  }

  Future<void> deleteRoute(PrintRoute route) async {
    await _routes.delete(route.clientId, route.key);
    await load();
  }

  Future<void> onPrinterDeleted(String printerId) async {
    await _routes.unassignPrinter(printerId);
    await load();
  }

  Map<String, Object?> routeJson(PrintRoute r) {
    final printer = r.printerId == null ? null : _printers.byId(r.printerId!);
    final width = r.paperWidth ?? printer?.paperWidth;
    return {
      'key': r.key,
      'name': r.name,
      'assigned': printer != null,
      'printer_id': printer?.id,
      'printer_name': printer?.name,
      'copies': r.copies,
      'paper': printer?.geometry(widthMm: width).toJson(),
    };
  }
}
