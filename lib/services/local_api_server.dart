import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../data/models/client.dart';
import '../data/models/printer.dart';
import 'client_store.dart';
import 'print_service.dart';
import 'printer_store.dart';

enum PairingStatus { pending, approved, rejected, expired }

/// A software asking to be introduced. Shown to the user for approval.
class PairingRequest {
  PairingRequest({required this.id, required this.clientId, required this.clientName, required this.code})
    : createdAt = DateTime.now();

  final String id;
  final String clientId;
  final String clientName;

  /// Shown both in the software and in the app, so the user can confirm
  /// they are approving the right thing.
  final String code;
  final DateTime createdAt;
  PairingStatus status = PairingStatus.pending;
  String? token;

  bool get isExpired => DateTime.now().difference(createdAt) > LocalApiServer.pairingTimeout;
}

/// Local HTTP API used by other software to print. See docs/API.md.
class LocalApiServer extends ChangeNotifier {
  LocalApiServer({
    required this._settings,
    required this._printService,
    required this._printers,
    required this._clients,
  });

  final SettingsRepository _settings;
  final PrintService _printService;
  final PrinterStore _printers;
  final ClientStore _clients;

  static const defaultPort = 8765;
  static const maxBodyBytes = 10 * 1024 * 1024;
  static const maxBatchJobs = 20;
  static const version = '1.3.0';
  static const pairingTimeout = Duration(minutes: 3);
  static const _features = ['text', 'bangla', 'image', 'barcode', 'qr', 'cut', 'cash_drawer', 'raw'];
  static const _labelFeatures = ['text', 'bangla', 'image', 'barcode', 'qr', 'raw'];

  HttpServer? _server;
  bool enabled = true;
  int port = defaultPort;

  /// Bind on all interfaces so other devices on the LAN can print.
  bool allowLan = false;

  /// When false, requests from this device (loopback) need no token. Requests
  /// from other devices on the LAN always need one.
  bool requireToken = false;

  /// Master token for quick manual setup; acts as the `default` client.
  String token = '';
  String? lastError;
  final _pairings = <String, PairingRequest>{};

  bool get isRunning => _server != null;

  /// Actual listening port (differs from [port] only when [port] is 0).
  int? get boundPort => _server?.port;

  List<PairingRequest> get pendingPairings {
    _pairings.removeWhere((_, p) => p.isExpired && p.status == PairingStatus.pending);
    return _pairings.values.where((p) => p.status == PairingStatus.pending).toList();
  }

  Future<void> init() async {
    enabled = (await _settings.get('api_enabled')) != 'false';
    port = int.tryParse(await _settings.get('api_port') ?? '') ?? defaultPort;
    allowLan = (await _settings.get('api_allow_lan')) == 'true';
    requireToken = (await _settings.get('api_require_token')) == 'true';
    token = await _settings.get('api_token') ?? '';
    if (token.isEmpty) await regenerateToken();
    if (enabled) await start();
  }

  Future<void> start() async {
    await stop();
    try {
      final address = allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      final server = await HttpServer.bind(address, port);
      server.listen(_handle);
      _server = server;
      lastError = null;
    } on SocketException catch (e) {
      lastError = 'Cannot start on port $port: ${e.osError?.message ?? e.message}';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    notifyListeners();
  }

  Future<void> configure({bool? enabled, int? port, bool? allowLan, bool? requireToken}) async {
    if (requireToken != null) {
      this.requireToken = requireToken;
      await _settings.set('api_require_token', '$requireToken');
      notifyListeners();
      if (enabled == null && port == null && allowLan == null) return;
    }
    if (enabled != null) {
      this.enabled = enabled;
      await _settings.set('api_enabled', '$enabled');
    }
    if (port != null) {
      this.port = port;
      await _settings.set('api_port', '$port');
    }
    if (allowLan != null) {
      this.allowLan = allowLan;
      await _settings.set('api_allow_lan', '$allowLan');
    }
    this.enabled ? await start() : await stop();
  }

  Future<void> regenerateToken() async {
    token = newToken();
    await _settings.set('api_token', token);
    notifyListeners();
  }

  Future<void> approvePairing(String pairingId) async {
    final p = _pairings[pairingId];
    if (p == null || p.status != PairingStatus.pending) return;
    if (p.isExpired) {
      p.status = PairingStatus.expired;
    } else {
      p.token = (await _clients.register(p.clientId, p.clientName)).token;
      p.status = PairingStatus.approved;
    }
    notifyListeners();
  }

  void rejectPairing(String pairingId) {
    _pairings[pairingId]?.status = PairingStatus.rejected;
    notifyListeners();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type, X-Api-Key')
      // Lets HTTPS pages in Chrome reach this localhost server.
      ..set('Access-Control-Allow-Private-Network', 'true');

    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
        await res.close();
        return;
      }
      final path = req.uri.path.replaceFirst(RegExp(r'/+$'), '');
      final route = '${req.method} $path';

      // --- public ---------------------------------------------------------
      if (route == 'GET /api/ping') {
        return await _json(res, 200, {
          'success': true,
          'app': 'universal_print',
          'version': version,
          'token_required': requireToken || req.connectionInfo?.remoteAddress.isLoopback != true,
        });
      }
      if (route == 'POST /api/pair') return await _startPairing(req, res);
      final pairMatch = RegExp(r'^GET /api/pair/([\w-]+)$').firstMatch(route);
      if (pairMatch != null) return await _pairingStatus(res, pairMatch.group(1)!);

      // --- authenticated --------------------------------------------------
      final clientId = _authenticate(req);
      if (clientId == null) {
        return await _json(res, 401, {
          'success': false,
          'error': requireToken || req.connectionInfo?.remoteAddress.isLoopback != true
              ? 'Invalid or missing API token'
              : 'Invalid API token',
          'code': 'unauthorized',
        });
      }
      if (clientId != ApiClient.manualId) unawaited(_clients.touch(clientId));

      switch (route) {
        case 'GET /api/config':
          return await _json(res, 200, {'success': true, ..._config(clientId)});
        case 'GET /api/printers':
          return await _json(res, 200, {
            'success': true,
            'default_printer_id': _printers.defaultPrinter?.id,
            'printers': [for (final p in _printers.printers) _printerJson(p)],
          });
        case 'GET /api/routes':
          return await _json(res, 200, {'success': true, 'routes': _routesJson(clientId)});
        case 'PUT /api/routes':
          final body = await _readJson(req);
          final list = body['routes'];
          if (list is! List) throw const FormatException('"routes" must be an array');
          final inputs = [for (var i = 0; i < list.length; i++) RouteInput.fromJson(list[i], i)];
          await _clients.sync(clientId, inputs, prune: body['prune'] == true);
          final routes = _routesJson(clientId);
          return await _json(res, 200, {
            'success': true,
            'routes': routes,
            'unassigned': [for (final r in routes) if (r['assigned'] != true) r['key']],
          });
        case 'POST /api/print':
          final result = await _printService.submit(await _readJson(req), source: 'api', clientId: clientId);
          return await _json(res, result.duplicate ? 200 : 202, {
            'success': true,
            'duplicate': result.duplicate,
            ...result.job.toApiJson(),
          });
        case 'POST /api/print/batch':
          final jobs = (await _readJson(req))['jobs'];
          if (jobs is! List || jobs.isEmpty || jobs.length > maxBatchJobs) {
            throw FormatException('"jobs" must be an array of 1..$maxBatchJobs print requests');
          }
          final results = <Map<String, Object?>>[];
          for (final job in jobs) {
            try {
              if (job is! Map) throw PrintRequestException('Each job must be an object');
              final r = await _printService.submit(Map<String, dynamic>.from(job), source: 'api', clientId: clientId);
              results.add({'success': true, 'duplicate': r.duplicate, ...r.job.toApiJson()});
            } on PrintRequestException catch (e) {
              results.add({'success': false, 'error': e.message});
            }
          }
          return await _json(res, 207, {'success': results.every((r) => r['success'] == true), 'results': results});
      }

      final jobMatch = RegExp(r'^GET /api/jobs/([\w-]+)$').firstMatch(route);
      if (jobMatch != null) {
        final job = await _printService.find(jobMatch.group(1)!);
        if (job == null || (job.clientId != null && job.clientId != clientId)) {
          return await _json(res, 404, {'success': false, 'error': 'Job not found'});
        }
        return await _json(res, 200, {'success': true, ...job.toApiJson()});
      }

      return await _json(res, 404, {'success': false, 'error': 'Not found'});
    } on PrintRequestException catch (e) {
      return _json(res, 422, {'success': false, 'error': e.message, 'code': 'invalid_request'});
    } on FormatException catch (e) {
      return _json(res, 422, {'success': false, 'error': e.message, 'code': 'invalid_request'});
    } on _PayloadTooLarge {
      return _json(res, 413, {'success': false, 'error': 'Body larger than ${maxBodyBytes ~/ 1024 ~/ 1024} MB'});
    } catch (e) {
      return _json(res, 500, {'success': false, 'error': 'Internal error: $e'});
    }
  }

  Future<void> _startPairing(HttpRequest req, HttpResponse res) async {
    final body = await _readJson(req);
    final clientId = body['client_id'];
    final clientName = body['client_name'];
    if (clientId is! String || !RegExp(r'^[\w.-]{1,64}$').hasMatch(clientId) || clientId == ApiClient.manualId) {
      throw const FormatException('"client_id" must be 1-64 letters, digits, "_", "-" or "."');
    }
    if (clientName is! String || clientName.trim().isEmpty) {
      throw const FormatException('"client_name" is required');
    }
    if (pendingPairings.length >= 5) {
      return _json(res, 429, {'success': false, 'error': 'Too many pending pairing requests'});
    }
    // A newer request from the same software replaces the old one.
    _pairings.removeWhere((_, p) => p.clientId == clientId && p.status == PairingStatus.pending);

    final random = Random.secure();
    final request = PairingRequest(
      id: newToken(),
      clientId: clientId,
      clientName: clientName.trim(),
      code: (100000 + random.nextInt(900000)).toString(),
    );
    _pairings[request.id] = request;
    notifyListeners();
    return _json(res, 202, {
      'success': true,
      'pairing_id': request.id,
      'code': request.code,
      'status': request.status.name,
      'expires_in': pairingTimeout.inSeconds,
    });
  }

  Future<void> _pairingStatus(HttpResponse res, String pairingId) async {
    final p = _pairings[pairingId];
    if (p == null) return _json(res, 404, {'success': false, 'error': 'Unknown or finished pairing'});
    if (p.status == PairingStatus.pending && p.isExpired) p.status = PairingStatus.expired;

    final body = <String, Object?>{'success': true, 'status': p.status.name, 'client_id': p.clientId};
    if (p.status == PairingStatus.approved) {
      // The token is handed out exactly once.
      body['token'] = p.token;
      body.addAll(_config(p.clientId));
    }
    if (p.status != PairingStatus.pending) _pairings.remove(pairingId);
    return _json(res, 200, body);
  }

  /// Everything the software needs to set itself up in one call.
  Map<String, Object?> _config(String clientId) {
    final client = _clients.byId(clientId);
    return {
      'client': client?.toApiJson() ?? {'client_id': ApiClient.manualId, 'client_name': 'Manual (master token)'},
      'default_printer_id': _printers.defaultPrinter?.id,
      'printers': [for (final p in _printers.printers) _printerJson(p)],
      'routes': _routesJson(clientId),
    };
  }

  List<Map<String, Object?>> _routesJson(String clientId) =>
      [for (final r in _clients.routesFor(clientId)) _clients.routeJson(r)];

  Map<String, Object?> _printerJson(Printer p) => {
    ...p.toApiJson(),
    'paper': p.geometry().toJson(),
    'auto_cut': p.autoCut,
    'features': p.isLabel ? _labelFeatures : _features,
  };

  /// Returns the client id for a valid token. Without a token, local
  /// requests are accepted as the manual client unless [requireToken] is on.
  /// A wrong token is always rejected, so misconfiguration is visible.
  String? _authenticate(HttpRequest req) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final given = auth != null && auth.startsWith('Bearer ')
        ? auth.substring(7).trim()
        : req.headers.value('x-api-key');
    if (given == null || given.isEmpty) {
      final local = req.connectionInfo?.remoteAddress.isLoopback ?? false;
      return !requireToken && local ? ApiClient.manualId : null;
    }
    if (_constantTimeEquals(given, token)) return ApiClient.manualId;
    return _clients.byToken(given)?.id;
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) throw _PayloadTooLarge();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > maxBodyBytes) throw _PayloadTooLarge();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      throw const FormatException('Body must be valid JSON');
    }
    if (decoded is! Map) throw const FormatException('Body must be a JSON object');
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _json(HttpResponse res, int status, Map<String, Object?> body) async {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }
}

class _PayloadTooLarge implements Exception {}
